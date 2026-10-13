import CoreLocation
import Foundation

/// The doors after this one that are a short walk away — carried along in one
/// go, instead of found out about from the navigation app once the driver is
/// back in the van and it says "30 m".
///
/// Jetzt shows one stop and nothing else, on purpose. This is the one thing
/// about what comes next that changes what the driver does *now*: how many
/// parcels leave the van.
enum WalkOn {
    /// As the crow flies, so the real walk is somewhat more. Far enough for
    /// the next Stiege across a Hof and the house two doors down; not so far
    /// that it would have been quicker to drive.
    static let reach: Double = 100

    struct Door: Identifiable, Equatable {
        let id: UUID
        let name: String
        let paket: String?
        /// Metres from the stop the van is standing at.
        let metres: Double

        /// "60 m", or "hier" for the same house.
        var distance: String {
            metres < 15 ? "hier" : "\(Int((metres / 10).rounded()) * 10) m"
        }
    }

    /// The open customers that follow `current` in driving order, for as long
    /// as each is within `reach` of it. Stops at the first that is not: a door
    /// further down the list means driving somewhere else in between.
    @MainActor
    static func doors(after current: Stop, in ordered: [Stop]) -> [Door] {
        guard current.kind == .customer,
              let at = ordered.firstIndex(where: { $0.id == current.id })
        else { return [] }
        let here = points(of: current)
        var out: [Door] = []
        for stop in ordered[(at + 1)...] {
            // Not driven to at all, or already answered for: neither is in
            // the way, and neither is carried.
            if stop.excluded || stop.isSettled { continue }
            guard stop.kind == .customer,
                  let metres = metres(from: here, to: points(of: stop)), metres <= reach
            else { break }
            out.append(
                Door(id: stop.id, name: stop.kunde ?? "Stopp", paket: stop.displayPaket,
                     metres: metres))
        }
        return out
    }

    /// Whether `next` is carried along from `stop` rather than driven to.
    @MainActor
    static func reaches(_ next: Stop, from stop: Stop) -> Bool {
        guard stop.kind == .customer, next.kind == .customer,
              let metres = metres(from: points(of: stop), to: points(of: next))
        else { return false }
        return metres <= reach
    }

    /// Where a stop is: its pin on the map, and the street door when that is
    /// somewhere else. Two houses are as close as their closest pair.
    @MainActor
    private static func points(of stop: Stop) -> [CLLocationCoordinate2D] {
        // "Nur Bezirk": the pin is the middle of a district, not a house.
        // Two addresses nobody could find are not next door to each other.
        guard stop.precision == nil || stop.pinned else { return [] }
        var out: [CLLocationCoordinate2D] = []
        if Coordinates.isPlausible(lat: stop.lat, lon: stop.lon, forPlz: stop.plz ?? "") {
            out.append(CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon))
        }
        if !stop.pinned, let entrance = stop.entrance { out.append(entrance) }
        return out
    }

    /// The shortest distance between two sets of points, or `nil` when either
    /// stop has no usable position at all.
    static func metres(
        from a: [CLLocationCoordinate2D], to b: [CLLocationCoordinate2D]
    ) -> Double? {
        var best: Double?
        for p in a {
            for q in b {
                let dLat = (p.latitude - q.latitude) * 111_000
                let dLon = (p.longitude - q.longitude) * 111_000 * cos(p.latitude * .pi / 180)
                let d = (dLat * dLat + dLon * dLon).squareRoot()
                if best == nil || d < best! { best = d }
            }
        }
        return best
    }
}

/// "Geliefert" carries straight on: the navigation to the next stop starts
/// with the tick, so it is already running when the driver is back at the
/// wheel — one press per door instead of two and a look for the second.
enum AutoContinue {
    /// Also read directly by `@AppStorage` in the settings screen.
    static let enabledKey = "now.autoContinue"

    /// On unless switched off. It follows a button the driver pressed, at the
    /// moment the next thing they do is drive there.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    /// Where to navigate once `stop` has been answered for with `outcome`, or
    /// `nil` to stay put.
    ///
    /// Only after a door the driver stood at. Abbestellt and "ins Lager" are
    /// noted from the phone, often the evening before, and re-plan the tour
    /// behind them — neither is a moment to open a navigation app. And not to
    /// a door within `WalkOn.reach`: that one is walked to.
    @MainActor
    static func destination(
        after stop: Stop, outcome: DeliveryOutcome, next: Stop?,
        enabled: Bool = isEnabled()
    ) -> Stop? {
        guard enabled, !outcome.skipsDoor,
              let next, next.id != stop.id, !WalkOn.reaches(next, from: stop)
        else { return nil }
        return next
    }
}
