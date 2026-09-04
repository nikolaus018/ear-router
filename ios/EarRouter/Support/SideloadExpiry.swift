import Foundation
import OSLog
import UserNotifications

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "expiry")

/// The seven-day clock a sideloaded build runs on, and the reminder that keeps
/// it from running out unannounced.
///
/// This app is installed straight from Xcode on a free developer account, which
/// means the embedded provisioning profile is valid for exactly seven days.
/// When it lapses the app stops launching — no warning, no error the driver can
/// act on, just a bounce back to the home screen, typically on a morning when
/// there is a van and a list of meals waiting.
///
/// So the build tells you when it is going to die. The expiry date is not a
/// constant to be maintained by hand: it is read out of the profile Xcode
/// embedded at signing time, so every reinstall silently rearms the reminder at
/// the new date and there is nothing to remember to update.
///
/// Nothing here is a push notification in the network sense — no server, no APNs
/// certificate, no reliance on this Mac being awake. iOS holds the scheduled
/// alarm itself, which is also why it still fires *after* the profile has
/// expired and the app can no longer be opened.
enum SideloadExpiry {

    /// When this build stops being accepted, or `nil` for any build without a
    /// short-lived profile — the simulator, and anything distributed properly.
    /// Reading it once is safe: a bundle cannot change underneath a running app.
    static let expiresAt: Date? = readExpirationDate()

    /// The hour the evening-before reminder fires: after work, but with enough
    /// of the evening left to plug the phone in and press Run.
    static let eveningHour = 19

    // MARK: - Reading the profile

    /// Pulls `ExpirationDate` out of `embedded.mobileprovision`.
    ///
    /// The file is a DER-wrapped PKCS#7 container, and the API that unwraps one
    /// properly — `CMSDecoder` — is macOS-only. The payload it wraps is an
    /// ordinary XML plist, though, so the pragmatic move on iOS is to lift the
    /// plist out of the envelope by its delimiters and let
    /// `PropertyListSerialization` do the rest. The signature goes unchecked,
    /// which would matter if this were a security decision; it is a reminder.
    private static func readExpirationDate() -> Date? {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url)
        else { return nil }

        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), options: .backwards)
        else {
            log.error("embedded.mobileprovision holds no plist")
            return nil
        }

        // A fresh `Data` rather than the slice: a slice does not start at index
        // zero, and enough of Foundation still treats that as a footgun.
        let xml = Data(data[start.lowerBound..<end.upperBound])
        guard
            let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil),
            let fields = plist as? [String: Any]
        else {
            log.error("embedded.mobileprovision plist did not parse")
            return nil
        }
        return fields["ExpirationDate"] as? Date
    }

    // MARK: - When to warn

    enum Reminder: String, CaseIterable {
        case eveningBefore = "sideload-expiry-evening-before"
        case lastCall = "sideload-expiry-last-call"
    }

    /// The reminders still worth scheduling for a build expiring at `expiry`.
    ///
    /// Two of them, because one is not enough on its own: the evening before is
    /// when there is actually time to reinstall, and a last call two hours out
    /// catches the case where the phone was face-down all evening. Anything
    /// already in the past is dropped rather than scheduled — a calendar trigger
    /// with a past date never fires, so an unfiltered list would look armed and
    /// do nothing.
    static func reminders(
        for expiry: Date, now: Date = .now, calendar: Calendar = .current
    ) -> [(id: Reminder, fireAt: Date)] {
        var due: [(id: Reminder, fireAt: Date)] = []

        let expiryDay = calendar.startOfDay(for: expiry)
        if let dayBefore = calendar.date(byAdding: .day, value: -1, to: expiryDay),
            let evening = calendar.date(
                bySettingHour: eveningHour, minute: 0, second: 0, of: dayBefore),
            evening > now
        {
            due.append((.eveningBefore, evening))
        }

        if let lastCall = calendar.date(byAdding: .hour, value: -2, to: expiry), lastCall > now {
            due.append((.lastCall, lastCall))
        }

        return due
    }

    // MARK: - Scheduling

    /// Rearms both reminders for the currently installed build. Idempotent, and
    /// meant to be called on every launch: reinstalling is what moves the expiry
    /// date, and reinstalling from Xcode always launches the app.
    static func scheduleReminders() async {
        guard let expiry = expiresAt else { return }

        let center = UNUserNotificationCenter.current()
        // Clear first, unconditionally. Yesterday's pending alarm names a date
        // this build no longer expires on, and a reminder that cries wolf a day
        // early is one the driver learns to swipe away.
        center.removePendingNotificationRequests(
            withIdentifiers: Reminder.allCases.map(\.rawValue))

        let due = reminders(for: expiry)
        guard !due.isEmpty else {
            log.notice("build expires \(expiry, privacy: .public); too late to warn")
            return
        }

        // Asking every launch costs nothing: once the driver has answered, iOS
        // returns the standing answer without showing anything.
        let granted =
            (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            log.notice("no notification permission; expiry reminder not scheduled")
            return
        }

        for (id, fireAt) in due {
            let request = UNNotificationRequest(
                identifier: id.rawValue,
                content: id.content(expiry: expiry),
                trigger: id.trigger(firingAt: fireAt))
            do {
                try await center.add(request)
                log.notice("expiry reminder \(id.rawValue, privacy: .public) set for \(fireAt, privacy: .public)")
            } catch {
                log.error("could not schedule \(id.rawValue, privacy: .public): \(error.localizedDescription)")
            }
        }
    }
}

extension SideloadExpiry.Reminder {

    /// The two reminders mean different things by their time, so they are
    /// triggered differently.
    ///
    /// "The evening before" is a wall-clock intention — it should land at 19:00
    /// wherever the phone is, which is what a calendar trigger preserves. "Two
    /// hours before it dies" is an absolute one: the profile expires at a fixed
    /// instant no matter which timezone the phone has moved to since, so that
    /// one counts down real seconds.
    func trigger(firingAt fireAt: Date) -> UNNotificationTrigger {
        switch self {
        case .eveningBefore:
            let parts = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireAt)
            return UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        case .lastCall:
            return UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fireAt.timeIntervalSinceNow), repeats: false)
        }
    }

    func content(expiry: Date) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        let clock = expiry.formatted(.dateTime.hour().minute())

        switch self {
        case .eveningBefore:
            content.title = "EAR Router läuft morgen ab"
            content.body =
                "Die Installation gilt nur bis morgen \(clock) Uhr. Am besten heute Abend "
                + "noch einmal über Xcode installieren — danach startet die App nicht mehr."
        case .lastCall:
            content.title = "EAR Router läuft in zwei Stunden ab"
            content.body = "Um \(clock) Uhr ist Schluss. Jetzt neu über Xcode installieren."
        }

        content.sound = .default
        return content
    }
}
