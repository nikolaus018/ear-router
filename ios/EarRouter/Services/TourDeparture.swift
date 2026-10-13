import Foundation

/// When the van left for the Lager — the one moment of the day no tick marks.
///
/// Everything after the Lager is measured: its tick, then each door's. What
/// comes before it was only ever the drive OSRM puts between Start and the
/// Lager, and that is not what the morning takes: the drive at that hour,
/// finding the pallet, waiting for the kitchen. Nothing said when it began,
/// so nothing could be learned about it, and an estimate made before the
/// Lager's tick — "Tour vorbereiten" the evening before, above all — was
/// short by however long that is.
///
/// The driver starts navigation to the Lager when they leave. That tap is the
/// stamp. `PaceHistory` holds it against the Lager's tick on the finished
/// tours, and the next tour starts from what those took.
///
/// Per tour, in `UserDefaults`, beside the other things a tour carries that
/// are not part of the store — see `LadelisteState`.
enum TourDeparture {
    private static func key(_ routeID: UUID) -> String { "tour.departure.\(routeID.uuidString)" }

    /// A stamp older than this is another day's: the tour was not reset, or
    /// the tap was made the evening before.
    static let staleAfter: TimeInterval = 4 * 3600

    static func load(for routeID: UUID) -> Date? {
        UserDefaults.standard.object(forKey: key(routeID)) as? Date
    }

    static func forget(_ routeID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(routeID))
    }

    /// Called wherever navigation to a stop is started. Stamps the departure
    /// when that stop is the Lager and the tour has not begun.
    ///
    /// The first tap stands: a second one on the way — after a wrong turn, or
    /// a stop for fuel — is not when the van left.
    @MainActor
    static func noteNavigation(to stop: Stop, at now: Date = Date()) {
        // Every start passes through here, which makes it the one place that
        // can say where the navigation app was last sent.
        NavigationHandoff.noteStarted(stop.id, at: now)
        guard let route = stop.route, route.status == .active,
              stop.kind == .via, stop.isCheckpoint, !stop.isSettled,
              !route.stops.contains(where: { $0.countsAsStop && $0.isSettled && $0.outcome?.skipsDoor != true })
        else { return }
        if let stamped = load(for: route.id), now.timeIntervalSince(stamped) < staleAfter,
           stamped <= now { return }
        UserDefaults.standard.set(now, forKey: key(route.id))
    }
}
