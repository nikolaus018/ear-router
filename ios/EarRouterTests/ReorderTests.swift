import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// "Reihenfolge ändern": the driver's own order, dragged into place.
@MainActor
struct ReorderTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A tour with its three fixed points and `names` as customers, listed in
    /// that order.
    private func tour(_ names: [String], in context: ModelContext) throws -> Route {
        let route = try RouteStore.createRoute(name: "Test", in: context)
        route.stops.first { $0.kind == .end }?.orderIndex = 100
        for (i, name) in names.enumerated() {
            let stop = Stop(
                kind: .customer, kunde: name, strasse: "Gasse \(i + 1)", plz: "1180",
                lat: 48.22 + Double(i) / 1000, lon: 16.33, orderIndex: 10 + i)
            stop.route = route
            context.insert(stop)
        }
        try context.save()
        return route
    }

    private func listed(_ route: Route) -> [String] {
        route.orderedStops.map { $0.kunde ?? "" }
    }

    private func ids(_ names: [String], in route: Route) -> [UUID] {
        names.compactMap { name in route.customerStops.first { $0.kunde == name }?.id }
    }

    @Test func theCustomersTakeTheDraggedOrder() throws {
        let context = try makeContext()
        let route = try tour(["A", "B", "C"], in: context)

        let moved = try RouteStore.reorder(
            route, customerIDs: ids(["C", "A", "B"], in: route), in: context)

        #expect(moved)
        #expect(listed(route) == ["Start", "Lager", "C", "A", "B", "Ziel"])
        // The line and the distances belong to the old order until OSRM has
        // answered for the new one.
        #expect(route.needsOptimize)
        #expect(route.geometryFlat.isEmpty)
        #expect(route.stops.allSatisfy { $0.nextLegKm == nil })
    }

    /// Remembered, so the next edit re-routes in this order instead of
    /// re-optimizing it away.
    @Test func aDraggedTourIsMarkedHandSorted() throws {
        let context = try makeContext()
        let route = try tour(["A", "B", "C"], in: context)
        #expect(!route.handOrdered)

        try RouteStore.reorder(route, customerIDs: ids(["B", "A", "C"], in: route), in: context)

        #expect(route.handOrdered)
    }

    /// And the mark survives a backup, so a restored tour is routed in the
    /// driver's order rather than re-optimized.
    @Test func theHandSortedMarkSurvivesABackup() throws {
        let source = try makeContext()
        let route = try tour(["A", "B", "C"], in: source)
        try RouteStore.reorder(route, customerIDs: ids(["C", "B", "A"], in: route), in: source)

        let archive = try BackupArchive.decode(BackupArchive.make(from: source).encoded())
        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let restored = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        #expect(restored.handOrdered)
        #expect(listed(restored) == ["Start", "Lager", "C", "B", "A", "Ziel"])
    }

    /// A backup written before the mark existed restores as not hand-sorted.
    @Test func anOlderBackupIsNotHandSorted() throws {
        let json = """
            {"format":"ear-router-backup","version":1,"routes":[{"id":"\(UUID())",
            "name":"Alt","status":"active","createdAt":"2026-09-01T08:00:00Z","needsOptimize":true,"stops":[]}]}
            """
        let archive = try BackupArchive.decode(Data(json.utf8))
        #expect(archive.routes.first?.handOrdered == nil)
    }

    /// Dropped where it started: nothing is written and nothing is re-routed.
    @Test func aDropInPlaceChangesNothing() throws {
        let context = try makeContext()
        let route = try tour(["A", "B", "C"], in: context)

        let moved = try RouteStore.reorder(
            route, customerIDs: ids(["A", "B", "C"], in: route), in: context)

        #expect(!moved)
        #expect(!route.needsOptimize)
    }

    /// A customer the list did not name — added from elsewhere mid-drag —
    /// is kept, after the ones that were.
    @Test func anUnnamedCustomerIsKeptAtTheEnd() throws {
        let context = try makeContext()
        let route = try tour(["A", "B", "C"], in: context)

        try RouteStore.reorder(route, customerIDs: ids(["C", "A"], in: route), in: context)

        #expect(listed(route) == ["Start", "Lager", "C", "A", "B", "Ziel"])
    }

    /// Driven exactly as listed, between whichever fixed points this tour
    /// actually drives.
    @Test func theListedOrderIsDrivenBetweenTheFixedPoints() {
        func coord(_ n: Int) -> StopCoord {
            StopCoord(id: UUID(), lat: 48.2 + Double(n) / 1000, lon: 16.3)
        }
        var nodes = RouteOptimizer.Nodes()
        nodes.start = RouteOptimizer.FixedStop(coord: coord(0), excluded: false)
        nodes.via = RouteOptimizer.FixedStop(coord: coord(1), excluded: true)
        nodes.end = RouteOptimizer.FixedStop(coord: coord(9), excluded: false)
        let customers = [coord(5), coord(3), coord(4)]

        let routed = RouteOptimizer.listedDrivingOrder(nodes, customers: customers)

        #expect(routed.map(\.id)
            == [nodes.start!.coord.id] + customers.map(\.id) + [nodes.end!.coord.id])
    }
}
