import Testing
import Foundation
import SwiftData
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

    // MARK: - Mid-tour

    /// Once doors are answered for, the trip starts at the last one — where
    /// the van is — and only the open customers are handed to OSRM.
    @Test func midTourTheTripStartsAtTheLastDoorAnsweredFor() {
        var (n, customers) = nodes(customers: 4)
        n.driven = [customers[0], customers[2]]
        let plan = RouteOptimizer.plan(n)

        #expect(plan.anchor == customers[2])
        #expect(plan.tripNodes.map(\.id)
            == [customers[2].id, customers[1].id, customers[3].id, plan.tripNodes.last!.id])
        #expect(plan.fixFirst)
    }

    /// The driven doors stay in front, in their order; the open ones follow
    /// in OSRM's, and nobody is listed twice.
    @Test func midTourTheDrivenDoorsKeepTheirPlaceInFront() {
        var (n, customers) = nodes(customers: 4)
        n.driven = [customers[0], customers[2]]
        let plan = RouteOptimizer.plan(n)
        // Anchor, then the two open customers reversed, then the destination.
        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: [0, 2, 1, 3])
        let display = RouteOptimizer.displayOrder(n, routed: routed)
        let customerIDs = Set(customers.map(\.id))

        #expect(display.map(\.id).filter { customerIDs.contains($0) }
            == [customers[0], customers[2], customers[3], customers[1]].map(\.id))
        #expect(Set(routed.map(\.id)).count == routed.count)
    }

    /// Nothing answered for yet: planned exactly as before.
    @Test func beforeTheFirstDoorNothingChanges() {
        let (n, _) = nodes(customers: 3)
        let plan = RouteOptimizer.plan(n)
        #expect(plan.driven.isEmpty)
        #expect(plan.anchor == plan.head.last)
    }

    /// Where the van is, taken off the times, not the list: and an abbestellt
    /// tick, made in the yard, says nothing about where it is.
    @Test func theVanIsAtTheDoorAnsweredForLast() throws {
        let container = try ModelContainer(
            for: Route.self, Stop.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = Route(name: "Test")
        context.insert(route)
        let names = ["A", "B", "C", "D"]
        let stops = names.enumerated().map { i, name in
            Stop(kind: .customer, kunde: name, strasse: "Gasse \(i)", plz: "1180",
                 lat: 48.20 + Double(i) / 1000, lon: 16.32, orderIndex: i)
        }
        for s in stops {
            s.route = route
            context.insert(s)
        }
        let t = Date(timeIntervalSince1970: 1_757_000_000)
        stops[1].record(.delivered, at: t.addingTimeInterval(600))
        stops[0].record(.notHome, at: t.addingTimeInterval(60))
        stops[3].record(.cancelled, at: t)

        let driven = RouteOptimizer.driven(route).map(\.id)
        #expect(driven == [stops[0].id, stops[1].id])
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

/// How long the self-hosted router gets before the app gives up on it and
/// asks the public demo server instead.
///
/// The deadline exists for a primary that accepts a connection and then stalls,
/// and it used to be a flat four seconds for every call — which quietly made it
/// a cap on how hard the router is allowed to *think*. A `/route` over two
/// points answers in milliseconds; a `/trip` over ninety-seven customers is a
/// travelling-salesman solve and legitimately takes seconds. So the flat
/// version timed out a perfectly healthy server on exactly the tours that need
/// it, put it in a minute-long cooldown, and sent the work to a shared demo
/// server sitting at its own hundred-waypoint ceiling.
struct OSRMDeadlineTests {

    /// A two-point leg still gets the short deadline it always had.
    @Test func aFixedLegKeepsTheShortDeadline() {
        #expect(OSRMClient.primaryDeadline(waypoints: 2) == 4)
    }

    /// Degenerate counts cannot pull it below the base.
    @Test func neverShorterThanTheBase() {
        #expect(OSRMClient.primaryDeadline(waypoints: 0) == 4)
        #expect(OSRMClient.primaryDeadline(waypoints: 1) == 4)
    }

    /// A full tour gets meaningfully longer, and the growth is monotonic — a
    /// bigger problem is never given less time than a smaller one.
    @Test func afullTourGetsRoomToSolve() {
        let small = OSRMClient.primaryDeadline(waypoints: 10)
        let full = OSRMClient.primaryDeadline(waypoints: osrmMaxTripCoords)
        #expect(small > 4)
        #expect(full > small)
        #expect(full > 15)
    }

    /// Never past the URL session's own request timeout: a deadline longer
    /// than that can never fire, so it would silently stop being a deadline.
    @Test func neverOutlivesTheRequestTimeout() {
        #expect(OSRMClient.primaryDeadline(waypoints: osrmMaxTripCoords) <= 20)
        #expect(OSRMClient.primaryDeadline(waypoints: 10_000) <= 20)
    }
}

/// Writing one finished solution back onto the route.
///
/// This is what the driver actually reads: the order the rows appear in, the
/// "→ 3,2 km · 8 min" under each one, and whether the amber "Route nicht
/// aktuell" banner is still there. All of it sat behind seconds of OSRM calls
/// where no test could reach it.
@MainActor
struct OptimizerWriteBackTests {

    private func makeRoute() throws -> (Route, ModelContext, [Stop]) {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        var customers: [Stop] = []
        for (i, name) in ["Fam. Gruber", "Hr. Novak", "Fr. Huber"].enumerated() {
            let stop = Stop(
                kind: .customer, kunde: name, strasse: "Gasse \(i)", plz: "1180",
                lat: 48.23 + Double(i) / 1000, lon: 16.32, orderIndex: 99)
            stop.route = route
            context.insert(stop)
            customers.append(stop)
        }
        try context.save()
        return (route, context, customers)
    }

    /// The whole thing, driven the way `run` drives it: snapshot, plan, walk
    /// OSRM's answer back, write.
    private func optimize(
        _ route: Route, in context: ModelContext,
        order: [Int]? = nil, legs: [(Double, Double)]? = nil,
        plannedFrom: RouteOptimizer.Fingerprint? = nil
    ) throws {
        let (nodes, taken) = RouteOptimizer.snapshot(route)
        let plan = RouteOptimizer.plan(nodes)
        let solved = order ?? Array(plan.tripNodes.indices)
        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: solved)
        var madeUpLegs: [(Double, Double)] = legs ?? []
        if legs == nil {
            let gaps: Int = max(0, routed.count - 1)
            for i in 0..<gaps {
                let metres = Double(i + 1) * 1000.0
                let seconds = Double(i + 1) * 60.0
                madeUpLegs.append((metres, seconds))
            }
        }
        try RouteOptimizer.apply(
            nodes, routed: routed, legs: madeUpLegs, geometry: [[48.2, 16.3], [48.3, 16.4]],
            plannedFrom: plannedFrom ?? taken, to: route, in: context)
    }

    @Test func theRowsAreNumberedFromTheTopWithNoGaps() throws {
        let (route, context, _) = try makeRoute()
        try optimize(route, in: context)

        let indices = route.orderedStops.map(\.orderIndex)
        #expect(indices == Array(0..<route.stops.count))
        // Start and Lager at the top, Ziel at the bottom — a fixed point keeps
        // its place in the list whatever the solve did with the customers.
        #expect(route.orderedStops.first?.kind == .start)
        #expect(route.orderedStops.last?.kind == .end)
    }

    /// A leg belongs to the drive *out* of a stop, so the last one has none.
    @Test func theLastStopCarriesNoLeg() throws {
        let (route, context, _) = try makeRoute()
        try optimize(route, in: context)

        let last = try #require(route.orderedStops.last)
        #expect(last.nextLegKm == nil)
        #expect(last.nextLegMin == nil)
        #expect(route.orderedStops.dropLast().allSatisfy { $0.nextLegKm != nil })
    }

    /// Metres and seconds in, kilometres and minutes out.
    @Test func theLegsArriveInTheUnitsTheRowShows() throws {
        let (route, context, _) = try makeRoute()
        try optimize(route, in: context, legs: [
            (3_250, 510), (1_000, 60), (2_000, 120), (4_000, 240), (5_000, 300),
        ])
        let first = try #require(route.orderedStops.first)
        #expect(first.nextLegKm == 3.25)
        #expect(first.nextLegMin == 8.5)
    }

    /// Stale distances are cleared rather than left behind — a stop switched
    /// out of the tour must not keep the leg it used to drive.
    @Test func aStopThatIsNoLongerDrivenLosesItsOldLeg() throws {
        let (route, context, _) = try makeRoute()
        try optimize(route, in: context)
        let via = try #require(route.stops.first { $0.kind == .via })
        #expect(via.nextLegKm != nil)

        via.excluded = true
        try context.save()
        try optimize(route, in: context)

        #expect(via.nextLegKm == nil)
        #expect(via.nextLegMin == nil)
        // And it keeps its place in the list rather than being flushed to the end.
        #expect(route.orderedStops.map(\.kind).prefix(2) == [.start, .via])
    }

    // MARK: - The flag

    @Test func aSolutionThatStillDescribesTheRouteClearsTheBanner() throws {
        let (route, context, _) = try makeRoute()
        route.needsOptimize = true
        try optimize(route, in: context)
        #expect(!route.needsOptimize)
        #expect(!route.geometryFlat.isEmpty)
    }

    /// The one that is not self-correcting. A stop added while OSRM was
    /// answering means this solution is already stale; its order and geometry
    /// are still worth writing, but clearing the flag would leave the route
    /// claiming to be current — and if the next run then fails, there is no
    /// banner and no retry, with wrong distances all day.
    @Test func aRouteThatChangedWhileSolvingStaysFlagged() throws {
        let (route, context, _) = try makeRoute()
        let plannedFrom = RouteOptimizer.snapshot(route).1

        // The edit that lands mid-solve.
        let late = Stop(
            kind: .customer, kunde: "Fam. Wagner", strasse: "Spätgasse 1", plz: "1180",
            lat: 48.26, lon: 16.32)
        late.route = route
        context.insert(late)
        try context.save()

        try optimize(route, in: context, plannedFrom: plannedFrom)

        #expect(route.needsOptimize)
        // Written anyway: a fresher-than-nothing solution beats the old one.
        #expect(!route.geometryFlat.isEmpty)
    }

    /// Moving a stop counts; editing a note does not, or every tour would sit
    /// permanently flagged over a corrected spelling.
    @Test func onlyAMoveLeavesTheRouteFlagged() throws {
        let (route, context, customers) = try makeRoute()
        let plannedFrom = RouteOptimizer.snapshot(route).1
        customers[0].notiz = "Bitte laut klingeln"
        customers[0].kunde = "Familie Gruber"
        try context.save()

        try optimize(route, in: context, plannedFrom: plannedFrom)
        #expect(!route.needsOptimize)
    }
}
