import Testing
import Foundation
@testable import EarRouter

/// The most intricate code in the app, and the code whose failures are hardest
/// to notice: every bug in here produces a route that looks entirely ordinary
/// on screen — the right number of rows, plausible distances — while sending
/// the driver to the wrong doors in the wrong order.
///
/// None of it needs a network. The parts that decide *what to ask* and *how to
/// read the answer* are pure, which is what makes them checkable at all.
@MainActor
struct RoutePlanningTests {

    private func coord(_ n: Int) -> StopCoord {
        StopCoord(id: UUID(), lat: 48.20 + Double(n) / 1000, lon: 16.30 + Double(n) / 1000)
    }

    private func nodes(
        start: Bool = true, startExcluded: Bool = false,
        via: Bool = true, viaExcluded: Bool = false,
        end: Bool = true, endExcluded: Bool = false,
        customers: Int = 3
    ) -> (RouteOptimizer.Nodes, [StopCoord]) {
        var n = RouteOptimizer.Nodes()
        if start {
            n.start = RouteOptimizer.FixedStop(coord: coord(0), excluded: startExcluded)
        }
        if via {
            n.via = RouteOptimizer.FixedStop(coord: coord(1), excluded: viaExcluded)
        }
        if end {
            n.end = RouteOptimizer.FixedStop(coord: coord(99), excluded: endExcluded)
        }
        n.customers = (0..<customers).map { coord(10 + $0) }
        return (n, n.customers)
    }

    // MARK: - What gets asked

    /// The ordinary tour: depot, warehouse, customers, back to the depot. The
    /// warehouse anchors the optimized section and is *not* a second stop in it.
    @Test func theWarehouseAnchorsTheTripWithoutBeingVisitedTwice() {
        let (n, customers) = nodes()
        let plan = RouteOptimizer.plan(n)

        #expect(plan.head.count == 2)
        #expect(plan.anchor == plan.head.last)
        // anchor + 3 customers + destination
        #expect(plan.tripNodes.count == 5)
        #expect(plan.tripNodes.first == plan.anchor)
        #expect(plan.tripNodes.dropFirst().dropLast().map(\.id) == customers.map(\.id))
        #expect(plan.fixFirst)
        #expect(plan.fixLast)
    }

    /// A shift that starts straight at the warehouse. The depot is not a leg
    /// this van ever drives, so it must not be planned around.
    @Test func aTourThatSkipsTheDepotPlansOnlyWhatItDrives() {
        let (n, _) = nodes(startExcluded: true)
        let plan = RouteOptimizer.plan(n)

        #expect(plan.head.count == 1)
        #expect(plan.anchor?.id == n.via?.coord.id)
        #expect(plan.fixFirst)
        #expect(plan.fixLast)
    }

    /// A tour that finishes at its last customer rather than back at the depot:
    /// the end is left open, which is the whole point of `roundtrip=false`.
    @Test func aTourWithNoDestinationLeavesTheEndOpen() {
        let (n, _) = nodes(endExcluded: true)
        let plan = RouteOptimizer.plan(n)

        #expect(plan.fixFirst)
        #expect(!plan.fixLast)
        #expect(plan.tripNodes.count == 4)  // anchor + 3 customers
    }

    /// Every fixed point switched off. OSRM refuses a `roundtrip=false` trip
    /// with *both* ends open, so one has to be pinned — and the only defensible
    /// choice is the first customer entered.
    @Test func aTourWithNoFixedPointsStillPinsOneEnd() {
        let (n, customers) = nodes(startExcluded: true, viaExcluded: true, endExcluded: true)
        let plan = RouteOptimizer.plan(n)

        #expect(plan.head.isEmpty)
        #expect(plan.anchor == nil)
        #expect(plan.tripNodes.map(\.id) == customers.map(\.id))
        // The combination OSRM answers with `NotImplemented`.
        #expect(plan.fixFirst || plan.fixLast)
        #expect(plan.fixFirst)
        #expect(!plan.fixLast)
    }

    @Test func aTourWithNothingToOrderAsksNothing() {
        let (n, _) = nodes(endExcluded: true, customers: 0)
        let plan = RouteOptimizer.plan(n)
        #expect(!plan.needsTrip)
    }

    // MARK: - How the answer is read

    /// The anchor is `tripNodes[0]` *and* already the last entry of the head.
    /// Appending it again puts the warehouse in the middle of the customers.
    @Test func theAnchorIsNotAddedASecondTime() {
        let (n, _) = nodes()
        let plan = RouteOptimizer.plan(n)
        // OSRM keeps the pinned ends and reverses the customers in between:
        // visiting position 0 is the anchor, 1–3 are the customers in reverse,
        // 4 is the destination.
        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: [0, 3, 2, 1, 4])

        // Depot, warehouse, three customers, destination — the anchor appears
        // once, as the warehouse, not again among the customers.
        #expect(routed.count == 6)
        #expect(routed.map(\.id) == [
            plan.head[0].id,        // depot
            plan.head[1].id,        // warehouse, the anchor
            plan.tripNodes[3].id,   // customers, reversed
            plan.tripNodes[2].id,
            plan.tripNodes[1].id,
            plan.tripNodes[4].id,   // destination
        ])
        // Every id appears exactly once — the failure this guards against is a
        // route that visits one stop twice and silently drops another.
        #expect(Set(routed.map(\.id)).count == routed.count)
    }

    @Test func withNoFixedPointsEveryCustomerIsWalkedInTheSolvedOrder() {
        let (n, _) = nodes(startExcluded: true, viaExcluded: true, endExcluded: true)
        let plan = RouteOptimizer.plan(n)
        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: [0, 2, 1])

        #expect(routed.map(\.id) == [
            plan.tripNodes[0].id, plan.tripNodes[2].id, plan.tripNodes[1].id,
        ])
        #expect(Set(routed.map(\.id)).count == 3)
    }

    /// Nothing to optimize, but the single remaining point still has to be
    /// driven to.
    @Test func theUnoptimizedCaseStillDrivesToItsOnePoint() {
        let (n, _) = nodes(customers: 0)
        let plan = RouteOptimizer.plan(n)
        #expect(plan.needsTrip)  // anchor + destination is two points

        let (single, _) = nodes(endExcluded: true, customers: 1)
        let singlePlan = RouteOptimizer.plan(single)
        let routed = RouteOptimizer.drivingOrder(singlePlan, solvedOrder: nil)
        #expect(routed.count == 3)  // depot, warehouse, the one customer
        #expect(Set(routed.map(\.id)).count == 3)
    }

    // MARK: - The invariant that keeps distances honest

    /// `legs[i]` is the leg *from* `routed[i]`, so the last stop gets none. Off
    /// by one here and every row on the screen shows its neighbour's distance.
    @Test func eachStopCarriesTheLegItSelfDrives() {
        let a = coord(1), b = coord(2), c = coord(3)
        let legs = [(1000.0, 60.0), (2000.0, 120.0)]
        let index = RouteOptimizer.legIndex(routed: [a, b, c], legs: legs)

        #expect(index[a.id]?.0 == 1000)
        #expect(index[b.id]?.0 == 2000)
        #expect(index[c.id] == nil)
    }

    @Test func aStopThatIsNotDrivenCarriesNoLegAtAll() {
        let a = coord(1), b = coord(2)
        let index = RouteOptimizer.legIndex(routed: [a, b], legs: [])
        #expect(index.isEmpty)
    }

    // MARK: - Display order

    /// A switched-off fixed point still belongs where it *would* have been
    /// driven — the depot at the top, the destination at the bottom — rather
    /// than flushed to the end, where "Start" would sit under the last customer
    /// of the day.
    @Test func switchedOffFixedPointsKeepTheirPlaceInTheList() {
        let (n, _) = nodes(startExcluded: true, endExcluded: true, customers: 2)
        let plan = RouteOptimizer.plan(n)
        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: [0, 2, 1])
        let display = RouteOptimizer.displayOrder(n, routed: routed)

        #expect(display.first?.id == n.start?.coord.id)
        #expect(display.last?.id == n.end?.coord.id)
        #expect(display.count == 5)  // start, via, 2 customers, end
        #expect(Set(display.map(\.id)).count == 5)
    }

    /// Only the customers are placed by the solve; the fixed points are placed
    /// by what they are.
    @Test func theCustomersAppearInTheOrderTheyAreDriven() {
        let (n, _) = nodes(customers: 3)
        let plan = RouteOptimizer.plan(n)
        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: [0, 3, 1, 2, 4])
        let display = RouteOptimizer.displayOrder(n, routed: routed)

        let customerIDs = Set(n.customers.map(\.id))
        let shown = display.map(\.id).filter { customerIDs.contains($0) }
        let driven = routed.map(\.id).filter { customerIDs.contains($0) }
        #expect(shown == driven)
    }
}

/// OSRM's answer, before it is trusted.
struct VisitingOrderTests {

    @Test func invertsTheWaypointMappingIntoDrivingOrder() throws {
        // Input point 0 was visited 2nd, point 1 visited 1st, point 2 visited 3rd.
        let order = try OSRMClient.visitingOrder(
            waypointIndices: [1, 0, 2], count: 3, fixFirst: false, fixLast: false)
        #expect(order == [1, 0, 2])
    }

    @Test func acceptsAnUntouchedOrder() throws {
        let order = try OSRMClient.visitingOrder(
            waypointIndices: [0, 1, 2, 3], count: 4, fixFirst: true, fixLast: true)
        #expect(order == [0, 1, 2, 3])
    }

    /// The failure that matters most: two points claiming the same visiting
    /// position means one stop is driven twice and another is never driven at
    /// all, on a route that looks completely normal.
    @Test func refusesAnOrderThatVisitsOnePositionTwice() {
        #expect(throws: AppError.self) {
            try OSRMClient.visitingOrder(
                waypointIndices: [0, 0, 2], count: 3, fixFirst: false, fixLast: false)
        }
    }

    @Test func refusesAPositionOutsideTheTrip() {
        #expect(throws: AppError.self) {
            try OSRMClient.visitingOrder(
                waypointIndices: [0, 1, 7], count: 3, fixFirst: false, fixLast: false)
        }
        #expect(throws: AppError.self) {
            try OSRMClient.visitingOrder(
                waypointIndices: [0, 1, -1], count: 3, fixFirst: false, fixLast: false)
        }
    }

    @Test func refusesAResponseWithTheWrongNumberOfWaypoints() {
        #expect(throws: AppError.self) {
            try OSRMClient.visitingOrder(
                waypointIndices: [0, 1], count: 3, fixFirst: false, fixLast: false)
        }
    }

    /// The pinned ends are a dependency, not a request. The first visiting
    /// position is the node already written into the driving order and the last
    /// is the depot the tour has to finish at, so a response that moved either
    /// would be walked as if it had not.
    @Test func refusesAMovedStartWhenTheStartWasPinned() {
        // Input point 1 was visited first — the anchor was displaced.
        #expect(throws: AppError.self) {
            try OSRMClient.visitingOrder(
                waypointIndices: [1, 0, 2], count: 3, fixFirst: true, fixLast: false)
        }
    }

    @Test func refusesAMovedDestinationWhenTheEndWasPinned() {
        // Input point 2 (the destination) was visited second.
        #expect(throws: AppError.self) {
            try OSRMClient.visitingOrder(
                waypointIndices: [0, 2, 1], count: 3, fixFirst: false, fixLast: true)
        }
    }

    /// …but the same response is fine when nothing was pinned.
    @Test func allowsAReorderedEndWhenNothingWasPinned() throws {
        let order = try OSRMClient.visitingOrder(
            waypointIndices: [0, 2, 1], count: 3, fixFirst: false, fixLast: false)
        #expect(order == [0, 2, 1])
    }
}

/// Nominatim's usage policy is one request a second from one *client*, and it
/// is enforced against that client individually — so getting this wrong risks
/// the whole app being blocked, for every driver, over one bulk import.
struct NominatimThrottleTests {

    private let interval: TimeInterval = 1.1

    /// The bug this replaced: recording *the last call* left the actor free
    /// while a caller slept, so every caller that arrived during that sleep
    /// measured against the same stale timestamp, computed the same delay, and
    /// woke up to fire simultaneously — a burst, from the code whose whole job
    /// is to prevent one.
    @Test func thirtyCallersArrivingAtOnceAreSpacedOutRatherThanBursting() {
        let start = Date()
        var nextFree = Date.distantPast
        var fireTimes: [Date] = []

        // All thirty claim their slot at the same instant, which is what a bulk
        // import looks like.
        for _ in 0..<30 {
            let claim = Geocoder.claimSlot(now: start, nextFree: nextFree, interval: interval)
            nextFree = claim.nextFree
            fireTimes.append(claim.fireAt)
        }

        #expect(fireTimes.count == 30)
        #expect(fireTimes[0] == start)  // the first one waits for nothing
        for (earlier, later) in zip(fireTimes, fireTimes.dropFirst()) {
            #expect(later.timeIntervalSince(earlier) >= interval)
        }
    }

    /// A caller arriving long after the last one does not pay a delay it does
    /// not owe.
    @Test func aCallerArrivingAfterTheGapFiresImmediately() {
        let now = Date()
        let claim = Geocoder.claimSlot(
            now: now, nextFree: now.addingTimeInterval(-10), interval: interval)
        #expect(claim.fireAt == now)
        #expect(claim.nextFree == now.addingTimeInterval(interval))
    }

    /// …and one arriving inside the gap waits exactly the remainder.
    @Test func aCallerArrivingInsideTheGapWaitsOutTheRemainder() {
        let now = Date()
        let nextFree = now.addingTimeInterval(0.4)
        let claim = Geocoder.claimSlot(now: now, nextFree: nextFree, interval: interval)
        #expect(claim.fireAt == nextFree)
        // Compared with a tolerance, not `==`: a `Date` is a `Double` of
        // seconds and at today's magnitude it cannot represent 0.4 exactly.
        // (That same resolution limit is why `Stop.createdBefore` needs a
        // tiebreak at all.)
        #expect(abs(claim.fireAt.timeIntervalSince(now) - 0.4) < 0.000_001)
    }
}
