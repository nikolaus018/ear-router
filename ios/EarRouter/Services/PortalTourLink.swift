import Foundation

/// Which Zusteller-Portal tour, on which day, a route was made from.
///
/// Kept in `UserDefaults` beside the route's id rather than on `Route`: the
/// store is versioned, and a schema step for one optional field that only the
/// map's "Stopps der anderen" reads is a bigger change than the field is
/// worth. The same arrangement the packing checklist already has — see
/// `RouteStore.delete`, which lets go of it with the route.
///
/// A route with no link is not an error: it came from a paste, a document, or
/// an older build, and the map then falls back to `OtherStops.infer`.
struct PortalTourLink: Codable, Equatable, Sendable {
    var tourID: Int
    var tourName: String
    var date: Date

    private static func key(_ routeID: UUID) -> String { "portal.link.\(routeID.uuidString)" }

    static func load(for routeID: UUID) -> PortalTourLink? {
        guard let data = UserDefaults.standard.data(forKey: key(routeID)) else { return nil }
        return try? JSONDecoder().decode(PortalTourLink.self, from: data)
    }

    func save(for routeID: UUID) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(routeID))
    }

    static func forget(_ routeID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(routeID))
    }
}
