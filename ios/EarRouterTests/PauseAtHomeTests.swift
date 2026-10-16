import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// "Pause zu Hause": the driver's home as the last stop before Ziel, once the
/// driver has switched it on — and until then, nothing at all.
@MainActor
struct PauseAtHomeTests {

    private func coord(_ n: Int) -> StopCoord {
        StopCoord(id: UUID(), lat: 48.20 + Double(n) / 1000, lon: 16.30 + Double(n) / 1000)
    }

    private func nodes(customers: Int = 3, endExcluded: Bool = false) -> RouteOptimizer.Nodes {
        var n = RouteOptimizer.Nodes()
        n.start = RouteOptimizer.FixedStop(coord: coord(0), excluded: false)
        n.via = RouteOptimizer.FixedStop(coord: coord(1), excluded: false)
        n.end = RouteOptimizer.FixedStop(coord: coord(99), excluded: endExcluded)
        n.customers = (0..<customers).map { coord(10 + $0) }
        return n
    }

    /// How many legs the three OSRM calls in `run` hand back for this plan.
    private func legCount(_ plan: RouteOptimizer.Plan) -> Int {
        let fixed = plan.head.count + plan.driven.count + (plan.pauseDriven == nil ? 0 : 1)
        return max(0, fixed - 1)
            + (plan.needsTrip ? plan.tripNodes.count - 1 : 0)
            + max(0, plan.tail.count - 1)
    }

    // MARK: - Planning

    @Test func withoutAPauseNothingChanges() {
        let n = nodes()
        let plan = RouteOptimizer.plan(n)
        #expect(plan.tail.isEmpty)
        #expect(plan.pauseDriven == nil)
        #expect(plan.tripNodes.last == n.end?.coord)
        #expect(plan.fixLast)
    }

    /// The open doors finish at home, and Ziel is driven from there.
    @Test func theOpenDoorsAreSolvedToFinishAtHome() {
        var n = nodes()
        let home = coord(50)
        n.pause = home
        let plan = RouteOptimizer.plan(n)

        #expect(plan.tripNodes.last == home)
        #expect(plan.fixLast)
        #expect(plan.tail.map(\.id) == [home.id, n.end!.coord.id])
        #expect(!plan.tripNodes.contains { $0.id == n.end!.coord.id })

        let routed = RouteOptimizer.drivingOrder(
            plan, solvedOrder: Array(plan.tripNodes.indices))
        #expect(routed.suffix(2).map(\.id) == [home.id, n.end!.coord.id])
        #expect(Set(routed.map(\.id)).count == routed.count)
        #expect(legCount(plan) == routed.count - 1)
    }

    /// Ziel switched off: the tour simply ends at home.
    @Test func withoutAZielTheTourEndsAtHome() {
        var n = nodes(endExcluded: true)
        let home = coord(50)
        n.pause = home
        let plan = RouteOptimizer.plan(n)

        #expect(plan.tripNodes.last == home)
        #expect(plan.fixLast)
        #expect(plan.tail.isEmpty)
        let routed = RouteOptimizer.drivingOrder(
            plan, solvedOrder: Array(plan.tripNodes.indices))
        #expect(routed.last == home)
        #expect(legCount(plan) == routed.count - 1)
    }

    /// Every door done and the pause still to come: home, then Ziel.
    @Test func withNoDoorsLeftItIsHomeThenZiel() {
        var n = nodes(customers: 2)
        n.driven = n.customers
        let home = coord(50)
        n.pause = home
        let plan = RouteOptimizer.plan(n)

        #expect(plan.tripNodes.map(\.id) == [n.customers[1].id, home.id])
        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: [0, 1])
        #expect(routed.suffix(2).map(\.id) == [home.id, n.end!.coord.id])
        #expect(legCount(plan) == routed.count - 1)
    }

    /// Back from the pause with a door added since: the van is at home, so
    /// that door is planned from there, and on to Ziel.
    @Test func afterThePauseTheVanIsAtHome() {
        var n = nodes(customers: 3)
        n.driven = [n.customers[0], n.customers[1]]
        let home = coord(50)
        n.pause = home
        n.pauseDone = true
        let plan = RouteOptimizer.plan(n)

        #expect(plan.anchor == home)
        #expect(plan.pauseDriven == home)
        #expect(plan.tail.isEmpty)
        #expect(plan.tripNodes.map(\.id) == [home.id, n.customers[2].id, n.end!.coord.id])

        let routed = RouteOptimizer.drivingOrder(plan, solvedOrder: [0, 1, 2])
        #expect(routed.map(\.id).filter { $0 == home.id }.count == 1)
        #expect(legCount(plan) == routed.count - 1)
    }

    /// In the list the pause sits directly above Ziel.
    @Test func thePauseIsListedAboveZiel() {
        var n = nodes()
        let home = coord(50)
        n.pause = home
        let plan = RouteOptimizer.plan(n)
        let routed = RouteOptimizer.drivingOrder(
            plan, solvedOrder: Array(plan.tripNodes.indices))
        let display = RouteOptimizer.displayOrder(n, routed: routed)

        #expect(display.suffix(2).map(\.id) == [home.id, n.end!.coord.id])
        #expect(display.count == 2 + 3 + 2)

        let listed = RouteOptimizer.listedDrivingOrder(n, customers: n.customers)
        #expect(listed.suffix(2).map(\.id) == [home.id, n.end!.coord.id])
    }

    // MARK: - The switch

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private let home = HomeAddress(strasse: "Hausgasse 3", plz: "1210", lat: 48.27, lon: 16.41)

    private func tour(in context: ModelContext) throws -> Route {
        let route = try RouteStore.createRoute(name: "Test", in: context)
        for (i, name) in ["A", "B"].enumerated() {
            let stop = Stop(
                kind: .customer, kunde: name, strasse: "Gasse \(i + 1)", plz: "1180",
                lat: 48.22 + Double(i) / 1000, lon: 16.33, orderIndex: 3 + i)
            stop.route = route
            context.insert(stop)
        }
        RouteStore.keepZielLast(in: route)
        try context.save()
        return route
    }

    @Test func switchingOnPutsHomeAboveZiel() async throws {
        let context = try makeContext()
        let route = try tour(in: context)

        try await RouteStore.setPause(true, on: route, home: home, reroute: false, in: context)

        let kinds = route.orderedStops.map(\.kind)
        #expect(kinds.suffix(2) == [.pause, .end])
        let pause = try #require(route.stops.first { $0.kind == .pause })
        #expect(pause.strasse == "Hausgasse 3")
        #expect(pause.lat == 48.27)
        #expect(pause.isCheckpoint)
        #expect(!pause.canToggleExcluded)
        #expect(route.needsOptimize)
    }

    @Test func switchingOnTwiceAddsOnePause() async throws {
        let context = try makeContext()
        let route = try tour(in: context)
        try await RouteStore.setPause(true, on: route, home: home, reroute: false, in: context)
        try await RouteStore.setPause(true, on: route, home: home, reroute: false, in: context)
        #expect(route.stops.count { $0.kind == .pause } == 1)
    }

    @Test func switchingOffTakesItAway() async throws {
        let context = try makeContext()
        let route = try tour(in: context)
        try await RouteStore.setPause(true, on: route, home: home, reroute: false, in: context)
        try await RouteStore.setPause(false, on: route, home: home, reroute: false, in: context)
        #expect(!route.stops.contains { $0.kind == .pause })
        #expect(route.orderedStops.last?.kind == .end)
    }

    @Test func withoutAHomeAddressItSaysWhereToEnterOne() async throws {
        let context = try makeContext()
        let route = try tour(in: context)
        await #expect(throws: AppError.self) {
            try await RouteStore.setPause(true, on: route, home: nil, reroute: false, in: context)
        }
        #expect(!route.stops.contains { $0.kind == .pause })
    }

    /// A door added after the pause goes above it, not between it and Ziel.
    @Test func aStopAddedLaterStaysAboveThePause() async throws {
        let context = try makeContext()
        let route = try tour(in: context)
        try await RouteStore.setPause(true, on: route, home: home, reroute: false, in: context)

        let late = Stop(
            kind: .customer, kunde: "C", strasse: "Gasse 9", plz: "1180",
            lat: 48.23, lon: 16.33, orderIndex: RouteStore.nextOrderIndex(in: route))
        late.route = route
        context.insert(late)
        RouteStore.keepZielLast(in: route)

        #expect(route.orderedStops.suffix(3).map(\.kind) == [.customer, .pause, .end])
    }

    /// Dragging the doors into a new order leaves the pause above Ziel.
    @Test func reorderingKeepsThePauseAboveZiel() async throws {
        let context = try makeContext()
        let route = try tour(in: context)
        try await RouteStore.setPause(true, on: route, home: home, reroute: false, in: context)

        let ids = route.customerStops.map(\.id).reversed()
        try RouteStore.reorder(route, customerIDs: Array(ids), in: context)

        #expect(route.orderedStops.map { $0.kunde ?? "" }
            == ["Start", "Lager", "B", "A", "Pause", "Ziel"])
    }

    @Test func thePauseIsReadFromTheStoreAsAPause() async throws {
        let context = try makeContext()
        let route = try tour(in: context)
        try await RouteStore.setPause(true, on: route, home: home, reroute: false, in: context)

        let (n, _) = RouteOptimizer.snapshot(route)
        #expect(n.pause?.lat == 48.27)
        #expect(!n.pauseDone)
        #expect(!n.customers.contains { $0.lat == 48.27 })
    }

    // MARK: - The address

    @Test func theHomeAddressIsKeptOnThePhone() throws {
        let defaults = try #require(UserDefaults(suiteName: "PauseAtHomeTests.\(UUID())"))
        #expect(HomeAddress.load(from: defaults) == nil)

        home.save(to: defaults)
        #expect(HomeAddress.load(from: defaults) == home)

        HomeAddress.clear(in: defaults)
        #expect(HomeAddress.load(from: defaults) == nil)
    }

    /// A position that is not in Austria never reaches OSRM.
    @Test func anUnusablePositionIsNoHomeAtAll() throws {
        let defaults = try #require(UserDefaults(suiteName: "PauseAtHomeTests.\(UUID())"))
        HomeAddress(strasse: "Irgendwo 1", plz: "1210", lat: 0, lon: 0).save(to: defaults)
        #expect(HomeAddress.load(from: defaults) == nil)
    }
}

/// What the confirmation says before the pause goes on.
@MainActor
struct PauseDetourTests {
    private let three = Date(timeIntervalSince1970: 1_757_000_000)

    /// The drive only: how long the pause takes is the driver's business.
    @Test func itSaysTheDetourAndTheNewZielTime() {
        let text = PauseDetour.summary(
            PauseDetour(minutes: 14, km: 6.2), zielBefore: three, endsAtHome: false)
        let later = Format.time(three.addingTimeInterval(14 * 60))
        #expect(text == "Umweg +14 min · 6,2 km. Am Ziel ca. \(later) "
            + "statt \(Format.time(three)), plus die Pause.")
    }

    @Test func aTourEndingAtHomeSaysSo() {
        let text = PauseDetour.summary(
            PauseDetour(minutes: 5, km: 2), zielBefore: nil, endsAtHome: true)
        #expect(text == "Umweg +5 min · 2,0 km. Die Tour endet dann zu Hause.")
    }

    @Test func withoutAZielTimeItSaysTheDetourAlone() {
        let text = PauseDetour.summary(
            PauseDetour(minutes: 5, km: 2), zielBefore: nil, endsAtHome: false)
        #expect(text == "Umweg +5 min · 2,0 km.")
    }

    @Test func withoutOSRMItSaysItCouldNotTell() {
        let text = PauseDetour.summary(nil, zielBefore: three, endsAtHome: false)
        #expect(text == "Der Umweg konnte gerade nicht berechnet werden.")
    }

    private func c(_ n: Int) -> StopCoord {
        StopCoord(id: UUID(), lat: 48.2 + Double(n) / 1000, lon: 16.3)
    }

    /// A hand-sorted tour: only the drive out of the last door differs.
    @Test func aHandSortedTourComparesOnlyItsEnd() {
        let (start, x, y, home, ziel) = (c(0), c(1), c(2), c(3), c(4))
        let (a, b) = RouteOptimizer.listedEnds(
            [start, x, y, ziel], [start, x, y, home, ziel], hasEnd: true)
        #expect(a == [y, ziel])
        #expect(b == [y, home, ziel])

        let (open, toHome) = RouteOptimizer.listedEnds(
            [start, x, y], [start, x, y, home], hasEnd: false)
        #expect(open == [y])
        #expect(toHome == [y, home])
    }
}
