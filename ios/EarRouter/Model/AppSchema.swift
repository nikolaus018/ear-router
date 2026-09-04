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

    /// The shipping models. From V2 onwards a version pins its *own* copies of
    /// the model definitions here, so the migration has both shapes to work
    /// with; V1 is the shape on every phone today, so it is these.
    static var models: [any PersistentModel.Type] { [Route.self, Stop.self] }
}

/// How the store gets from one schema version to the next.
///
/// Empty of stages on purpose: there is one version, so there is nothing to
/// migrate yet. It exists so that adding the next version is an edit to this
/// list rather than a decision about architecture.
enum EarRouterMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [EarRouterSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum AppSchema {
    static let current = Schema(versionedSchema: EarRouterSchemaV1.self)

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
