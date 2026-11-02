import Foundation
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "speedlimits")

/// A Viennese road with the limit OpenStreetMap posts on it, per direction
/// of travel along its geometry.
struct LimitWay: Equatable, Sendable {
    var forward: Int?
    var backward: Int?
    /// `[lat, lon]` pairs in the way's own direction.
    var geometry: [[Double]]
}

/// The posted limit along a `GuidanceRoute`, in km/h, sampled every
/// `spacing` metres of each step. `nil` where OpenStreetMap has no number
/// for the road — shown as no sign rather than a guess.
struct SpeedLimitProfile: Equatable, Sendable {
    static let spacing = 10.0
    var samples: [[Int?]]

    func limit(step: Int, along: Double) -> Int? {
        guard samples.indices.contains(step), !samples[step].isEmpty else { return nil }
        let i = min(samples[step].count - 1, max(0, Int(along / Self.spacing)))
        return samples[step][i]
    }
}

/// Speed limits for the in-app guidance, from `Resources/WienTempolimits.deflate`
/// — made by `scripts/fetch_speed_limits.py`. Bundled rather than asked of
/// Overpass on the road: the public servers answer in 40 seconds or with a
/// 502, and a sign that arrives after the street is no sign. Vienna only; a
/// route outside it simply has none.
enum SpeedLimits {
    static func fetch(for route: GuidanceRoute) async -> SpeedLimitProfile? {
        await Task.detached(priority: .utility) {
            guard let ways = bundled else { return nil }
            return profile(route: route, ways: ways)
        }.value
    }

    /// Read once, on first use.
    static let bundled: [LimitWay]? = {
        guard let url = Bundle.main.url(forResource: "WienTempolimits", withExtension: "deflate"),
              let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .zlib) as Data
        else {
            log.warning("no bundled speed limits")
            return nil
        }
        return parse(data)
    }()

    /// `[[forward, backward, [lat, lon, lat, lon, …]], …]`
    static func parse(_ data: Data) -> [LimitWay]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return nil }
        return rows.compactMap { row in
            guard row.count == 3, let flat = row[2] as? [Double], flat.count >= 4 else { return nil }
            var g: [[Double]] = []
            var i = 0
            while i + 1 < flat.count {
                g.append([flat[i], flat[i + 1]])
                i += 2
            }
            return LimitWay(
                forward: (row[0] as? NSNumber)?.intValue,
                backward: (row[1] as? NSNumber)?.intValue,
                geometry: g)
        }
    }

    // MARK: - Matching

    static func profile(route: GuidanceRoute, ways all: [LimitWay]) -> SpeedLimitProfile {
        // Only the roads near this route: the rest of the city is noise.
        let pts = route.steps.flatMap(\.geometry).filter { $0.count == 2 }
        let pad = 0.0004
        let routeBox = box(of: pts)
        var ways: [LimitWay] = []
        var boxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)] = []
        for w in all {
            let b = box(of: w.geometry)
            guard b.maxLat >= routeBox.minLat - pad, b.minLat <= routeBox.maxLat + pad,
                  b.maxLon >= routeBox.minLon - pad, b.minLon <= routeBox.maxLon + pad
            else { continue }
            ways.append(w)
            boxes.append(b)
        }

        var samples: [[Int?]] = []
        for step in route.steps {
            let length = GuidanceEngine.polylineLength(step.geometry)
            var row: [Int?] = []
            var d = 0.0
            while d <= length {
                let at = GuidanceEngine.point(on: step.geometry, along: d)
                row.append(limit(at: at, ways: ways, boxes: boxes))
                d += SpeedLimitProfile.spacing
            }
            samples.append(fillSmallGaps(row))
        }
        return SpeedLimitProfile(samples: samples)
    }

    /// The nearest road within 15 m that runs the same way as the route
    /// (or the opposite way, for its backward limit).
    private static func limit(
        at p: (lat: Double, lon: Double, bearing: Double), ways: [LimitWay],
        boxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)]
    ) -> Int? {
        let pad = 0.0002
        var best: (distance: Double, limit: Int)?
        for (i, way) in ways.enumerated() {
            let b = boxes[i]
            guard p.lat >= b.minLat - pad, p.lat <= b.maxLat + pad,
                  p.lon >= b.minLon - pad, p.lon <= b.maxLon + pad
            else { continue }
            let g = way.geometry
            guard g.count >= 2 else { continue }
            for j in 0..<(g.count - 1) {
                guard g[j].count == 2, g[j + 1].count == 2 else { continue }
                let segBearing = GuidanceEngine.bearing((g[j][0], g[j][1]), (g[j + 1][0], g[j + 1][1]))
                let delta = abs(GuidanceEngine.angleDelta(from: p.bearing, to: segBearing))
                let forward = delta < 40
                guard forward || delta > 140 else { continue }
                guard let hit = GuidanceEngine.project((p.lat, p.lon), onto: [g[j], g[j + 1]]),
                      hit.distance <= 15,
                      let kmh = forward ? way.forward : way.backward
                else { continue }
                if best == nil || hit.distance < best!.distance { best = (hit.distance, kmh) }
            }
        }
        return best?.limit
    }

    /// Junction crossings and a missing node leave one or two holes inside a
    /// stretch with one limit; bridge them, but not a real change.
    static func fillSmallGaps(_ row: [Int?]) -> [Int?] {
        var out = row
        var i = 0
        while i < out.count {
            guard out[i] == nil else { i += 1; continue }
            var j = i
            while j < out.count, out[j] == nil { j += 1 }
            if i > 0, j < out.count, j - i <= 4, out[i - 1] == out[j] {
                for k in i..<j { out[k] = out[j] }
            }
            i = j
        }
        return out
    }

    private static func box(of g: [[Double]])
        -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    {
        let pts = g.filter { $0.count == 2 }
        return (
            pts.map { $0[0] }.min() ?? 0, pts.map { $0[0] }.max() ?? 0,
            pts.map { $0[1] }.min() ?? 0, pts.map { $0[1] }.max() ?? 0)
    }
}
