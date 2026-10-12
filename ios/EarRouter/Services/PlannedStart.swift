import Foundation

/// When the driver means to set off — the one thing an estimate made the
/// evening before cannot work out for itself.
///
/// Every arrival time is counted from the last tick, or from now while there
/// is none. The evening before, "now" is the wrong end of the night: a tour
/// loaded at nine was promised finished at three in the morning. "Tour
/// vorbereiten" can be given a departure to count from instead.
///
/// A question asked of that one screen, and nothing more: the departure is not
/// kept, and no other screen's times move with it. All that is remembered is
/// the time of day last asked about, so the picker opens somewhere sensible.
enum PlannedStart {
    private static let lastClockKey = "planned.start.lastClock"

    static func remember(_ date: Date, calendar: Calendar = .current) {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        UserDefaults.standard.set((clock.hour ?? 0) * 60 + (clock.minute ?? 0), forKey: lastClockKey)
    }

    /// What the picker opens on: the next time the clock shows what the driver
    /// asked about last — a round leaves at the same time most mornings — or
    /// eight o'clock on a phone that has never been asked.
    static func suggestion(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let minutes = UserDefaults.standard.object(forKey: lastClockKey) as? Int ?? 8 * 60
        return suggestion(after: now, clockMinutes: minutes, calendar: calendar)
    }

    static func suggestion(after now: Date, clockMinutes: Int, calendar: Calendar = .current) -> Date {
        let clock = DateComponents(hour: clockMinutes / 60, minute: clockMinutes % 60)
        return calendar.nextDate(after: now, matching: clock, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(12 * 3600)
    }
}
