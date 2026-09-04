import Foundation
import SwiftData
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "optimize")

/// Re-solves stop order and fetches real geometry for a route via OSRM.
///
/// The shape of a tour is: the fixed head (depot → warehouse) in exactly that
/// order, then the customers in whatever order OSRM finds cheapest, then the
/// fixed destination. Each of those three fixed points can be switched off per
/// route, so none is assumed to be there — a tour that starts straight at the
/// warehouse, or ends at its last customer, is planned on exactly the points
/// it actually drives instead of on two legs it never will.
///
/// Structured as read → await → write, with no model context touched across an
/// `await`: the OSRM calls in the middle take seconds. The reads produce plain
/// `Sendable` value types and the write applies the result back by stop id, so
/// SwiftData is only ever used on the main actor.
@MainActor
enum RouteOptimizer {

    /// The three fixed points of a tour plus its customers, as value types.
    private struct Nodes: Sendable {
        var start: FixedStop?
        var via: FixedStop?
        var end: FixedStop?
        var customers: [StopCoord] = []

        /// The fixed points the tour actually drives, in order, before any
        /// customer. Excluded ones are simply not there.
        var head: [StopCoord] {
            [start, via].compactMap { $0?.active }
        }
    }

    private struct FixedStop: Sendable {
        let coord: StopCoord
        let excluded: Bool
        var active: StopCoord? { excluded ? nil : coord }
    }

    /// Everything the optimizer actually plans from, in a form two runs can be
    /// compared by: which stops exist, where they are, and which are skipped.
    ///
    /// Deliberately not the whole row — a customer's name or note changing
    /// between the read and the write does not make the computed order or
    /// geometry wrong, and treating it as if it did would leave routes
    /// perpetually flagged for re-optimization over an edited Notiz.
    private struct Fingerprint: Equatable, Sendable {
        let entries: [Entry]
        struct Entry: Equatable, Sendable {
            let id: UUID
            let lat: Double
            let lon: Double
            let excluded: Bool
        }
    }

    /// Serializes optimizations per route: the read and the write are
    /// separated by seconds of network calls, so two concurrent runs on one
    /// route would both plan from the same starting state and the slower one
    /// would overwrite the faster one's stop order while keeping its own leg
    /// distances.
    private static var inFlight: [UUID: Task<Void, Error>] = [:]

    // MARK: - Entry points

    /// The explicit "Neu optimieren" action. Failures surface, because here
    /// the optimization *is* the request — failing quietly would mean a tap
    /// that appears to do nothing at all.
    static func optimize(_ route: Route, in context: ModelContext) async throws {
        let routeID = route.id
        // Each run waits for its predecessor *inside its own task*, so the map
        // always holds the newest link in the chain. Awaiting the predecessor
        // before storing ourselves — which is what this did — let a finishing
        // run clear the entry belonging to the run after it, and the call after
        // that then started concurrently with one already in flight.
        let previous = inFlight[routeID]
        let task = Task {
            _ = try? await previous?.value
            try await run(route, in: context)
        }
        inFlight[routeID] = task
        defer {
            // Only if we are still the newest; otherwise this would strand the
            // successor that has already queued behind us.
            if inFlight[routeID] == task { inFlight[routeID] = nil }
        }
        try await task.value
    }

    /// For callers that have *already committed* their change — a stop added,
    /// edited, deleted, or a whole route imported.
    ///
    /// For those, a failing OSRM call is not a failed request. The write
    /// landed and the route is correctly flagged `needsOptimize`, so the app
    /// already has a designed answer for this exact state: the amber "Route
    /// nicht aktuell" banner with its one-tap retry. Propagating the error
    /// instead hands the driver a red failure toast for an action that
    /// demonstrably worked — and the obvious response to that toast, doing it
    /// again, silently adds the same stop twice.
    static func optimizeBestEffort(_ route: Route, in context: ModelContext) async {
        do {
            try await optimize(route, in: context)
        } catch {
            log.warning("best-effort optimize failed: \(error.localizedDescription)")
        }
    }

    // MARK: - The solve

    private static func run(_ route: Route, in context: ModelContext) async throws {
        // --- read ---
        let (nodes, plannedFrom) = snapshot(route)

        let head = nodes.head
        let end = nodes.end?.active

        // `routed` is the driving order and `legs[i]` is the leg from
        // `routed[i]` to `routed[i + 1]`, so `legs.count + 1 == routed.count`
        // holds from here to the write below.
        var routed = head
        var legs: [(Double, Double)] = []
        var geometry: [[Double]] = []

        // --- await ---

        // Depot → warehouse: fixed, never reordered, so a plain point-to-point
        // call rather than anything the trip optimizer needs to see. Written
        // as a loop over pairs because the head is 0, 1 or 2 points depending
        // on what this tour skips — with either of them off there is no leg.
        for pair in zip(head, head.dropFirst()) {
            let leg = try await OSRMClient.shared.routeLeg(
                from: (pair.0.lat, pair.0.lon), to: (pair.1.lat, pair.1.lon))
            legs.append((leg.distance, leg.duration))
            append(&geometry, leg.geometry)
        }

        // The optimized section runs from the last fixed head point through
        // every customer to the destination. That head point is the anchor: it
        // is already in `routed` and goes into this call only to be routed
        // *from*, never to be added a second time.
        let anchor = head.last
        var tripNodes: [StopCoord] = []
        if let anchor { tripNodes.append(anchor) }
        tripNodes.append(contentsOf: nodes.customers)
        if let end { tripNodes.append(end) }

        if tripNodes.count >= 2 {
            // OSRM cannot solve a `roundtrip=false` trip with both ends open.
            // A tour with depot, warehouse *and* destination all switched off
            // has no fixed point left to anchor to, so the first customer —
            // first by creation order, i.e. the order they were entered — is
            // pinned as the start and the tour is left free to end wherever is
            // cheapest. That is a real choice made on the driver's behalf, but
            // it is the only one on offer, and "start where the list starts"
            // is what a hand-entered list already implies.
            let fixFirst = anchor != nil || end == nil
            let fixLast = end != nil
            let coords = tripNodes.map { (lat: $0.lat, lon: $0.lon) }
            let solved = try await OSRMClient.shared.trip(
                coords: coords, fixFirst: fixFirst, fixLast: fixLast)

            for idx in solved.order {
                // The anchor is already the last entry of `routed`.
                if anchor != nil && idx == 0 { continue }
                routed.append(tripNodes[idx])
            }
            legs.append(contentsOf: solved.legs)
            append(&geometry, solved.geometry)
        } else {
            // At most one point after the head — nothing to optimize, but it
            // still belongs in the driving order.
            routed.append(contentsOf: tripNodes.dropFirst(anchor != nil ? 1 : 0))
        }

        // --- write ---

        // Leg distances belong to the driving order; the row they are written
        // onto is found by stop id, so the display order below can differ from
        // it without the two ever drifting apart. A stop that is not driven at
        // all appears in neither map and has its stale legs cleared.
        var legFor: [UUID: (Double, Double)] = [:]
        for (pos, node) in routed.enumerated() where pos < legs.count {
            legFor[node.id] = legs[pos]
        }

        // Did the route change while this solution was being computed?
        //
        // Edits commit and *then* queue an optimization, so two edits in quick
        // succession produce two runs, and the first planned from a route that
        // no longer exists by the time it writes. Its stop order and geometry
        // are simply stale, which the second run corrects. What is not
        // self-correcting is clearing `needsOptimize`: the first run would
        // clear the flag the second edit had set, and if that second run then
        // fails (OSRM unreachable — the whole reason best-effort exists), the
        // route is left claiming to be current while its geometry is missing a
        // stop. No banner, no retry offered, wrong distances all day.
        //
        // The order and geometry are written either way — a fresher-than-
        // nothing solution beats leaving the old one — but the flag only
        // clears when this solution actually describes the route on disk.
        let current = fingerprint(route)
        let stillCurrent = current == plannedFrom
        if !stillCurrent {
            log.info("route changed while being optimized — writing this solution but leaving it flagged")
        }

        let byID = Dictionary(route.stops.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (pos, node) in displayOrder(nodes, routed: routed).enumerated() {
            guard let stop = byID[node.id] else { continue }
            stop.orderIndex = pos
            if let leg = legFor[node.id] {
                stop.nextLegKm = leg.0 / 1000
                stop.nextLegMin = leg.1 / 60
            } else {
                stop.nextLegKm = nil
                stop.nextLegMin = nil
            }
        }

        route.geometryFlat = geometry.flatMap { $0 }
        route.needsOptimize = !stillCurrent
        try context.save()
    }

    // MARK: - Helpers

    private static func snapshot(_ route: Route) -> (Nodes, Fingerprint) {
        // Ordered by creation so "the first customer" means the one entered
        // first, which is what the no-fixed-points anchor rule relies on.
        let stops = route.stops.sorted { $0.createdAt < $1.createdAt }
        var nodes = Nodes()
        for s in stops {
            let coord = s.planningSnapshot
            let fixed = FixedStop(coord: coord, excluded: s.excluded)
            // `excluded` is only ever written to a fixed stop, and a customer
            // row carrying it anyway must not silently disappear from the tour
            // — hence matching on the kind rather than on the flag.
            switch s.kind {
            case .start: nodes.start = fixed
            case .via: nodes.via = fixed
            case .end: nodes.end = fixed
            case .customer: nodes.customers.append(coord)
            }
        }
        return (nodes, fingerprint(route))
    }

    private static func fingerprint(_ route: Route) -> Fingerprint {
        Fingerprint(
            entries: route.stops
                .sorted { $0.createdAt < $1.createdAt }
                .map {
                    Fingerprint.Entry(
                        id: $0.id, lat: $0.lat, lon: $0.lon, excluded: $0.excluded)
                })
    }

    /// The order the route's stops are *shown* in, which is not the order they
    /// are driven in: a switched-off fixed stop still belongs where it would
    /// have been driven — the depot at the top of the list, the destination at
    /// the bottom — rather than flushed to the end, where "Start" would sit
    /// underneath the last customer of the day. Only the customers are placed
    /// by `routed`; that ordering is the whole point of the optimization.
    private static func displayOrder(_ nodes: Nodes, routed: [StopCoord]) -> [StopCoord] {
        let customerIDs = Set(nodes.customers.map(\.id))
        var out: [StopCoord] = []
        out.reserveCapacity(routed.count + 3)
        if let s = nodes.start?.coord { out.append(s) }
        if let v = nodes.via?.coord { out.append(v) }
        out.append(contentsOf: routed.filter { customerIDs.contains($0.id) })
        if let e = nodes.end?.coord { out.append(e) }
        return out
    }

    /// Joins two OSRM geometries, dropping the duplicated shared point where
    /// one leg ends and the next begins.
    private static func append(_ acc: inout [[Double]], _ segment: [[Double]]) {
        if !acc.isEmpty && !segment.isEmpty { acc.removeLast() }
        acc.append(contentsOf: segment)
    }
}
