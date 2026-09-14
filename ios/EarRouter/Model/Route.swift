import Foundation
import SwiftData

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
    /// Invalidates the part of a route that is only true for one particular
    /// set of stops: its driving geometry.  A stop can disappear from the
    /// list immediately while OSRM is still working; keeping the old geometry
    /// in that interval made the map draw a line through a stop that no longer
    /// exists.  Clearing it makes the map truthful straight away and lets the
    /// fresh line arrive as one atomic replacement.
    func markRoutingStale() {
        needsOptimize = true
        geometryFlat = []
    }

    /// Stops in the order they are shown, which is not necessarily the order
    /// they are driven in — see `RouteOptimizer.displayOrder`.
    var orderedStops: [Stop] {
        stops.sorted(by: Stop.displayBefore)
    }

    var customerStops: [Stop] {
        orderedStops.filter { $0.kind == .customer }
    }

    /// Counted straight off `stops` rather than through `customerStops`: the
    /// answer is a number, and a number does not care what order it was
    /// arrived at. Going through the ordered list sorted the whole route for
    /// nothing — and these are read from list rows, several times each.
    var customerCount: Int {
        stops.count { $0.kind == .customer }
    }

    var deliveredCount: Int {
        stops.count { $0.kind == .customer && $0.delivered }
    }

    /// Doors the driver has answered for, whichever way they answered. What
    /// "how far through is this tour" actually means, and what
    /// "Lieferstatus zurücksetzen" actually clears.
    var settledCount: Int {
        stops.count { $0.kind == .customer && $0.isSettled }
    }

    /// Whether every door on the tour has been answered for — which is not the
    /// same as every meal having been delivered.
    ///
    /// A customer who was not home settles the stop: the van has been there and
    /// is not going back past it. The driving is done, and the tour is finished
    /// in the only sense a driver uses the word. Counting that as incomplete
    /// left a tour that had visibly ended showing "Noch 1 Stopp" until somebody
    /// ticked a meal as delivered that never was.
    var isComplete: Bool {
        var seen = false
        for s in stops where s.kind == .customer {
            if !s.isSettled { return false }
            seen = true
        }
        return seen
    }

    /// The next stop the driver has not yet answered for.
    var nextOpenStop: Stop? {
        orderedStops.first(where: \.isOpenDelivery)
    }

    /// Total distance and time over the legs that are actually driven. One
    /// pass — the three it used to take each allocated an intermediate array.
    var totals: (km: Double, minutes: Double) {
        var km = 0.0, minutes = 0.0
        for s in stops where !s.excluded {
            km += s.nextLegKm ?? 0
            minutes += s.nextLegMin ?? 0
        }
        return (km, minutes)
    }
}
