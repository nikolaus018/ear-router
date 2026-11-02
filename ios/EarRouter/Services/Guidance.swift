import Foundation

/// One manoeuvre of a turn-by-turn route and the road that follows it, as
/// OSRM's `steps=true` describes it. `geometry` is `[lat, lon]` pairs.
struct GuidanceStep: Equatable, Sendable {
    var type: String
    var modifier: String?
    /// The road the manoeuvre leads onto; empty when it has no name.
    var name: String
    var exit: Int?
    var distance: Double
    var geometry: [[Double]]
    /// The lanes at this step's manoeuvre, left to right, when OpenStreetMap
    /// has them for that junction. Empty otherwise.
    var lanes: [GuidanceLane] = []
}

/// One lane at a junction: the ways it may be used to leave, and whether the
/// route wants it.
struct GuidanceLane: Equatable, Sendable {
    var indications: [String]
    var valid: Bool
}

struct GuidanceRoute: Equatable, Sendable {
    var steps: [GuidanceStep]
    var geometry: [[Double]]
    var distance: Double
    var duration: Double
}

/// Where the van is on a `GuidanceRoute`.
struct GuidanceProgress: Equatable {
    /// The step being driven. The manoeuvre it ends in is `steps[stepIndex + 1]`.
    var stepIndex: Int
    /// Metres to that manoeuvre, along the road.
    var metersToManeuver: Double
    /// Metres to the destination, along the road.
    var metersRemaining: Double
    var offRoute: Bool
    var arrived: Bool
    /// Metres driven along `stepIndex`'s own line.
    var along: Double = 0
    /// The van's place on the route — the GPS fix pulled onto the line, as
    /// every navigation app draws it — and the road's bearing there, degrees
    /// clockwise from north.
    var lat: Double = 0
    var lon: Double = 0
    var bearing: Double = 0
}

/// Position against route: which step, how far to the next turn, whether the
/// van has left the line. Pure, so it can be tested without a phone or a drive.
enum GuidanceEngine {
    /// Further than this from the line is "off the route". GPS in a Vienna
    /// street canyon is routinely 15–25 m out, so this is generous on purpose:
    /// a re-route that fires on noise is worse than a late one.
    static let offRouteMeters = 45.0
    static let arrivalMeters = 25.0
    /// How many steps ahead of the current one a fix may jump to. Stops a
    /// route that doubles back on itself matching the wrong half.
    static let lookahead = 3

    static func progress(
        route: GuidanceRoute, at p: (lat: Double, lon: Double), after previous: Int = 0
    ) -> GuidanceProgress {
        let steps = route.steps
        guard steps.count >= 2, let end = steps.last?.geometry.last, end.count == 2 else {
            return GuidanceProgress(
                stepIndex: 0, metersToManeuver: 0, metersRemaining: 0,
                offRoute: false, arrived: true)
        }
        let lastDriven = steps.count - 2
        let from = min(max(previous, 0), lastDriven)
        let to = min(lastDriven, from + lookahead)

        var best: (index: Int, distance: Double, along: Double)?
        for i in from...to {
            guard let hit = project(p, onto: steps[i].geometry) else { continue }
            if best == nil || hit.distance < best!.distance {
                best = (i, hit.distance, hit.along)
            }
        }
        let toEnd = meters(p, (end[0], end[1]))
        guard let best else {
            return GuidanceProgress(
                stepIndex: from, metersToManeuver: 0, metersRemaining: toEnd,
                offRoute: true, arrived: toEnd < arrivalMeters)
        }
        let length = polylineLength(steps[best.index].geometry)
        let toManeuver = max(0, length - best.along)
        let after = steps[(best.index + 1)...].reduce(0) { $0 + $1.distance }
        let remaining = toManeuver + after
        let on = point(on: steps[best.index].geometry, along: best.along)
        return GuidanceProgress(
            stepIndex: best.index, metersToManeuver: toManeuver, metersRemaining: remaining,
            offRoute: best.distance > offRouteMeters,
            arrived: toEnd < arrivalMeters,
            along: best.along, lat: on.lat, lon: on.lon, bearing: on.bearing)
    }

    /// A road changing its name, or "continue straight": nothing to tell the
    /// driver, and no other app announces it.
    static func isTrivial(_ s: GuidanceStep) -> Bool {
        (s.type == "new name" || s.type == "continue") && (s.modifier == nil || s.modifier == "straight")
    }

    /// The next manoeuvre worth telling the driver about, with its index and
    /// the metres to it — past any trivial ones in between.
    static func upcoming(
        route: GuidanceRoute, progress p: GuidanceProgress
    ) -> (index: Int, step: GuidanceStep, meters: Double)? {
        var i = p.stepIndex + 1
        guard i < route.steps.count else { return nil }
        var meters = p.metersToManeuver
        while i < route.steps.count - 1, isTrivial(route.steps[i]) {
            meters += route.steps[i].distance
            i += 1
        }
        return (i, route.steps[i], meters)
    }

    /// `progress`, moved `meters` further down the road — dead reckoning. The
    /// van keeps its place on the line between GPS fixes and through a tunnel,
    /// crossing into the next step when it runs off the end of this one.
    static func advanced(
        _ p: GuidanceProgress, on route: GuidanceRoute, by meters: Double
    ) -> GuidanceProgress {
        let steps = route.steps
        guard steps.count >= 2, meters > 0 else { return p }
        let lastDriven = steps.count - 2
        var index = min(p.stepIndex, lastDriven)
        var along = p.along + meters
        while index < lastDriven {
            let length = polylineLength(steps[index].geometry)
            guard along > length else { break }
            along -= length
            index += 1
        }
        let length = polylineLength(steps[index].geometry)
        along = min(along, length)
        let toManeuver = max(0, length - along)
        let after = steps[(index + 1)...].reduce(0) { $0 + $1.distance }
        let on = point(on: steps[index].geometry, along: along)
        var q = p
        q.stepIndex = index
        q.along = along
        q.metersToManeuver = toManeuver
        q.metersRemaining = toManeuver + after
        q.lat = on.lat
        q.lon = on.lon
        q.bearing = on.bearing
        q.arrived = index == lastDriven && toManeuver < arrivalMeters
        return q
    }

    /// The point `along` metres down `line`, and the bearing of the stretch
    /// it is on. Clamped to the line's ends.
    static func point(
        on line: [[Double]], along: Double
    ) -> (lat: Double, lon: Double, bearing: Double) {
        let pts = line.filter { $0.count == 2 }
        guard let first = pts.first else { return (0, 0, 0) }
        guard pts.count >= 2 else { return (first[0], first[1], 0) }
        var left = max(0, along)
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let len = meters((a[0], a[1]), (b[0], b[1]))
            if left <= len || i == pts.count - 2 {
                let t = len == 0 ? 0 : min(1, left / len)
                return (
                    a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t,
                    bearing((a[0], a[1]), (b[0], b[1])))
            }
            left -= len
        }
        let last = pts[pts.count - 1]
        return (last[0], last[1], 0)
    }

    /// `line` from `along` metres on, starting at that point — what is still
    /// ahead of the van on a step, so the drawn route does not trail behind it.
    static func remainder(of line: [[Double]], from along: Double) -> [[Double]] {
        let pts = line.filter { $0.count == 2 }
        guard pts.count >= 2, along > 0 else { return pts }
        var left = along
        for i in 0..<(pts.count - 1) {
            let len = meters((pts[i][0], pts[i][1]), (pts[i + 1][0], pts[i + 1][1]))
            if left <= len {
                let t = len == 0 ? 0 : left / len
                let at = [
                    pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t,
                    pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t,
                ]
                return [at] + Array(pts[(i + 1)...])
            }
            left -= len
        }
        return [pts[pts.count - 1]]
    }

    /// Degrees clockwise from north, 0..<360.
    static func bearing(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let lonScale = cos((a.lat + b.lat) / 2 * .pi / 180)
        let dx = (b.lon - a.lon) * lonScale
        let dy = b.lat - a.lat
        guard dx != 0 || dy != 0 else { return 0 }
        let deg = atan2(dx, dy) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// The shortest way round from `a` to `b`, in degrees, -180...180.
    static func angleDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    // MARK: - Geometry

    /// Nearest point of `line` to `p`: how far off it is, and how far along.
    static func project(
        _ p: (lat: Double, lon: Double), onto line: [[Double]]
    ) -> (distance: Double, along: Double)? {
        guard line.count >= 2 else { return nil }
        var best: (distance: Double, along: Double)?
        var walked = 0.0
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            guard a.count == 2, b.count == 2 else { continue }
            // Metres on a local flat map around `p`: exact enough at street scale.
            let lonScale = cos(p.lat * .pi / 180)
            func xy(_ c: [Double]) -> (Double, Double) {
                ((c[1] - p.lon) * lonScale * 111_320, (c[0] - p.lat) * 110_540)
            }
            let (ax, ay) = xy(a), (bx, by) = xy(b)
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : min(1, max(0, -(ax * dx + ay * dy) / len2))
            let px = ax + t * dx, py = ay + t * dy
            let d = (px * px + py * py).squareRoot()
            let segment = len2.squareRoot()
            if best == nil || d < best!.distance {
                best = (d, walked + t * segment)
            }
            walked += segment
        }
        return best
    }

    static func polylineLength(_ line: [[Double]]) -> Double {
        var total = 0.0
        for i in 0..<max(0, line.count - 1) where line[i].count == 2 && line[i + 1].count == 2 {
            total += meters((line[i][0], line[i][1]), (line[i + 1][0], line[i + 1][1]))
        }
        return total
    }

    static func meters(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
        let lonScale = cos((a.lat + b.lat) / 2 * .pi / 180)
        let dx = (b.lon - a.lon) * lonScale * 111_320
        let dy = (b.lat - a.lat) * 110_540
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// What to tell the driver about a manoeuvre.
enum ManeuverText {
    static func instruction(_ step: GuidanceStep) -> String {
        let road = step.name.isEmpty ? "" : " auf \(step.name)"
        switch step.type {
        case "depart":
            return step.name.isEmpty ? "Losfahren" : "Losfahren auf \(step.name)"
        case "arrive":
            switch step.modifier {
            case "left", "slight left", "sharp left": return "Ziel liegt links"
            case "right", "slight right", "sharp right": return "Ziel liegt rechts"
            default: return "Ziel erreicht"
            }
        case "roundabout", "rotary", "roundabout turn":
            if let n = step.exit { return "Im Kreisverkehr \(n). Ausfahrt nehmen\(road)" }
            return "In den Kreisverkehr einfahren\(road)"
        case "exit roundabout", "exit rotary":
            return "Kreisverkehr verlassen\(road)"
        case "fork":
            switch step.modifier {
            case "left", "slight left", "sharp left": return "Links halten\(road)"
            default: return "Rechts halten\(road)"
            }
        case "merge":
            return "Einfädeln\(road)"
        default:
            return "\(direction(step.modifier))\(road)"
        }
    }

    /// "In 200 Metern: …" — distance rounded the way a person says it.
    static func spoken(_ step: GuidanceStep, in meters: Double) -> String {
        if meters < 60 { return instruction(step) }
        let rounded = meters >= 150 ? Int((meters / 50).rounded()) * 50 : Int((meters / 10).rounded()) * 10
        return "In \(rounded) Metern: \(instruction(step))"
    }

    static func direction(_ modifier: String?) -> String {
        switch modifier {
        case "uturn": "Wenden"
        case "sharp right": "Scharf rechts abbiegen"
        case "right": "Rechts abbiegen"
        case "slight right": "Leicht rechts halten"
        case "sharp left": "Scharf links abbiegen"
        case "left": "Links abbiegen"
        case "slight left": "Leicht links halten"
        default: "Geradeaus weiter"
        }
    }

    static func symbol(_ step: GuidanceStep) -> String {
        switch step.type {
        case "arrive": return "flag.checkered"
        case "roundabout", "rotary", "roundabout turn", "exit roundabout", "exit rotary":
            return "arrow.triangle.turn.up.right.circle"
        default: break
        }
        switch step.modifier {
        case "uturn": return "arrow.uturn.left"
        case "sharp right", "right": return "arrow.turn.up.right"
        case "slight right": return "arrow.up.right"
        case "sharp left", "left": return "arrow.turn.up.left"
        case "slight left": return "arrow.up.left"
        default: return "arrow.up"
        }
    }

    /// "350 m" / "1,2 km", the way the rest of the app writes distances.
    static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int((meters / 10).rounded()) * 10) m" }
        return String(format: "%.1f km", locale: Locale(identifier: "de_AT"), meters / 1000)
    }
}
