import Foundation

/// What switching "Pause zu Hause" on would add to the drive still ahead —
/// asked before the pause goes on the tour, because whether there is time for
/// it is the whole question.
struct PauseDetour: Equatable, Sendable {
    let minutes: Double
    let km: Double

    /// The sentence the confirmation asks with.
    ///
    /// `zielBefore` is the arrival at Ziel as the tour stands; the detour
    /// moves it, and so does the pause — by however long the driver takes,
    /// which nobody can say beforehand, so it is named and not counted.
    /// `nil` detour: OSRM could not be asked, and the pause can still be
    /// switched on blind.
    static func summary(_ detour: PauseDetour?, zielBefore: Date?, endsAtHome: Bool) -> String {
        guard let detour else {
            return "Der Umweg konnte gerade nicht berechnet werden."
        }
        let drive = [Format.minutes(detour.minutes), Format.km(detour.km)]
            .compactMap { $0 }.joined(separator: " · ")
        let first = "Umweg +\(drive)."
        if endsAtHome { return first + " Die Tour endet dann zu Hause." }
        guard let zielBefore else { return first }
        let after = zielBefore.addingTimeInterval(detour.minutes * 60)
        return first + " Am Ziel ca. \(Format.time(after)) statt \(Format.time(zielBefore)), "
            + "plus die Pause."
    }
}

extension RouteOptimizer {
    /// The extra drive "Pause zu Hause" costs, planned the way switching it on
    /// would plan it: the open doors solved once to finish at Ziel and once to
    /// finish at home, home → Ziel added to the second. A hand-sorted tour
    /// keeps its order either way, so only its end differs.
    ///
    /// Nothing is written. Both answers come from the same server in the same
    /// moment, so the difference is the detour and not two servers' opinions.
    static func pauseDetour(_ route: Route, home: HomeAddress) async throws -> PauseDetour {
        let (nodes, _) = snapshot(route)
        var withPause = nodes
        withPause.pause = StopCoord(id: UUID(), lat: home.lat, lon: home.lon)
        withPause.pauseDone = false

        let without: (Double, Double)
        let with: (Double, Double)
        if route.handOrdered {
            let skippedIDs = Set(nodes.skipped.map(\.id))
            let listed = route.customerStops.map(\.planningSnapshot)
                .filter { !skippedIDs.contains($0.id) }
            let (a, b) = listedEnds(
                listedDrivingOrder(nodes, customers: listed),
                listedDrivingOrder(withPause, customers: listed),
                hasEnd: nodes.end?.active != nil)
            async let first = through(a)
            async let second = through(b)
            (without, with) = try await (first, second)
        } else {
            async let first = ahead(plan(nodes))
            async let second = ahead(plan(withPause))
            (without, with) = try await (first, second)
        }
        return PauseDetour(
            minutes: max(0, (with.1 - without.1) / 60),
            km: max(0, (with.0 - without.0) / 1000))
    }

    /// The part of two listed orders that differs: from the last point both
    /// share before their ends — the last open door, or wherever the van is
    /// — to the end of each.
    static func listedEnds(
        _ without: [StopCoord], _ with: [StopCoord], hasEnd: Bool
    ) -> ([StopCoord], [StopCoord]) {
        let shared = without.count - (hasEnd ? 1 : 0)
        guard shared >= 1 else { return (without, with) }
        return (Array(without[(shared - 1)...]), Array(with[(shared - 1)...]))
    }

    /// Metres and seconds of everything a plan leaves to OSRM: the trip from
    /// where the van is, and Ziel behind the pause.
    private static func ahead(_ plan: Plan) async throws -> (Double, Double) {
        var legs: [(Double, Double)] = []
        if plan.needsTrip {
            legs += try await OSRMClient.shared.trip(
                coords: plan.tripNodes.map { (lat: $0.lat, lon: $0.lon) },
                fixFirst: plan.fixFirst, fixLast: plan.fixLast).legs
        }
        if plan.tail.count >= 2 {
            legs += try await OSRMClient.shared.routeThrough(
                plan.tail.map { (lat: $0.lat, lon: $0.lon) }).legs
        }
        return legs.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
    }

    private static func through(_ points: [StopCoord]) async throws -> (Double, Double) {
        guard points.count >= 2 else { return (0, 0) }
        let legs = try await OSRMClient.shared.routeThrough(
            points.map { (lat: $0.lat, lon: $0.lon) }).legs
        return legs.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
    }
}
