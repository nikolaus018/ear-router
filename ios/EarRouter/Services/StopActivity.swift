import ActivityKit
import Foundation
import OSLog
import SwiftData

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "activity")

/// Keeps the lock screen showing the door the driver is on.
///
/// One activity at a time, for the tour the rest of the app is already talking
/// about: the current one, as `Route.current` decides it. It starts itself when
/// that tour has a door still owed a visit, follows `nextOpen` as the driver
/// ticks along, and ends when the last door is answered for — so the thing on
/// the lock screen is never a stop that is already done.
///
/// Driven from the app rather than from a push: every change it reflects is one
/// the driver made in the app a moment earlier, so there is always a foreground
/// moment to update in, and no server, no APNs certificate, and nothing to keep
/// alive in the background.
@MainActor
enum StopActivity {

    /// Whether to bother at all. Off when the driver has switched Live
    /// Activities off for the app in Settings, which is a real answer and not
    /// an error to log every time a meal is ticked.
    private static var available: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Brings the lock screen back in line with the store: starts, updates or
    /// ends, whichever the tour now calls for.
    ///
    /// Safe to call after anything — a tick, an import, a re-optimize, a
    /// deletion, a launch. It reads the same current tour Jetzt shows — see
    /// `Route.current` — and works out the rest itself, so no call site has to
    /// know which of the three things is about to happen.
    static func refresh(
        in context: ModelContext, working: UUID? = RouteFocus.lastOpenedRouteID
    ) {
        guard available else { return }

        // One snapshot, not two: it walks every stop on the tour, and this
        // runs after every tick.
        guard let route = Route.current(in: context, working: working) else {
            end()
            return
        }
        let snapshot = RouteSnapshot(route)
        guard let stop = snapshot.nextOpen else {
            end()
            return
        }
        // What the app knows about this customer from every previous tour —
        // the floor, and whatever the driver wrote down at the door once. The
        // same lookup the Jetzt tab and Siri do; a stop with nothing stored
        // simply carries neither.
        let info = (try? StockwerkStore.note(for: stop, in: context)) ?? nil
        // Every free-text field capped: ActivityKit refuses a state over 4 KB
        // outright, and the widget shows one to three lines of each anyway. The
        // Paket alone used to be — a 1000-character Notiz beside a long Globale
        // Info went over, the update was refused, and the lock screen went on
        // showing the door before.
        let state = StopActivityAttributes.ContentState(
            kunde: Self.capped(stop.kunde) ?? "Stopp",
            adresse: Self.capped(stop.strasse) ?? "",
            paket: Self.capped(stop.displayPaket),
            notiz: Self.capped(stop.notiz),
            stockwerk: Self.capped(info?.stockwerk).map(Format.floor),
            kundeninfo: Self.capped(info?.notiz),
            number: snapshot.number(stop))
        enqueue(tour: route.name, state: state)
    }

    /// Takes the activity down — the tour is finished, deleted, or there is no
    /// longer one running.
    /// Trimmed, and cut to at most `fieldBytes` of UTF-8 on a character
    /// boundary. Bytes rather than characters, because the limit is on the
    /// encoded state: 250 characters of emoji are a kilobyte. Six fields at
    /// this cap stay inside 4 KB even with every byte escaped in the JSON.
    nonisolated static func capped(_ text: String?) -> String? {
        guard let text = text?.trimmed.nilIfEmpty else { return nil }
        guard text.utf8.count > fieldBytes else { return text }
        var out = ""
        var bytes = 0
        for c in text {
            bytes += c.utf8.count
            if bytes > fieldBytes { break }
            out.append(c)
        }
        return out.nilIfEmpty
    }

    nonisolated static let fieldBytes = 300

    static func end() {
        enqueue(tour: nil, state: nil)
    }

    // MARK: - Private

    /// The last hand-off to ActivityKit, which the next one waits for.
    ///
    /// Each refresh used to start a task of its own, and two close together —
    /// a launch and the first save after it, two ticks at a shared door — ran
    /// side by side. Both could look for the tour's card, find none yet, and
    /// each request one: two cards on the lock screen, only the first of them
    /// ever updated again. Or the older state's update landed after the newer
    /// one's, and the card showed a door already done. In a line, each sees
    /// exactly what the one before it left.
    private static var pending: Task<Void, Never>?

    private static func enqueue(
        tour: String?, state: StopActivityAttributes.ContentState?
    ) {
        let previous = pending
        pending = Task {
            await previous?.value
            await sync(tour: tour, state: state)
        }
    }

    /// Every call into ActivityKit, in one `nonisolated` place.
    ///
    /// Not an accident of style. `Activity` is a class, it is not `Sendable`,
    /// and `update` and `end` are `nonisolated async` — so an activity read on
    /// the main actor and awaited on there is a non-`Sendable` object crossing
    /// an isolation boundary, which Swift 6 rejects. Read it here, use it here,
    /// and it never crosses: what goes in is the tour's name and a state struct
    /// of strings and numbers, both of which are `Sendable` on their own.
    private nonisolated static func sync(
        tour: String?, state: StopActivityAttributes.ContentState?
    ) async {
        guard let tour, let state else {
            await endAll()
            return
        }

        if let current = Activity<StopActivityAttributes>.activities
            .first(where: { $0.attributes.tour == tour }) {
            await current.update(ActivityContent(state: state, staleDate: nil))
            return
        }

        // A different tour than the one on the lock screen means the driver
        // moved on: the old activity is replaced rather than updated, because
        // Tuesday's stops under Monday's tour name is worse than a moment with
        // nothing there at all.
        await endAll()
        do {
            _ = try Activity.request(
                attributes: StopActivityAttributes(tour: tour),
                content: ActivityContent(state: state, staleDate: nil))
        } catch {
            // Not surfaced. A Live Activity that will not start is a lock
            // screen that stays as it was; the tour itself is unaffected, and
            // an alert about it would interrupt a driver at a door over
            // something they cannot act on.
            log.error("Live Activity nicht gestartet: \(error.localizedDescription)")
        }
    }

    private nonisolated static func endAll() async {
        for activity in Activity<StopActivityAttributes>.activities {
            // `end(_:dismissalPolicy:)`, with no new content: the older
            // one-argument form has been deprecated since iOS 16.2.
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
