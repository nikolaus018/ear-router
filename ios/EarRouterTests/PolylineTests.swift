import Testing
import CoreLocation
@testable import EarRouter

/// The route line is the single most expensive thing the map draws — OSRM's
/// full-overview geometry is ~600 points per leg, so a thirty-stop tour is
/// several thousand in one polyline, redrawn on every pan frame.
@MainActor
struct PolylineSimplificationTests {

    /// A synthetic road: a long arc with the kind of dense sampling OSRM emits
    /// along a straight run.
    private func arc(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return CLLocationCoordinate2D(
                latitude: 48.15 + t * 0.13,
                longitude: 16.35 + sin(t * .pi) * 0.08)
        }
    }

    @Test func keepsBothEndpointsExactly() {
        let points = arc(600)
        let out = MapTab.simplified(points, tolerance: 0.00002)
        #expect(out.first?.latitude == points.first?.latitude)
        #expect(out.first?.longitude == points.first?.longitude)
        #expect(out.last?.latitude == points.last?.latitude)
        #expect(out.last?.longitude == points.last?.longitude)
    }

    @Test func actuallyReducesThePointCount() {
        let points = arc(6000)
        let out = MapTab.simplified(points, tolerance: 0.00002)
        #expect(out.count < points.count / 4, "only got down to \(out.count) of \(points.count)")
    }

    @Test func neverMovesTheLineFurtherThanTheTolerance() {
        // The whole justification for dropping points: what is discarded has to
        // stay under the tolerance of the line that replaces it, or the route
        // drawn is not the route driven.
        let points = arc(2000)
        let out = MapTab.simplified(points, tolerance: 0.00002)
        let lonScale = cos(48.2 * .pi / 180)

        for p in points {
            var best = Double.greatestFiniteMagnitude
            for i in 0..<(out.count - 1) {
                let a = out[i], b = out[i + 1]
                let dx = (b.longitude - a.longitude) * lonScale
                let dy = b.latitude - a.latitude
                let lengthSquared = dx * dx + dy * dy
                let px = (p.longitude - a.longitude) * lonScale
                let py = p.latitude - a.latitude
                var t = lengthSquared > 0 ? (px * dx + py * dy) / lengthSquared : 0
                t = min(max(t, 0), 1)
                best = min(best, hypot(px - t * dx, py - t * dy))
            }
            // ~0.00002 degrees is a bit over two metres at this latitude.
            #expect(best <= 0.000021, "a point drifted \(best) from the simplified line")
        }
    }

    @Test func leavesShortLinesAlone() {
        let two = [
            CLLocationCoordinate2D(latitude: 48.2, longitude: 16.3),
            CLLocationCoordinate2D(latitude: 48.3, longitude: 16.4),
        ]
        #expect(MapTab.simplified(two, tolerance: 0.00002).count == 2)
        #expect(MapTab.simplified([], tolerance: 0.00002).isEmpty)
    }

    @Test func keepsARealCornerThatDefinesTheShape() {
        // A right-angle turn must survive: it is the shape of the route.
        let corner = [
            CLLocationCoordinate2D(latitude: 48.20, longitude: 16.30),
            CLLocationCoordinate2D(latitude: 48.25, longitude: 16.30),
            CLLocationCoordinate2D(latitude: 48.25, longitude: 16.40),
        ]
        #expect(MapTab.simplified(corner, tolerance: 0.00002).count == 3)
    }
}

/// The decode half of the line build. It runs off the main actor now, on a
/// plain `[Double]` buffer rather than a `Route`, so nothing touches SwiftData
/// from a background task.
struct PolylineDecodeTests {

    @Test func decodesFlatPairsAsLatitudeThenLongitude() {
        let out = MapTab.simplifiedLine(
            flat: [48.20, 16.37, 48.25, 16.40], tolerance: 0.00002)
        #expect(out.count == 2)
        #expect(out.first?.latitude == 48.20)
        #expect(out.first?.longitude == 16.37)
        #expect(out.last?.latitude == 48.25)
        #expect(out.last?.longitude == 16.40)
    }

    /// A buffer too short to be a line, and — the case that would crash an
    /// unguarded stride — one holding an odd number of values.
    @Test func refusesBuffersThatAreNotWholePairs() {
        #expect(MapTab.simplifiedLine(flat: [], tolerance: 0.00002).isEmpty)
        #expect(MapTab.simplifiedLine(flat: [48.2, 16.3], tolerance: 0.00002).isEmpty)
        let odd = MapTab.simplifiedLine(
            flat: [48.20, 16.37, 48.25, 16.40, 48.30], tolerance: 0.00002)
        #expect(odd.count == 2)
    }

    @Test func simplifiesTheDecodedLine() {
        // A straight run sampled densely: everything between the ends is
        // redundant at any zoom a route is looked at.
        var flat: [Double] = []
        for i in 0..<500 {
            flat.append(48.20 + Double(i) * 0.0001)
            flat.append(16.37)
        }
        let out = MapTab.simplifiedLine(flat: flat, tolerance: 0.00002)
        #expect(out.count == 2)
        #expect(out.first?.latitude == 48.20)
    }
}
