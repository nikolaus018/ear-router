import Foundation
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
}
