import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// The store on a driver's phone right now was written by a build that opened
/// it with no schema version and no migration plan. Attaching both must be
/// invisible to that file — if it is not, the app falls through to `Store`'s
/// recovery path on next launch and comes up empty, which is the exact outcome
/// versioning the schema was meant to make less likely.
///
/// So this is not a test of SwiftData. It is the check that this change is
/// safe to ship to a phone that already has a tour on it.
@MainActor
struct SchemaMigrationTests {

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ear-router-test-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// A full day's work, written exactly the way the shipping build writes it.
    private func writeATourTheOldWay(at url: URL) throws {
        // `ModelContainer(for:configurations:)` with a bare `ModelConfiguration`
        // is the unversioned open this replaces.
        let container = try ModelContainer(
            for: Route.self, Stop.self,
            configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)

        let route = Route(name: "Tour 04.09.2026")
        route.needsOptimize = true
        route.geometryFlat = [48.2, 16.3, 48.21, 16.31]
        context.insert(route)

        let start = Stop(
            kind: .start, kunde: "Start", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz,
            lat: Coordinates.start.lat, lon: Coordinates.start.lon, orderIndex: 0)
        let delivered = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", paket: "2 Menü", notiz: "Bitte laut klingeln",
            lat: 48.2301, lon: 16.3201, orderIndex: 1,
            precision: .street, pinned: true)
        delivered.delivered = true
        delivered.nextLegKm = 3.2
        delivered.nextLegMin = 8
        let open = Stop(
            kind: .customer, kunde: "Fam. Novak", strasse: "Währinger Straße 4",
            plz: "1180", lat: 48.2312, lon: 16.3222, orderIndex: 2)

        for s in [start, delivered, open] {
            s.route = route
            context.insert(s)
        }
        try context.save()
    }

    /// The one that matters: nothing is lost, and nothing is quietly reset.
    @Test func aStoreWrittenBeforeVersioningOpensWithEverythingIntact() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }

        try writeATourTheOldWay(at: url)

        let container = try AppSchema.container(url: url)
        let context = ModelContext(container)
        let routes = try context.fetch(FetchDescriptor<Route>())

        #expect(routes.count == 1)
        let route = try #require(routes.first)
        #expect(route.name == "Tour 04.09.2026")
        #expect(route.needsOptimize)
        #expect(route.geometryFlat.count == 4)
        #expect(route.stops.count == 3)

        // The delivered tick above all — it is the thing on this route that
        // cannot be reconstructed from anywhere else.
        let customers = route.customerStops
        #expect(customers.count == 2)
        let gruber = try #require(customers.first { $0.kunde == "Fam. Gruber" })
        #expect(gruber.delivered)
        #expect(gruber.paket == "2 Menü")
        #expect(gruber.notiz == "Bitte laut klingeln")
        #expect(gruber.precision == .street)
        #expect(gruber.pinned)
        #expect(gruber.nextLegKm == 3.2)
        #expect(customers.first { $0.kunde == "Fam. Novak" }?.delivered == false)

        // Enum-backed columns survive as their enums, not as raw strings that
        // silently fall back to a default.
        #expect(route.status == .active)
        #expect(route.stops.contains { $0.kind == .start })
    }

    /// And the versioned container can be written to and reopened — a migration
    /// plan that only ever works on the first open is not a migration plan.
    @Test func theVersionedStoreRoundTripsItsOwnWrites() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }

        do {
            let container = try AppSchema.container(url: url)
            let context = ModelContext(container)
            let route = try RouteStore.createRoute(name: "Neu", in: context)
            #expect(route.stops.count == 3)
        }

        let reopened = try AppSchema.container(url: url)
        let context = ModelContext(reopened)
        let routes = try context.fetch(FetchDescriptor<Route>())
        #expect(routes.count == 1)
        #expect(routes.first?.stops.count == 3)
    }

    /// The version is the anchor every future migration is written against, so
    /// changing it is a deliberate act rather than a typo.
    @Test func declaresTheVersionItsStagesWillBeWrittenAgainst() {
        #expect(EarRouterSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(EarRouterMigrationPlan.schemas.count == 1)
        #expect(EarRouterMigrationPlan.stages.isEmpty)
    }
}
