import Foundation
import SwiftData
import CoreLocation

enum RouteStatus: String, Codable, Sendable {
    case active
    case completed
}

@Model
final class Route {
    var id: UUID = UUID()
    var name: String = ""

    /// Stored raw so `#Predicate` can filter on it — SwiftData predicates only
    /// see stored properties, not the computed enum wrapper above them.
    var statusRaw: String = RouteStatus.active.rawValue
    var status: RouteStatus {
        get { RouteStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var createdAt: Date = Date()
    var completedAt: Date?

    /// The driven line, as flat `[lat, lon, lat, lon, …]`. Stored flat rather
    /// than as `[[Double]]` because SwiftData's transformable handling of
    /// nested arrays is needless overhead for what is really just a buffer of
    /// numbers, and this keeps a several-thousand-point Vienna route cheap to
    /// load on every list render.
    var geometryFlat: [Double] = []

    /// Set when the route has changed since the last successful optimization.
    /// Surfaced as the amber "Route nicht aktuell" banner with its one-tap
    /// retry, so a failed OSRM call leaves a visible, recoverable state rather
    /// than a route quietly claiming to be current.
    var needsOptimize: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Stop.route)
    var stops: [Stop] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.statusRaw = RouteStatus.active.rawValue
        self.createdAt = Date()
        self.geometryFlat = []
        self.needsOptimize = false
        self.stops = []
    }
}

extension Route {
    /// Stops in the order they are shown, which is not necessarily the order
    /// they are driven in — see `RouteOptimizer.displayOrder`.
    var orderedStops: [Stop] {
        stops.sorted { $0.orderIndex < $1.orderIndex }
    }

    var customerStops: [Stop] {
        orderedStops.filter { $0.kind == .customer }
    }

    var deliveredCount: Int {
        customerStops.count { $0.delivered }
    }

    var isComplete: Bool {
        let customers = customerStops
        return !customers.isEmpty && customers.allSatisfy(\.delivered)
    }

    /// The next stop the driver has not yet ticked off.
    var nextOpenStop: Stop? {
        orderedStops.first { $0.kind == .customer && !$0.delivered }
    }

    var geometry: [CLLocationCoordinate2D] {
        guard geometryFlat.count >= 4 else { return [] }
        return stride(from: 0, to: geometryFlat.count - 1, by: 2).map {
            CLLocationCoordinate2D(
                latitude: geometryFlat[$0], longitude: geometryFlat[$0 + 1])
        }
    }

    /// Total distance and time over the legs that are actually driven.
    var totals: (km: Double, minutes: Double) {
        let driven = stops.filter { !$0.excluded }
        let km = driven.compactMap(\.nextLegKm).reduce(0, +)
        let min = driven.compactMap(\.nextLegMin).reduce(0, +)
        return (km, min)
    }
}
