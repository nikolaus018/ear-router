import Foundation
import Testing

@testable import EarRouter

/// The reminder is the only thing standing between a lapsed profile and a
/// driver whose app will not open, so the arithmetic that picks its moment is
/// worth pinning down — especially the edges, which are exactly the cases where
/// a silently dropped reminder looks identical to a scheduled one.
struct SideloadExpiryTests {

    private let vienna = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: - The ordinary case

    @Test func warnsTheEveningBeforeAndAgainTwoHoursOut() {
        // A profile signed on a Friday afternoon: it dies the next Friday at
        // 16:04 local, so the useful evening is the Thursday.
        let expiry = date("2026-09-11T16:04:27+02:00")
        let due = SideloadExpiry.reminders(
            for: expiry, now: date("2026-09-04T22:00:00+02:00"), calendar: vienna)

        #expect(due.map(\.id) == [.eveningBefore, .lastCall])
        #expect(due[0].fireAt == date("2026-09-10T19:00:00+02:00"))
        #expect(due[1].fireAt == date("2026-09-11T14:04:27+02:00"))
    }

    @Test func theEveningReminderLandsAtSevenRegardlessOfTheExpiryTime() {
        // Whatever time of day the profile happens to lapse, the evening before
        // is an evening — not "expiry minus 21 hours".
        for clock in ["00:30", "09:00", "23:59"] {
            let expiry = date("2026-09-11T\(clock):00+02:00")
            let due = SideloadExpiry.reminders(
                for: expiry, now: date("2026-09-01T12:00:00+02:00"), calendar: vienna)
            #expect(due.first?.fireAt == date("2026-09-10T19:00:00+02:00"))
        }
    }

    // MARK: - Edges

    @Test func dropsTheEveningReminderOnceItsEveningHasPassed() {
        // Installed on the last afternoon: there is no "evening before" left to
        // use, and scheduling one in the past would arm nothing while looking
        // armed. The two-hour call still has time to run.
        let expiry = date("2026-09-11T16:04:00+02:00")
        let due = SideloadExpiry.reminders(
            for: expiry, now: date("2026-09-11T09:00:00+02:00"), calendar: vienna)

        #expect(due.map(\.id) == [.lastCall])
    }

    @Test func schedulesNothingInsideTheFinalTwoHours() {
        let expiry = date("2026-09-11T16:04:00+02:00")
        let due = SideloadExpiry.reminders(
            for: expiry, now: date("2026-09-11T15:00:00+02:00"), calendar: vienna)

        #expect(due.isEmpty)
    }

    @Test func schedulesNothingForAProfileThatHasAlreadyLapsed() {
        let expiry = date("2026-09-11T16:04:00+02:00")
        let due = SideloadExpiry.reminders(
            for: expiry, now: date("2026-09-12T08:00:00+02:00"), calendar: vienna)

        #expect(due.isEmpty)
    }

    @Test func aMidnightExpiryWarnsOnTheEveningTwoCalendarDaysEarlier() {
        // Expiring at 00:30 on the 11th means the 10th is the last usable day,
        // so both reminders land on the 10th — and the last call precedes
        // midnight rather than following it.
        let expiry = date("2026-09-11T00:30:00+02:00")
        let due = SideloadExpiry.reminders(
            for: expiry, now: date("2026-09-05T12:00:00+02:00"), calendar: vienna)

        #expect(due.map(\.id) == [.eveningBefore, .lastCall])
        #expect(due[0].fireAt == date("2026-09-10T19:00:00+02:00"))
        #expect(due[1].fireAt == date("2026-09-10T22:30:00+02:00"))
    }

    @Test func crossesTheEndOfAMonthWithoutLosingADay() {
        let expiry = date("2026-10-01T11:00:00+02:00")
        let due = SideloadExpiry.reminders(
            for: expiry, now: date("2026-09-25T12:00:00+02:00"), calendar: vienna)

        #expect(due.first?.fireAt == date("2026-09-30T19:00:00+02:00"))
    }

    @Test func survivesTheEndOfSummerTime() {
        // Vienna moves the clocks back on 25 October 2026. The evening before
        // is still 19:00 wall-clock on the 24th, which is a UTC+02:00 evening
        // even though the expiry itself falls in UTC+01:00.
        let expiry = date("2026-10-25T14:00:00+01:00")
        let due = SideloadExpiry.reminders(
            for: expiry, now: date("2026-10-20T12:00:00+02:00"), calendar: vienna)

        #expect(due.first?.fireAt == date("2026-10-24T19:00:00+02:00"))
    }

    // MARK: - Identifiers

    @Test func reminderIdentifiersAreDistinctSoRearmingReplacesRatherThanPiles() {
        let ids = SideloadExpiry.Reminder.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
    }
}
