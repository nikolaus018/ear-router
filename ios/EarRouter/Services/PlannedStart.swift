import Foundation

/// When the driver means to set off on a tour — the one thing an estimate
/// made the evening before cannot work out for itself.
///
/// Every arrival time is counted from the last tick, or from now while there
/// is none. The evening before, "now" is the wrong end of the night: a tour
/// loaded at nine was promised finished at three in the morning. With a
/// departure set, the estimate starts there instead, until the tour is
/// actually under way.
///
/// Per tour, in `UserDefaults` beside the other things a tour carries that are
/// not part of the store — see `PortalTourLink`.
enum PlannedStart {
    private static func key(_ routeID: UUID) -> String { "planned.start.\(routeID.uuidString)" }
    private static let lastClockKey = "planned.start.lastClock"

    static func load(for routeID: UUID) -> Date? {
        UserDefaults.standard.object(forKey: key(routeID)) as? Date
    }

    static func save(_ date: Date, for routeID: UUID, calendar: Calendar = .current) {
        UserDefaults.standard.set(date, forKey: key(routeID))
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        UserDefaults.standard.set((clock.hour ?? 0) * 60 + (clock.minute ?? 0), forKey: lastClockKey)
    }

    static func forget(_ routeID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(routeID))
    }

    /// What the picker opens on: the next time the clock shows what the driver
    /// set last — a round leaves at the same time most mornings — or eight
    /// o'clock on a phone that has never been asked.
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
