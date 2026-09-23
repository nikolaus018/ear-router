import Foundation
import SwiftData

/// The store's schema, with a version attached to it.
///
/// Until now the container was opened as `ModelContainer(for: Route.self,
/// Stop.self)` — no version, no migration plan. That works exactly as long as
/// every future model change is one SwiftData can infer on its own. The moment
/// one is not (a renamed property, a split entity, an attribute that has to be
/// computed from the old data), the open fails, and what catches it is
/// `Store`'s recovery path: the driver's tours are moved aside and the app
/// comes up empty. That is the right *last* resort and the wrong plan.
///
/// This gives migrations somewhere to live before they are needed. The version
/// is the anchor; a future `V2` describes what changed and a `MigrationStage`
/// describes how to get there, and neither is something anyone wants to be
/// inventing on the morning it first matters.
enum EarRouterSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// The two models as they were before `StockwerkNote` existed. These are
    /// deliberately the frozen V3 copies rather than the live types: a schema
    /// version must never silently acquire attributes added in a later build.
    static var models: [any PersistentModel.Type] {
        [EarRouterSchemaV3.Route.self, EarRouterSchemaV3.Stop.self]
    }
}

/// V2 added `DoorNote` — the floor, keyed by the *front door*.
///
/// That key was wrong, and the model is kept here only because a store stamped
/// with this version exists. Two households in one Gemeindebau share a front
/// door and do not share a floor: the second one inherited the first one's
/// answer and was never asked about. V3 re-keys by customer.
///
/// This version pins its own copy of the model rather than the live type,
/// which is what a superseded version has to do. Without it, a phone holding a
/// V2 store meets a migration plan that cannot name the version it is on, the
/// open fails with "unknown model version", and `Store`'s recovery path moves
/// the tours aside and brings the app up empty — which is exactly the outcome
/// versioning the schema exists to avoid.
enum EarRouterSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [EarRouterSchemaV3.Route.self, EarRouterSchemaV3.Stop.self, DoorNote.self]
    }

    /// V2's floor table, keyed per door. Nested, so it keeps the entity name
    /// the store was written with while the live model is called something
    /// else.
    @Model
    final class DoorNote {
        var id: UUID = UUID()
        var key: String = ""
        var strasse: String = ""
        var plz: String = ""
        var stockwerk: String?
        var dontAsk: Bool = false
        var updatedAt: Date = Date()

        init(key: String = "", strasse: String = "", plz: String = "") {
            self.key = key
            self.strasse = strasse
            self.plz = plz
        }
    }
}

/// V3 re-keys the floor by customer, as `StockwerkNote`.
///
/// A new entity beside the old one rather than a rename: the two are keyed
/// differently — "gentzgasse 129 1|1180" against "fam gruber|gentzgasse 129
/// 1|1180" — so there is no row-by-row translation that would be correct. A
/// name cannot be invented for an answer stored without one, and guessing
/// which of two households at a door a stored floor belonged to is precisely
/// the bug this version exists to fix. The old table is dropped, and the
/// handful of floors in it are asked for once more.
enum EarRouterSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Route.self, Stop.self, StockwerkNote.self]
    }

    /// The models as shipped in V3. Keep these copies frozen: the V4 phone
    /// field belongs only to the live models, otherwise a V3 store can no
    /// longer be identified as the source of a migration.
    @Model
    final class Route {
        var id: UUID = UUID()
        var name: String = ""
        var statusRaw: String = RouteStatus.active.rawValue
        var createdAt: Date = Date()
        var completedAt: Date?
        var geometryFlat: [Double] = []
        var needsOptimize: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \Stop.route)
        var stops: [Stop] = []

        init(name: String = "") {
            self.id = UUID()
            self.name = name
            self.statusRaw = RouteStatus.active.rawValue
            self.createdAt = Date()
            self.geometryFlat = []
            self.needsOptimize = false
            self.stops = []
        }
    }

    @Model
    final class Stop {
        var id: UUID = UUID()
        var kindRaw: String = StopKind.customer.rawValue
        var kunde: String?
        var strasse: String?
        var plz: String?
        var paket: String?
        var notiz: String?
        var lat: Double = 0
        var lon: Double = 0
        var orderIndex: Int = 0
        var delivered: Bool = false
        var nextLegKm: Double?
        var nextLegMin: Double?
        var createdAt: Date = Date()
        var excluded: Bool = false
        var pinned: Bool = false
        var precisionRaw: String?
        var route: Route?

        init(
            kind: StopKind = .customer,
            kunde: String? = nil,
            strasse: String? = nil,
            plz: String? = nil,
            paket: String? = nil,
            notiz: String? = nil,
            lat: Double = 0,
            lon: Double = 0,
            orderIndex: Int = 0,
            precision: Precision? = nil,
            pinned: Bool = false,
            excluded: Bool = false
        ) {
            self.id = UUID()
            self.kindRaw = kind.rawValue
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.paket = paket
            self.notiz = notiz
            self.lat = lat
            self.lon = lon
            self.orderIndex = orderIndex
            self.delivered = false
            self.createdAt = Date()
            self.excluded = excluded
            self.pinned = pinned
            self.precisionRaw = precision?.rawValue
        }
    }

    @Model
    final class StockwerkNote {
        var id: UUID = UUID()
        var key: String = ""
        var kunde: String = ""
        var strasse: String = ""
        var plz: String = ""
        var stockwerk: String?
        var dontAsk: Bool = false
        var updatedAt: Date = Date()

        init(
            key: String = "", kunde: String = "", strasse: String = "", plz: String = "",
            stockwerk: String? = nil, dontAsk: Bool = false
        ) {
            self.id = UUID()
            self.key = key
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.stockwerk = stockwerk
            self.dontAsk = dontAsk
            self.updatedAt = Date()
        }
    }
}

/// V4 adds the optional customer phone number to `Stop`.
enum EarRouterSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Route.self, Stop.self, StockwerkNote.self]
    }

    /// The models as shipped in V4 — V3's, plus `telefon`. Frozen for the same
    /// reason V3's are, and frozen *now* because V5 is the first change to the
    /// live models since this version shipped: a superseded version still
    /// naming a live type silently acquires every field added after it, and a
    /// phone holding a V4 store then cannot be identified as the source of a
    /// migration. `onlySupersededVersionsAreFrozen` is the test that says so.
    @Model
    final class Route {
        var id: UUID = UUID()
        var name: String = ""
        var statusRaw: String = RouteStatus.active.rawValue
        var createdAt: Date = Date()
        var completedAt: Date?
        var geometryFlat: [Double] = []
        var needsOptimize: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \Stop.route)
        var stops: [Stop] = []

        init(name: String = "") {
            self.id = UUID()
            self.name = name
            self.statusRaw = RouteStatus.active.rawValue
            self.createdAt = Date()
            self.geometryFlat = []
            self.needsOptimize = false
            self.stops = []
        }
    }

    @Model
    final class Stop {
        var id: UUID = UUID()
        var kindRaw: String = StopKind.customer.rawValue
        var kunde: String?
        var strasse: String?
        var plz: String?
        var paket: String?
        var notiz: String?
        var telefon: String?
        var lat: Double = 0
        var lon: Double = 0
        var orderIndex: Int = 0
        var delivered: Bool = false
        var nextLegKm: Double?
        var nextLegMin: Double?
        var createdAt: Date = Date()
        var excluded: Bool = false
        var pinned: Bool = false
        var precisionRaw: String?
        var route: Route?

        init(
            kind: StopKind = .customer,
            kunde: String? = nil,
            strasse: String? = nil,
            plz: String? = nil,
            paket: String? = nil,
            notiz: String? = nil,
            telefon: String? = nil,
            lat: Double = 0,
            lon: Double = 0,
            orderIndex: Int = 0,
            precision: Precision? = nil,
            pinned: Bool = false,
            excluded: Bool = false
        ) {
            self.id = UUID()
            self.kindRaw = kind.rawValue
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.paket = paket
            self.notiz = notiz
            self.telefon = telefon
            self.lat = lat
            self.lon = lon
            self.orderIndex = orderIndex
            self.delivered = false
            self.createdAt = Date()
            self.excluded = excluded
            self.pinned = pinned
            self.precisionRaw = precision?.rawValue
        }
    }

    @Model
    final class StockwerkNote {
        var id: UUID = UUID()
        var key: String = ""
        var kunde: String = ""
        var strasse: String = ""
        var plz: String = ""
        var stockwerk: String?
        var dontAsk: Bool = false
        var updatedAt: Date = Date()

        init(
            key: String = "", kunde: String = "", strasse: String = "", plz: String = "",
            stockwerk: String? = nil, dontAsk: Bool = false
        ) {
            self.id = UUID()
            self.key = key
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.stockwerk = stockwerk
            self.dontAsk = dontAsk
            self.updatedAt = Date()
        }
    }
}

/// V5 records *what happened* at a door rather than one delivered bit, stamps
/// the time it was said, lets a stop be pinned to the front of the tour, and
/// keeps what a driver learns in a stairwell beside the floor.
///
/// Lightweight, and that is by design rather than by luck. Every field it adds
/// is optional or has a default, and the one fact that would otherwise need
/// rewriting — that an already-ticked stop was *delivered* — is read back out
/// of the `delivered` bit those rows already carry, by `Stop.outcome`. Nothing
/// on the phone is rewritten on the morning this build first opens the store.
///
/// Its floor table briefly split what a driver knows about a customer into
/// three columns — a Türcode, a "lange läuten" switch, and a note. V6 folds
/// them back into one note. This version is frozen rather than edited in place
/// because a store stamped with it can exist: opening one against an amended
/// V5 fails with "unknown model version", and what catches that is `Store`'s
/// recovery path, which parks a year of tours and brings the app up empty.
/// That was watched happening once, on a simulator, which was one time more
/// than it needs to happen on a phone in a van.
enum EarRouterSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Route.self, Stop.self, StockwerkNote.self]
    }

    @Model
    final class Route {
        var id: UUID = UUID()
        var name: String = ""
        var statusRaw: String = RouteStatus.active.rawValue
        var createdAt: Date = Date()
        var completedAt: Date?
        var geometryFlat: [Double] = []
        var needsOptimize: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \Stop.route)
        var stops: [Stop] = []

        init(name: String = "") {
            self.id = UUID()
            self.name = name
            self.statusRaw = RouteStatus.active.rawValue
            self.createdAt = Date()
            self.geometryFlat = []
            self.needsOptimize = false
            self.stops = []
        }
    }

    @Model
    final class Stop {
        var id: UUID = UUID()
        var kindRaw: String = StopKind.customer.rawValue
        var kunde: String?
        var strasse: String?
        var plz: String?
        var paket: String?
        var notiz: String?
        var telefon: String?
        var lat: Double = 0
        var lon: Double = 0
        var orderIndex: Int = 0
        var delivered: Bool = false
        var outcomeRaw: String?
        var settledAt: Date?
        var prioritaet: Bool = false
        var nextLegKm: Double?
        var nextLegMin: Double?
        var createdAt: Date = Date()
        var excluded: Bool = false
        var pinned: Bool = false
        var precisionRaw: String?
        var route: Route?

        init(kind: StopKind = .customer, lat: Double = 0, lon: Double = 0) {
            self.id = UUID()
            self.kindRaw = kind.rawValue
            self.lat = lat
            self.lon = lon
            self.createdAt = Date()
        }
    }

    /// V5's floor table, with the three columns V6 folds back into one note.
    @Model
    final class StockwerkNote {
        var id: UUID = UUID()
        var key: String = ""
        var kunde: String = ""
        var strasse: String = ""
        var plz: String = ""
        var stockwerk: String?
        var tuerNotiz: String?
        var tuercode: String?
        var langeLaeuten: Bool = false
        var dontAsk: Bool = false
        var updatedAt: Date = Date()

        init(key: String = "", kunde: String = "", strasse: String = "", plz: String = "") {
            self.id = UUID()
            self.key = key
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.updatedAt = Date()
        }
    }
}

/// V6 folds the three columns V5 kept about a customer's door back into one
/// free-text note.
///
/// The split was the wrong shape for what it held. The things worth writing
/// down at a door are a list with no end — a code, a bell that has to be held,
/// a dog, a neighbour who takes the meal, a lift that has been broken since May
/// — and every one of them is a sentence somebody would write anyway. A form of
/// labelled boxes is slower to fill in standing at a door than one line to type
/// into, and it can only ever hold the handful of cases somebody thought of.
///
/// Lightweight: two columns go, one arrives, and the floor — the thing this
/// table was made for and the thing that took a year of stairwells to learn —
/// is untouched by either. What the dropped columns held is not carried across
/// in the store, and does not need to be: `BackupArchive` folds all three into
/// the note when it reads a file that has them.
enum EarRouterSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Route.self, Stop.self, StockwerkNote.self]
    }

    @Model
    final class Route {
        var id: UUID = UUID()
        var name: String = ""
        var statusRaw: String = RouteStatus.active.rawValue
        var createdAt: Date = Date()
        var completedAt: Date?
        var geometryFlat: [Double] = []
        var needsOptimize: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \Stop.route)
        var stops: [Stop] = []

        init(name: String = "") {
            self.id = UUID()
            self.name = name
            self.statusRaw = RouteStatus.active.rawValue
            self.createdAt = Date()
            self.geometryFlat = []
            self.needsOptimize = false
            self.stops = []
        }
    }

    @Model
    final class Stop {
        var id: UUID = UUID()
        var kindRaw: String = StopKind.customer.rawValue
        var kunde: String?
        var strasse: String?
        var plz: String?
        var paket: String?
        var notiz: String?
        var telefon: String?
        var lat: Double = 0
        var lon: Double = 0
        var orderIndex: Int = 0
        var delivered: Bool = false
        var outcomeRaw: String?
        var settledAt: Date?
        var prioritaet: Bool = false
        var nextLegKm: Double?
        var nextLegMin: Double?
        var createdAt: Date = Date()
        var excluded: Bool = false
        var pinned: Bool = false
        var precisionRaw: String?
        var route: Route?

        init(kind: StopKind = .customer, lat: Double = 0, lon: Double = 0) {
            self.id = UUID()
            self.kindRaw = kind.rawValue
            self.lat = lat
            self.lon = lon
            self.createdAt = Date()
        }
    }

    @Model
    final class StockwerkNote {
        var id: UUID = UUID()
        var key: String = ""
        var kunde: String = ""
        var strasse: String = ""
        var plz: String = ""
        var stockwerk: String?
        var notiz: String?
        var dontAsk: Bool = false
        var updatedAt: Date = Date()

        init(key: String = "", kunde: String = "", strasse: String = "", plz: String = "") {
            self.id = UUID()
            self.key = key
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.updatedAt = Date()
        }
    }
}

/// V7 stores each stop's entrance — the point the register gives its house
/// number on the street — beside the building point, for the navigation app.
///
/// Lightweight: two optional columns arrive, empty on every stop already on
/// the phone, and nothing else moves. Those stops keep being navigated to by
/// address until "Adressen prüfen" or a re-import fills them in.
enum EarRouterSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Route.self, Stop.self, StockwerkNote.self]
    }

    @Model
    final class Route {
        var id: UUID = UUID()
        var name: String = ""
        var statusRaw: String = RouteStatus.active.rawValue
        var createdAt: Date = Date()
        var completedAt: Date?
        var geometryFlat: [Double] = []
        var needsOptimize: Bool = false

        @Relationship(deleteRule: .cascade, inverse: \Stop.route)
        var stops: [Stop] = []

        init(name: String = "") {
            self.id = UUID()
            self.name = name
            self.statusRaw = RouteStatus.active.rawValue
            self.createdAt = Date()
            self.geometryFlat = []
            self.needsOptimize = false
            self.stops = []
        }
    }

    @Model
    final class Stop {
        var id: UUID = UUID()
        var kindRaw: String = StopKind.customer.rawValue
        var kunde: String?
        var strasse: String?
        var plz: String?
        var paket: String?
        var notiz: String?
        var telefon: String?
        var lat: Double = 0
        var lon: Double = 0
        var orderIndex: Int = 0
        var delivered: Bool = false
        var outcomeRaw: String?
        var settledAt: Date?
        var prioritaet: Bool = false
        var nextLegKm: Double?
        var nextLegMin: Double?
        var createdAt: Date = Date()
        var excluded: Bool = false
        var pinned: Bool = false
        var entranceLat: Double?
        var entranceLon: Double?
        var precisionRaw: String?
        var route: Route?

        init(kind: StopKind = .customer, lat: Double = 0, lon: Double = 0) {
            self.id = UUID()
            self.kindRaw = kind.rawValue
            self.lat = lat
            self.lon = lon
            self.createdAt = Date()
        }
    }

    @Model
    final class StockwerkNote {
        var id: UUID = UUID()
        var key: String = ""
        var kunde: String = ""
        var strasse: String = ""
        var plz: String = ""
        var stockwerk: String?
        var notiz: String?
        var dontAsk: Bool = false
        var updatedAt: Date = Date()

        init(key: String = "", kunde: String = "", strasse: String = "", plz: String = "") {
            self.id = UUID()
            self.key = key
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.updatedAt = Date()
        }
    }
}

/// V8 remembers that a tour was put in order by hand, so re-routing it after
/// an edit keeps that order instead of re-optimizing it away.
///
/// Lightweight: one column arrives, false on every tour already on the phone,
/// which is what every one of them is.
enum EarRouterSchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Route.self, Stop.self, StockwerkNote.self]
    }
}

/// How the store gets from one schema version to the next.
enum EarRouterMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarRouterSchemaV1.self, EarRouterSchemaV2.self, EarRouterSchemaV3.self,
         EarRouterSchemaV4.self, EarRouterSchemaV5.self, EarRouterSchemaV6.self,
         EarRouterSchemaV7.self, EarRouterSchemaV8.self]
    }

    /// Both lightweight, because adding and dropping a standalone entity takes
    /// nothing from the others: every tour, stop and delivered tick on the
    /// phone is untouched by either step, and the new floor table starts empty
    /// — which is exactly what "this customer has not been asked yet" means.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: EarRouterSchemaV1.self, toVersion: EarRouterSchemaV2.self),
            .lightweight(fromVersion: EarRouterSchemaV2.self, toVersion: EarRouterSchemaV3.self),
            .lightweight(fromVersion: EarRouterSchemaV3.self, toVersion: EarRouterSchemaV4.self),
            .lightweight(fromVersion: EarRouterSchemaV4.self, toVersion: EarRouterSchemaV5.self),
            .lightweight(fromVersion: EarRouterSchemaV5.self, toVersion: EarRouterSchemaV6.self),
            .lightweight(fromVersion: EarRouterSchemaV6.self, toVersion: EarRouterSchemaV7.self),
            .lightweight(fromVersion: EarRouterSchemaV7.self, toVersion: EarRouterSchemaV8.self),
        ]
    }
}

enum AppSchema {
    static let current = Schema(versionedSchema: EarRouterSchemaV8.self)

    /// Opens the store. `url` is only for tests — the app always wants the
    /// default location, which is the same file the unversioned container used,
    /// so an install that predates this change opens in place rather than
    /// migrating anywhere.
    static func container(url: URL? = nil) throws -> ModelContainer {
        let configuration =
            url.map { ModelConfiguration(schema: current, url: $0) }
            ?? ModelConfiguration(schema: current)
        return try ModelContainer(
            for: current,
            migrationPlan: EarRouterMigrationPlan.self,
            configurations: configuration)
    }
}
