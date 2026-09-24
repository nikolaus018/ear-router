import Foundation
import Testing
@testable import EarRouter

/// Runs the real geocoder against the live Vienna register and Nominatim.
/// Off unless `LIVE_GEOCODE_CASES` names a JSON file of cases; results are
/// written to `LIVE_GEOCODE_OUT`. Pass both with a `TEST_RUNNER_` prefix.
@Suite struct LiveGeocodeTests {
    struct Case: Codable {
        let kind: String
        let input: String
        let plz: String
        let expect: String
        let lat: Double?
        let lon: Double?
    }
    struct Outcome: Codable {
        let kind: String
        let input: String
        let plz: String
        let expect: String
        let lat: Double?
        let lon: Double?
        var gotLat: Double?
        var gotLon: Double?
        var precision: String?
        var display: String?
        var error: String?
    }

    static var casesPath: String? { ProcessInfo.processInfo.environment["LIVE_GEOCODE_CASES"] }

    @Test(.enabled(if: casesPath != nil), .timeLimit(.minutes(30)))
    func geocodesEveryCase() async throws {
        let env = ProcessInfo.processInfo.environment
        let cases = try JSONDecoder().decode(
            [Case].self, from: Data(contentsOf: URL(fileURLWithPath: Self.casesPath!)))
        await GeocodeCache.shared.clear()

        var out: [Outcome] = []
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < cases.count else { return }
                let c = cases[next]; next += 1
                group.addTask {
                    var o = Outcome(
                        kind: c.kind, input: c.input, plz: c.plz, expect: c.expect,
                        lat: c.lat, lon: c.lon)
                    do {
                        let r = try await Geocoder.shared.geocode(strasse: c.input, plz: c.plz)
                        o.gotLat = r.lat; o.gotLon = r.lon
                        o.precision = "\(r.precision)"; o.display = r.displayName
                    } catch {
                        o.error = error.localizedDescription
                    }
                    return o
                }
            }
            for _ in 0..<6 { enqueue() }
            while let o = try await group.next() {
                out.append(o)
                enqueue()
            }
        }
        let path = env["LIVE_GEOCODE_OUT"] ?? NSTemporaryDirectory() + "live_geocode_out.json"
        try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: path))
    }
}
