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
            for: EarRouterSchemaV3.Route.self, EarRouterSchemaV3.Stop.self,
            configurations: ModelConfiguration(url: url))
        let context = ModelContext(container)

        let route = EarRouterSchemaV3.Route(name: "Tour 04.09.2026")
        route.needsOptimize = true
        route.geometryFlat = [48.2, 16.3, 48.21, 16.31]
        context.insert(route)

        let start = EarRouterSchemaV3.Stop(
            kind: .start, kunde: "Start", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz,
            lat: Coordinates.start.lat, lon: Coordinates.start.lon, orderIndex: 0)
        let delivered = EarRouterSchemaV3.Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", paket: "2 Menü", notiz: "Bitte laut klingeln",
            lat: 48.2301, lon: 16.3201, orderIndex: 1,
            precision: .street, pinned: true)
        delivered.delivered = true
        delivered.nextLegKm = 3.2
        delivered.nextLegMin = 8
        let open = EarRouterSchemaV3.Stop(
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
        #expect(gruber.telefon == nil)
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
        #expect(EarRouterSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(EarRouterSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
        #expect(EarRouterSchemaV4.versionIdentifier == Schema.Version(4, 0, 0))
        #expect(EarRouterMigrationPlan.schemas.count == 4)
        #expect(EarRouterMigrationPlan.stages.count == 3)
    }

    /// SwiftData identifies entities by these stable names, not by the nested
    /// Swift type used to keep a historical schema frozen. If that ever
    /// changes, a V3 store would need an explicit renaming migration instead.
    /// No superseded version may name a *live* model.
    ///
    /// This is the discipline the frozen copies in `AppSchema` exist for, and
    /// until now it was kept by a comment alone. The newest version is allowed
    /// to name the live types — it *is* them. Every older one has to name its
    /// own frozen copy, because the moment a live model gains a field, a
    /// version still pointing at it silently gains that field too. A phone
    /// holding a store written at that version can then no longer be
    /// identified as the source of a migration, the open fails with "unknown
    /// model version", and `Store`'s recovery path moves the driver's tours
    /// aside and brings the app up empty — which is the exact outcome
    /// versioning the schema exists to avoid.
    ///
    /// It costs nothing today and everything on the morning someone adds a
    /// field for V5 and forgets to freeze V4 first. That is the morning this
    /// fails.
    @Test func onlySupersededVersionsAreFrozen() throws {
        let live: Set<ObjectIdentifier> = [
            ObjectIdentifier(Route.self),
            ObjectIdentifier(Stop.self),
            ObjectIdentifier(StockwerkNote.self),
        ]

        for schema in EarRouterMigrationPlan.schemas.dropLast() {
            for model in schema.models {
                #expect(
                    !live.contains(ObjectIdentifier(model)),
                    """
                    \(schema.versionIdentifier) still names a live model. Freeze a \
                    copy of it inside that version before changing the live one.
                    """)
            }
        }

        // And the current one names exactly the live models, so the store the
        // app opens is the store these tests describe.
        let current = try #require(EarRouterMigrationPlan.schemas.last)
        #expect(Set(current.models.map(ObjectIdentifier.init)) == live)
        #expect(current.versionIdentifier == AppSchema.current.version)
    }

    /// The frozen V3 models, property by property.
    ///
    /// `frozenV3ModelsKeepTheLiveEntityNames` pins that they are still *called*
    /// the same thing, which is what makes a V3 store recognisable. This pins
    /// that they still *contain* the same thing — the other half, and the half
    /// that drifts, because adding a field to a model is the ordinary act and
    /// copying it into a frozen version is the easy one to do by accident.
    ///
    /// Updating this list is meant to be deliberate: a frozen version's shape
    /// is a fact about stores that already exist on phones, not a preference.
    @Test func theFrozenV3ModelsStillHoldExactlyWhatV3Held() {
        let v3 = Schema(versionedSchema: EarRouterSchemaV3.self)
        func properties(_ name: String) -> [String] {
            (v3.entities.first { $0.name == name }?.properties ?? []).map(\.name).sorted()
        }

        #expect(properties("Route") == [
            "completedAt", "createdAt", "geometryFlat", "id", "name",
            "needsOptimize", "statusRaw", "stops",
        ])
        #expect(properties("Stop") == [
            "createdAt", "delivered", "excluded", "id", "kindRaw", "kunde",
            "lat", "lon", "nextLegKm", "nextLegMin", "notiz", "orderIndex",
            "paket", "pinned", "plz", "precisionRaw", "route", "strasse",
        ])
        #expect(properties("StockwerkNote") == [
            "dontAsk", "id", "key", "kunde", "plz", "stockwerk", "strasse",
            "updatedAt",
        ])
    }

    /// The one field V4 added, and the proof that freezing V3 actually froze
    /// it: the same entity, in the two versions, is not the same shape.
    @Test func v4AddedThePhoneNumberAndV3DidNotFollow() {
        let v3Stop = Schema(versionedSchema: EarRouterSchemaV3.self)
            .entities.first { $0.name == "Stop" }?.properties.map(\.name) ?? []
        let v4Stop = Schema(versionedSchema: EarRouterSchemaV4.self)
            .entities.first { $0.name == "Stop" }?.properties.map(\.name) ?? []

        #expect(!v3Stop.contains("telefon"))
        #expect(v4Stop.contains("telefon"))
        #expect(Set(v4Stop).subtracting(v3Stop) == ["telefon"])
    }

    @Test func frozenV3ModelsKeepTheLiveEntityNames() {
        #expect(Schema.entityName(for: EarRouterSchemaV3.Route.self) == Schema.entityName(for: Route.self))
        #expect(Schema.entityName(for: EarRouterSchemaV3.Stop.self) == Schema.entityName(for: Stop.self))
        #expect(
            Schema.entityName(for: EarRouterSchemaV3.StockwerkNote.self)
                == Schema.entityName(for: StockwerkNote.self))
    }

    /// V1 is the shape on a phone that has not seen the floor feature at all.
    /// Opening one of those stores must carry the tours over untouched and
    /// simply start the new table empty.
    @Test func aV1StoreOpensWithTheTourIntact() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }

        do {
            let v1 = try ModelContainer(
                for: Schema(versionedSchema: EarRouterSchemaV1.self),
                configurations: ModelConfiguration(
                    schema: Schema(versionedSchema: EarRouterSchemaV1.self), url: url))
            let context = ModelContext(v1)
            let route = EarRouterSchemaV3.Route(name: "Tour 04.09.2026")
            context.insert(route)
            let stop = EarRouterSchemaV3.Stop(
                kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
                plz: "1180", lat: 48.2301, lon: 16.3201, orderIndex: 1)
            stop.delivered = true
            stop.route = route
            context.insert(stop)
            try context.save()
        }

        let container = try AppSchema.container(url: url)
        let context = ModelContext(container)

        let route = try #require(try context.fetch(FetchDescriptor<Route>()).first)
        #expect(route.name == "Tour 04.09.2026")
        #expect(route.customerStops.first?.delivered == true)

        // The new table exists, is empty, and is writable — an empty
        // `StockwerkNote` table is exactly "nobody has been asked yet".
        #expect(try context.fetch(FetchDescriptor<StockwerkNote>()).isEmpty)
        let stop = try #require(route.customerStops.first)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: context)
        #expect(try context.fetch(FetchDescriptor<StockwerkNote>()).count == 1)
    }

    /// The store this build actually meets on the developer's own phone: one
    /// stamped V2, from the build where the floor was keyed by front door.
    ///
    /// The floors in it are dropped — they cannot be re-keyed to a customer who
    /// was never recorded — but the tours must not be. Without a describable
    /// V2 this open fails outright and `Store` parks a year of work.
    @Test func aV2StoreOpensAsV3WithTheTourIntact() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }

        do {
            let schema = Schema(versionedSchema: EarRouterSchemaV2.self)
            let v2 = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(v2)

            let route = EarRouterSchemaV3.Route(name: "Tour 05.09.2026")
            context.insert(route)
            let stop = EarRouterSchemaV3.Stop(
                kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
                plz: "1180", paket: "2 Menü", lat: 48.2301, lon: 16.3201, orderIndex: 1)
            stop.delivered = true
            stop.route = route
            context.insert(stop)

            let door = EarRouterSchemaV2.DoorNote(
                key: "gentzgasse 129 1|1180", strasse: "Gentzgasse 129/1", plz: "1180")
            door.stockwerk = "3"
            context.insert(door)
            try context.save()
        }

        let context = ModelContext(try AppSchema.container(url: url))

        let route = try #require(try context.fetch(FetchDescriptor<Route>()).first)
        #expect(route.name == "Tour 05.09.2026")
        let gruber = try #require(route.customerStops.first)
        #expect(gruber.delivered)
        #expect(gruber.paket == "2 Menü")

        // The floor is gone, and the customer is asked again — which is the
        // point: the old row could not say which household it belonged to.
        #expect(try StockwerkStore.all(in: context).isEmpty)
        #expect(StockwerkStore.shouldAsk(gruber, in: context))
    }

    /// And a floor written today is still there after a relaunch — the same
    /// check as the routes above, for the table that now holds the one thing
    /// in this app that exists nowhere else.
    @Test func aFloorSurvivesClosingAndReopeningTheStore() throws {
        let url = temporaryStoreURL()
        defer { removeStore(at: url) }

        do {
            let container = try AppSchema.container(url: url)
            let context = ModelContext(container)
            let stop = Stop(
                kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
                plz: "1180", lat: 48.2301, lon: 16.3201)
            context.insert(stop)
            try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: context)
        }

        let reopened = ModelContext(try AppSchema.container(url: url))
        let notes = try StockwerkStore.all(in: reopened)
        #expect(notes.count == 1)
        #expect(notes.first?.stockwerk == "3")
    }
}
