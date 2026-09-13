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
    struct Nodes: Sendable {
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

    struct FixedStop: Sendable {
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
    struct Fingerprint: Equatable, Sendable {
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
        // The chaining above needs an *unstructured* task — it has to outlive
        // this call so the next one can queue behind it — and an unstructured
        // task inherits no cancellation from whoever is awaiting it. Without
        // this handler the stop button on the busy banner cancelled the caller
        // and left the OSRM calls running to completion underneath it: a
        // control that visibly did nothing.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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

        let plan = Self.plan(nodes)

        // `routed` is the driving order and `legs[i]` is the leg from
        // `routed[i]` to `routed[i + 1]`, so `legs.count + 1 == routed.count`
        // holds from here to the write below.
        var legs: [(Double, Double)] = []
        var geometry: [[Double]] = []

        // --- await ---

        // Depot → warehouse: fixed, never reordered, so a plain point-to-point
        // call rather than anything the trip optimizer needs to see. Written
        // as a loop over pairs because the head is 0, 1 or 2 points depending
        // on what this tour skips — with either of them off there is no leg.
        for pair in zip(plan.head, plan.head.dropFirst()) {
            let leg = try await OSRMClient.shared.routeLeg(
                from: (pair.0.lat, pair.0.lon), to: (pair.1.lat, pair.1.lon))
            legs.append((leg.distance, leg.duration))
            append(&geometry, leg.geometry)
        }

        var solvedOrder: [Int]?
        if plan.needsTrip {
            let coords = plan.tripNodes.map { (lat: $0.lat, lon: $0.lon) }
            let solved = try await OSRMClient.shared.trip(
                coords: coords, fixFirst: plan.fixFirst, fixLast: plan.fixLast)
            solvedOrder = solved.order
            legs.append(contentsOf: solved.legs)
            append(&geometry, solved.geometry)
        }

        let routed = Self.drivingOrder(plan, solvedOrder: solvedOrder)

        // --- write ---

        // Stopped while OSRM was answering. What follows is a complete, valid
        // solution — but writing it would reorder every row in the list a
        // moment after the driver pressed the button that says stop.
        // `needsOptimize` is still set, so the amber banner stays and nothing
        // is lost by dropping this answer on the floor.
        try Task.checkCancellation()

        let legFor = Self.legIndex(routed: routed, legs: legs)

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

    // MARK: - The shape of one solve

    /// What this tour asks OSRM, worked out before anything is sent.
    ///
    /// Split out from `run` so it can be tested without a network: the three
    /// fixed points are independently switchable, which means eight shapes of
    /// tour, and the difference between them is which end OSRM is allowed to
    /// move. Getting that wrong does not fail — it returns a route that looks
    /// entirely normal and visits the wrong doors in the wrong order.
    struct Plan: Equatable {
        /// The fixed points driven before any customer, in order.
        let head: [StopCoord]
        /// The last head point. It is already in the driving order and goes to
        /// OSRM only to be routed *from*, never to be added a second time.
        let anchor: StopCoord?
        /// Everything handed to `/trip`: the anchor, the customers, the end.
        let tripNodes: [StopCoord]
        let fixFirst: Bool
        let fixLast: Bool

        /// Fewer than two points is not an optimization problem.
        var needsTrip: Bool { tripNodes.count >= 2 }
    }

    static func plan(_ nodes: Nodes) -> Plan {
        let head = nodes.head
        let end = nodes.end?.active
        let anchor = head.last

        var tripNodes: [StopCoord] = []
        if let anchor { tripNodes.append(anchor) }
        tripNodes.append(contentsOf: nodes.customers)
        if let end { tripNodes.append(end) }

        // OSRM cannot solve a `roundtrip=false` trip with both ends open. A
        // tour with depot, warehouse *and* destination all switched off has no
        // fixed point left to anchor to, so the first customer — first by
        // creation order, i.e. the order they were entered — is pinned as the
        // start and the tour is left free to end wherever is cheapest. That is
        // a real choice made on the driver's behalf, but it is the only one on
        // offer, and "start where the list starts" is what a hand-entered list
        // already implies.
        return Plan(
            head: head,
            anchor: anchor,
            tripNodes: tripNodes,
            fixFirst: anchor != nil || end == nil,
            fixLast: end != nil)
    }

    /// Walks OSRM's answer back into the order the van actually drives.
    ///
    /// `solvedOrder` is `nil` when there was nothing to optimize, in which case
    /// whatever single point follows the head still belongs in the order.
    ///
    /// The one thing to get right is the anchor: it is the last head point, it
    /// is already in the driving order, and it is *also* `tripNodes[0]`. Adding
    /// it again puts the warehouse in the middle of the customer list.
    static func drivingOrder(_ plan: Plan, solvedOrder: [Int]?) -> [StopCoord] {
        var routed = plan.head
        guard let solvedOrder else {
            routed.append(contentsOf: plan.tripNodes.dropFirst(plan.anchor != nil ? 1 : 0))
            return routed
        }
        for index in solvedOrder {
            if plan.anchor != nil && index == 0 { continue }
            // Unreachable: `OSRMClient.visitingOrder` has already refused
            // anything that is not a permutation of the points we sent. Kept as
            // a bounds check rather than an index, because the alternative to
            // skipping one stop here is trapping — and crashing the app in a van
            // at the second door of the day is worse than a route the driver can
            // see is wrong.
            guard plan.tripNodes.indices.contains(index) else { continue }
            routed.append(plan.tripNodes[index])
        }
        return routed
    }

    /// Which leg belongs to which stop.
    ///
    /// Leg distances belong to the *driving* order — `legs[i]` runs from
    /// `routed[i]` to `routed[i + 1]` — but they are written onto rows found by
    /// stop id, so the display order can differ from the driving order without
    /// the two ever drifting apart. The last stop drives no further leg, and a
    /// stop that is not driven at all never appears here — so both end up with
    /// their stale distances cleared.
    static func legIndex(
        routed: [StopCoord], legs: [(Double, Double)]
    ) -> [UUID: (Double, Double)] {
        var out: [UUID: (Double, Double)] = [:]
        for (position, node) in routed.enumerated() where position < legs.count {
            out[node.id] = legs[position]
        }
        return out
    }

    // MARK: - Helpers

    static func snapshot(_ route: Route) -> (Nodes, Fingerprint) {
        // Ordered by creation so "the first customer" means the one entered
        // first, which is what the no-fixed-points anchor rule relies on.
        let stops = route.stops.sorted(by: Stop.createdBefore)
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
                .sorted(by: Stop.createdBefore)
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
    static func displayOrder(_ nodes: Nodes, routed: [StopCoord]) -> [StopCoord] {
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
    /// Not private: the legs of a tour are joined here and nowhere else, and a
    /// duplicated point at every junction is a line that looks almost right.
    static func append(_ acc: inout [[Double]], _ segment: [[Double]]) {
        if !acc.isEmpty && !segment.isEmpty { acc.removeLast() }
        acc.append(contentsOf: segment)
    }
}
