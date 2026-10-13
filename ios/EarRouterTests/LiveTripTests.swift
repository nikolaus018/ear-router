import Foundation
import SwiftData
import Testing
@testable import EarRouter

/// Plans real tours against the live OSRM server, through the same call the
/// app makes. Off unless `LIVE_TRIP_TOURS` names a JSON file of tours — each a
/// name, its points from the last fixed point to the Ziel, and what `/trip`
/// alone made of it. Pass it with a `TEST_RUNNER_` prefix; the "LIVE TRIP"
/// lines are the result.
@Suite struct LiveTripTests {
    struct Tour: Decodable {
        let name: String
        let points: [[Double]]
        let tripSeconds: Double
    }

    static var toursPath: String? { ProcessInfo.processInfo.environment["LIVE_TRIP_TOURS"] }

    @Test(.enabled(if: toursPath != nil), .timeLimit(.minutes(10)))
    func plansEveryTour() async throws {
        let tours = try JSONDecoder().decode(
            [Tour].self, from: Data(contentsOf: URL(fileURLWithPath: Self.toursPath!)))
        var before = 0.0, after = 0.0
        for tour in tours {
            let coords = tour.points.map { (lat: $0[0], lon: $0[1]) }
            let solved = try await OSRMClient.shared.trip(
                coords: coords, fixFirst: true, fixLast: true)
            #expect(solved.order.sorted() == Array(coords.indices))
            #expect(solved.order.first == 0)
            #expect(solved.order.last == coords.count - 1)
            #expect(solved.legs.count == coords.count - 1)

            let plain = try await OSRMClient.shared.trip(
                coords: coords, fixFirst: true, fixLast: true, polish: false)
            let driven = solved.legs.reduce(0) { $0 + $1.1 }
            let was = plain.legs.reduce(0) { $0 + $1.1 }
            #expect(driven <= was + 1)
            before += was
            after += driven
            print(
                "LIVE TRIP \(tour.name) n=\(coords.count - 2): \(Int(was)) s -> \(Int(driven)) s"
                    + (solved.order == plain.order ? "" : "  (reordered)"))
        }
        print("LIVE TRIP total: \(Int(before / 60)) min -> \(Int(after / 60)) min")
    }

    /// The whole pipeline, as "Neu optimieren" runs it: the line that ends up
    /// stored has to pass every stop, in the order the list numbers them.
    @MainActor
    @Test(.enabled(if: toursPath != nil), .timeLimit(.minutes(10)))
    func theStoredLinePassesTheStopsInListOrder() async throws {
        let tours = try JSONDecoder().decode(
            [Tour].self, from: Data(contentsOf: URL(fileURLWithPath: Self.toursPath!)))
        for tour in tours.prefix(8) {
            let container = try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let context = ModelContext(container)
            let route = try RouteStore.createRoute(name: tour.name, in: context)
            for (i, point) in tour.points.dropFirst().dropLast().enumerated() {
                let stop = Stop(
                    kind: .customer, kunde: "K\(i)", strasse: "S \(i)", plz: "1210",
                    lat: point[0], lon: point[1], orderIndex: 100 + i)
                stop.route = route
                context.insert(stop)
            }
            try context.save()
            try await RouteOptimizer.optimize(route, in: context)

            let flat = route.geometryFlat
            let line = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
            func metres(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
                let dLat = (a.0 - b.0) * 111_000
                let dLon = (a.1 - b.1) * 111_000 * cos(a.0 * .pi / 180)
                return (dLat * dLat + dLon * dLon).squareRoot()
            }
            // Walk the line once, stop by stop: each stop's nearest point must
            // lie at or after the previous stop's.
            var from = 0
            var worst = 0.0
            var outOfOrder = 0
            for stop in route.orderedStops where !stop.excluded {
                let here = (stop.lat, stop.lon)
                var best = Double.infinity, at = from
                for k in from..<line.count {
                    let d = metres(here, line[k])
                    if d < best { best = d; at = k }
                }
                var anywhere = Double.infinity
                for point in line { anywhere = min(anywhere, metres(here, point)) }
                if best > anywhere + 30 { outOfOrder += 1 }
                worst = max(worst, best)
                from = at
            }
            print("LIVE LINE \(tour.name): \(line.count) points, worst \(Int(worst)) m, out of order \(outOfOrder)")
            #expect(outOfOrder == 0)
        }
    }
}
