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

    /// The two models as they were before `StockwerkNote` existed. `Route` and
    /// `Stop` themselves did not change in V2, so this pins the live types
    /// rather than copies of them — what makes this V1 is the entity that is
    /// *absent* from the list.
    static var models: [any PersistentModel.Type] { [Route.self, Stop.self] }
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
        [Route.self, Stop.self, DoorNote.self]
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
}

/// How the store gets from one schema version to the next.
enum EarRouterMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarRouterSchemaV1.self, EarRouterSchemaV2.self, EarRouterSchemaV3.self]
    }

    /// Both lightweight, because adding and dropping a standalone entity takes
    /// nothing from the others: every tour, stop and delivered tick on the
    /// phone is untouched by either step, and the new floor table starts empty
    /// — which is exactly what "this customer has not been asked yet" means.
    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: EarRouterSchemaV1.self, toVersion: EarRouterSchemaV2.self),
            .lightweight(fromVersion: EarRouterSchemaV2.self, toVersion: EarRouterSchemaV3.self),
        ]
    }
}

enum AppSchema {
    static let current = Schema(versionedSchema: EarRouterSchemaV3.self)

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
