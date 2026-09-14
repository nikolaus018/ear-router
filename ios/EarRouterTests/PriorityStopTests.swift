import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// A stop the driver has pinned to the front of the tour.
///
/// OSRM solves for distance, which is the right objective right up until it is
/// not: somebody waiting on medication, a customer who leaves for dialysis at
/// ten, a Pflegedienst only at the flat until half nine. None of that is in a
/// distance matrix, and a driver who cannot say it to the app says it by
/// ignoring the stop order all morning — which costs the tour every other thing
/// the optimizer got right.
///
/// So a pinned customer is taken out of the solve entirely and driven straight
/// after the warehouse. These pin down that it leaves the solve, that it keeps
/// its place in the list, and that flagging one actually causes a re-solve.
@MainActor
struct PriorityStopTests {

    private func coord(_ n: Int) -> StopCoord {
        StopCoord(id: UUID(), lat: 48.20 + Double(n) / 1000, lon: 16.30 + Double(n) / 1000)
    }

    private func nodes(priority: Int, ordinary: Int) -> RouteOptimizer.Nodes {
        var n = RouteOptimizer.Nodes()
        n.start = RouteOptimizer.FixedStop(coord: coord(0), excluded: false)
        n.via = RouteOptimizer.FixedStop(coord: coord(1), excluded: false)
        n.end = RouteOptimizer.FixedStop(coord: coord(99), excluded: false)
        n.priority = (0..<priority).map { coord(20 + $0) }
        n.customers = (0..<ordinary).map { coord(40 + $0) }
        return n
    }

    /// The head is what the van drives before OSRM is consulted: the fixed
    /// points, then the pinned customers, in that order.
    @Test func pinnedCustomersAreDrivenStraightAfterTheWarehouse() {
        let n = nodes(priority: 2, ordinary: 3)
        #expect(n.head.count == 4)
        #expect(n.head[0].id == n.start?.coord.id)
        #expect(n.head[1].id == n.via?.coord.id)
        #expect(n.head[2].id == n.priority[0].id)
        #expect(n.head[3].id == n.priority[1].id)
    }

    /// And they are not part of the problem OSRM may reorder — which is the
    /// whole point of pinning one.
    ///
    /// The last pinned stop does reach OSRM, once, as `tripNodes[0]`: it is
    /// what the rest of the tour is routed *from*, exactly as the warehouse is
    /// on an ordinary tour, and `drivingOrder` drops that index rather than
    /// visiting it twice. Every pinned stop before it is not in the request at
    /// all.
    @Test func aPinnedCustomerIsOnlyEverTheAnchorOfTheSolve() {
        let n = nodes(priority: 2, ordinary: 3)
        let plan = RouteOptimizer.plan(n)

        #expect(plan.anchor?.id == n.priority[1].id)
        #expect(plan.tripNodes.first?.id == n.priority[1].id)
        // The earlier pinned stop is not in the request at all.
        #expect(!plan.tripNodes.contains { $0.id == n.priority[0].id })
        // Anchor, three ordinary customers, destination — and nothing else.
        #expect(plan.tripNodes.count == 1 + 3 + 1)

        // Walked back out, the anchor appears once and in the head's position.
        let routed = RouteOptimizer.drivingOrder(
            plan, solvedOrder: Array(0..<plan.tripNodes.count))
        #expect(routed.count(where: { $0.id == n.priority[1].id }) == 1)
    }

    /// With no depot and no warehouse, a pinned customer becomes the anchor on
    /// its own rather than being dropped back into the solve.
    @Test func aPinnedCustomerCanAnchorATourWithNoFixedPointsAtAll() {
        var n = RouteOptimizer.Nodes()
        n.priority = [coord(20)]
        n.customers = [coord(40), coord(41)]
        let plan = RouteOptimizer.plan(n)

        #expect(plan.head.count == 1)
        #expect(plan.anchor?.id == n.priority[0].id)
        #expect(plan.fixFirst)
        #expect(!plan.fixLast)
    }

    /// The bug this nearly shipped with: pinned stops travel inside `routed` as
    /// part of the head, so a display order built from the *unpinned* customers
    /// filtered them straight out — and the tour's most urgent stops were the
    /// three that stopped being shown at all.
    @Test func pinnedCustomersStillAppearInTheStopList() {
        let n = nodes(priority: 2, ordinary: 2)
        let routed = n.head + n.customers
        let display = RouteOptimizer.displayOrder(n, routed: routed)

        let customerIDs = display.map(\.id)
        for pinned in n.priority {
            #expect(customerIDs.contains(pinned.id))
        }
        // Depot, warehouse, two pinned, two ordinary, destination.
        #expect(display.count == 7)
        // And in front of the customers the optimizer was allowed to order.
        let firstOrdinary = try? #require(display.firstIndex { $0.id == n.customers[0].id })
        let lastPinned = try? #require(display.firstIndex { $0.id == n.priority[1].id })
        #expect((lastPinned ?? 0) < (firstOrdinary ?? 0))
    }

    /// `customerIDs` is what tells a customer from a fixed point when the list
    /// is rebuilt, and it has to cover both kinds.
    @Test func everyCustomerIsCountedAsACustomer() {
        let n = nodes(priority: 2, ordinary: 3)
        #expect(n.customerIDs.count == 5)
    }

    // MARK: - Causing a re-solve

    private func store() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    /// Pinning a stop changes the shape of the problem, not the contents of a
    /// row. Left out of the fingerprint, a route re-solved for a pin compared
    /// as unchanged and the amber banner cleared over a stop order that had
    /// never moved.
    @Test func pinningAStopMakesTheRouteCompareAsChanged() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let stop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", lat: 48.2301, lon: 16.3201)
        stop.route = route
        context.insert(stop)
        try context.save()

        let (_, before) = RouteOptimizer.snapshot(route)
        stop.prioritaet = true
        let (_, after) = RouteOptimizer.snapshot(route)

        #expect(before != after)
    }

    /// And the snapshot files it on the right side of the problem.
    @Test func aPinnedStopIsReadIntoThePriorityList() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let ordinary = Stop(
            kind: .customer, kunde: "A", strasse: "Gentzgasse 1", plz: "1180",
            lat: 48.2301, lon: 16.3201)
        let urgent = Stop(
            kind: .customer, kunde: "B", strasse: "Gentzgasse 2", plz: "1180",
            lat: 48.2302, lon: 16.3202)
        urgent.prioritaet = true
        for s in [ordinary, urgent] {
            s.route = route
            context.insert(s)
        }
        try context.save()

        let (nodes, _) = RouteOptimizer.snapshot(route)
        #expect(nodes.priority.count == 1)
        #expect(nodes.priority.first?.id == urgent.id)
        #expect(nodes.customers.count == 1)
        #expect(nodes.customers.first?.id == ordinary.id)
    }

    /// Only customers. A fixed point carrying the flag — which nothing writes,
    /// but a restored backup could — must not quietly become a delivery.
    @Test func aFixedPointCannotBeGivenPriority() async throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let start = try #require(route.stops.first { $0.kind == .start })

        try await RouteStore.setPriority(start, true, in: context)
        #expect(!start.prioritaet)
    }
}
