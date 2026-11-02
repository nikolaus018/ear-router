import Foundation

/// Fixed speed cameras and section-control points on a `GuidanceRoute`, from
/// `Resources/Blitzer.json` (OpenStreetMap, made by
/// `scripts/fetch_speed_cameras.py`). Only the ones the route actually passes
/// — within 15 m of its line — and where along it they are.
///
/// OSM's `direction` on these is relative to a road the file does not carry,
/// so a camera on the opposite carriageway, close by, can be warned of too.
struct SpeedCameraProfile: Equatable, Sendable {
    struct Camera: Equatable, Sendable {
        /// Metres from the start of the route.
        var along: Double
        var kmh: Int?
    }
    var cameras: [Camera]
    /// Where each step starts, metres from the start of the route.
    var stepStart: [Double]

    func routeAlong(step: Int, along: Double) -> Double {
        (stepStart.indices.contains(step) ? stepStart[step] : 0) + along
    }

    /// The first camera ahead of the van within `within` metres, its index
    /// and how far off it is.
    func next(step: Int, along: Double, within: Double)
        -> (index: Int, distance: Double, kmh: Int?)?
    {
        let here = routeAlong(step: step, along: along)
        for (i, c) in cameras.enumerated() where c.along >= here - 5 {
            let d = max(0, c.along - here)
            return d <= within ? (i, d, c.kmh) : nil
        }
        return nil
    }
}

enum SpeedCameras {
    /// Whether the driver wants the warnings. On by default.
    static let enabledKey = "guidance.cameras"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// `[lat, lon, kmh-or-null]`
    struct Point: Equatable, Sendable {
        var lat: Double
        var lon: Double
        var kmh: Int?
    }

    static let bundled: [Point] = {
        guard let url = Bundle.main.url(forResource: "Blitzer", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return parse(data)
    }()

    static func parse(_ data: Data) -> [Point] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return rows.compactMap { r in
            guard r.count == 3, let lat = (r[0] as? NSNumber)?.doubleValue,
                  let lon = (r[1] as? NSNumber)?.doubleValue
            else { return nil }
            return Point(lat: lat, lon: lon, kmh: (r[2] as? NSNumber)?.intValue)
        }
    }

    static func profile(route: GuidanceRoute, points: [Point] = bundled) -> SpeedCameraProfile {
        var start = 0.0
        var stepStart: [Double] = []
        for s in route.steps {
            stepStart.append(start)
            start += GuidanceEngine.polylineLength(s.geometry)
        }
        var found: [SpeedCameraProfile.Camera] = []
        for p in points {
            var best: (distance: Double, along: Double)?
            for (i, s) in route.steps.enumerated() {
                guard let hit = GuidanceEngine.project((p.lat, p.lon), onto: s.geometry),
                      hit.distance <= 15
                else { continue }
                if best == nil || hit.distance < best!.distance {
                    best = (hit.distance, stepStart[i] + hit.along)
                }
            }
            if let best { found.append(.init(along: best.along, kmh: p.kmh)) }
        }
        found.sort { $0.along < $1.along }
        // Two points a few metres apart are one camera (a pair facing both ways).
        var merged: [SpeedCameraProfile.Camera] = []
        for c in found where merged.last.map({ c.along - $0.along > 30 }) ?? true { merged.append(c) }
        return SpeedCameraProfile(cameras: merged, stepStart: stepStart)
    }
}
