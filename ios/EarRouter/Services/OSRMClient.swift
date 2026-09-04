import Foundation
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "osrm")

/// OSRM — the routing engine. Two calls do everything the app needs:
/// `routeLeg` for a fixed leg that is never reordered, and `trip` for the
/// multi-stop ordering problem.
///
/// An actor because of the primary-down cooldown: several stops being
/// re-optimized at once must not each pay their own full connect attempt to a
/// primary that is already known to be down.
actor OSRMClient {
    static let shared = OSRMClient()

    /// How long a primary-OSRM failure is remembered before the next request
    /// tries the primary again. Without this, a persistently-down instance
    /// would pay a full connect attempt on *every* call before falling back —
    /// added latency on the one thing a driver waits on interactively. Short
    /// enough that a primary coming back (a reboot, a restarted tunnel) is
    /// noticed again within about a minute.
    private static let primaryRetryAfter: TimeInterval = 60
    /// How long the primary gets to answer before the public fallback is tried.
    /// This caps the failure the connect timeout does not: a primary that
    /// *accepts* the connection and then stalls (a container still loading its
    /// graph, a captive portal swallowing the request).
    private static let primaryDeadline: TimeInterval = 4

    private var primaryDownSince: Date?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": upstreamUserAgent]
        return URLSession(configuration: c)
    }()

    // MARK: - Public API

    /// Real distance, duration and geometry for a single fixed leg — used for
    /// the depot → warehouse leg, which is always first and never reordered.
    func routeLeg(
        from a: (lat: Double, lon: Double),
        to b: (lat: Double, lon: Double)
    ) async throws -> (distance: Double, duration: Double, geometry: [[Double]]) {
        let path = "/route/v1/driving/\(Self.coordString([a, b]))"
            + "?overview=full&geometries=geojson"
        let resp: RouteResponse = try await get(path)
        guard resp.code == "Ok" else {
            throw AppError.message("OSRM route: \(resp.code)")
        }
        guard let route = resp.routes.first else {
            throw AppError.message("OSRM: keine Route gefunden")
        }
        return (route.distance, route.duration, Self.toPolyline(route.geometry))
    }

    /// Solves the multi-stop ordering problem via OSRM's `/trip` endpoint,
    /// with every point that is not pinned free to be reordered however
    /// minimizes total travel time.
    ///
    /// `fixFirst` pins `coords[0]` as the trip's start and `fixLast` pins the
    /// last as its end; an unpinned end is left open. At least one of the two
    /// must be set: OSRM answers `roundtrip=false` with *both* open as
    /// `NotImplemented`, so that combination is a bug in the caller rather
    /// than a routing failure to report to the driver.
    ///
    /// Returns the visiting order as indices into `coords`, the per-leg
    /// (distance, duration) in that visiting order, and the full geometry.
    func trip(
        coords: [(lat: Double, lon: Double)],
        fixFirst: Bool,
        fixLast: Bool
    ) async throws -> (order: [Int], legs: [(Double, Double)], geometry: [[Double]]) {
        assert(fixFirst || fixLast, "trip needs at least one pinned end")

        // Callers already skip the trip call for fewer than two points; this
        // makes that a thrown error rather than an index crash below.
        guard coords.count >= 2 else {
            throw AppError.message("OSRM: Routenabschnitt mit weniger als zwei Punkten")
        }
        guard coords.count <= osrmMaxTripCoords else {
            throw AppError.message(
                "Zu viele Stopps für die Routenoptimierung (\(coords.count) Wegpunkte, "
                    + "max. \(osrmMaxTripCoords)). Bitte die Route auf mehrere Touren aufteilen.")
        }

        let path = "/trip/v1/driving/\(Self.coordString(coords))"
            + "?source=\(fixFirst ? "first" : "any")"
            + "&destination=\(fixLast ? "last" : "any")"
            + "&roundtrip=false&overview=full&geometries=geojson"
        let resp: TripResponse = try await get(path)
        guard resp.code == "Ok" else {
            throw AppError.message("OSRM trip: \(resp.code)")
        }
        guard let trip = resp.trips.first else {
            throw AppError.message("OSRM: keine Route gefunden")
        }
        guard resp.waypoints.count == coords.count else {
            throw AppError.message("OSRM: unerwartete Antwort (Stopp-Anzahl stimmt nicht)")
        }

        // `waypoints[i].waypointIndex` is where input point `i` landed in the
        // optimized visiting order — invert it into "order[position] = input
        // index" so the caller can walk the trip in visiting order directly.
        // The result has to be a genuine permutation: a repeated or
        // out-of-range index would silently produce a route that visits one
        // stop twice and drops another, which is far worse than refusing to
        // reorder at all.
        var order = [Int](repeating: 0, count: coords.count)
        var seen = [Bool](repeating: false, count: coords.count)
        for (inputIdx, wp) in resp.waypoints.enumerated() {
            guard wp.waypointIndex >= 0, wp.waypointIndex < order.count,
                  !seen[wp.waypointIndex]
            else {
                throw AppError.message("OSRM: unerwartete Antwort (ungültige Stopp-Reihenfolge)")
            }
            seen[wp.waypointIndex] = true
            order[wp.waypointIndex] = inputIdx
        }

        // OSRM is asked to pin these ends, but the caller *relies* on it: the
        // first visiting position is the node already written into the route's
        // node list, and the last is the depot the tour has to finish at. A
        // response that quietly reordered either one would be walked as if it
        // had not, duplicating one stop and dropping another.
        if fixFirst && order[0] != 0 {
            throw AppError.message("OSRM: unerwartete Antwort (Startpunkt wurde verschoben)")
        }
        if fixLast && order[order.count - 1] != coords.count - 1 {
            throw AppError.message("OSRM: unerwartete Antwort (Zielpunkt wurde verschoben)")
        }

        // A non-roundtrip trip over n waypoints has exactly n-1 legs. Anything
        // else and the caller's `legs[pos - 1]` indexing would silently pair
        // each stop with the wrong leg's distance — a route that looks
        // entirely normal on screen while telling the driver the wrong
        // "x km to the next stop" for every single row.
        guard trip.legs.count + 1 == coords.count else {
            throw AppError.message("OSRM: unerwartete Antwort (Etappen-Anzahl stimmt nicht)")
        }

        return (order, trip.legs.map { ($0.distance, $0.duration) },
                Self.toPolyline(trip.geometry))
    }

    // MARK: - Transport

    /// GETs an OSRM path against the configured primary, falling back to the
    /// public demo server if the primary cannot be reached or answers with
    /// something that does not parse as OSRM JSON. The point of a self-hosted
    /// instance is speed and not sharing the public server's quota, not
    /// availability — an outage there should not take routing down entirely
    /// when the public server can still answer the same request.
    private func get<T: Decodable & Sendable>(_ pathAndQuery: String) async throws -> T {
        let primary = Upstreams.current.osrm
        let fallback = Upstreams.publicOSRMFallback
        let primaryIsFallback = primary == fallback

        // A primary that just failed is skipped for the cooldown rather than
        // retried on every call. Never skipped when it *is* the public
        // fallback — there is nothing to skip to.
        let skipPrimary = !primaryIsFallback
            && (primaryDownSince.map { Date().timeIntervalSince($0) < Self.primaryRetryAfter }
                ?? false)

        if !skipPrimary {
            do {
                let value: T = try await withDeadline(Self.primaryDeadline) {
                    try await Self.fetch(self.session, base: primary, path: pathAndQuery)
                }
                // Recovered (or never down) — clear the earlier verdict so the
                // next failure gets a fresh cooldown, not a leftover one.
                primaryDownSince = nil
                return value
            } catch {
                if primaryIsFallback {
                    log.error("OSRM unreachable: \(error.localizedDescription)")
                    throw AppError.routerUnavailable
                }
                log.warning(
                    "primary OSRM unreachable, falling back to public server: \(error.localizedDescription)")
                primaryDownSince = Date()
            }
        }

        do {
            return try await Self.fetch(session, base: fallback, path: pathAndQuery)
        } catch {
            log.error("public OSRM unreachable: \(error.localizedDescription)")
            throw AppError.routerUnavailable
        }
    }

    /// One GET + JSON decode against a single OSRM base — no fallback logic,
    /// just the mechanics `get` needs to try twice.
    private static func fetch<T: Decodable & Sendable>(
        _ session: URLSession, base: URL, path: String
    ) async throws -> T {
        guard let url = URL(string: base.absoluteString + path) else {
            throw AppError.message("OSRM: ungültige URL")
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppError.message("OSRM HTTP \(code)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Races `work` against a deadline. `Task.timeout` does not exist, and a
    /// `URLSession` timeout alone cannot express "give the primary 4 seconds
    /// but allow the fallback the full 20".
    private func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AppError.message("no response within \(Int(seconds))s")
            }
            guard let first = try await group.next() else {
                throw AppError.routerUnavailable
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Encoding

    /// OSRM takes `lon,lat` pairs, semicolon-separated — the opposite order
    /// from how the rest of this app writes a coordinate.
    private static func coordString(_ coords: [(lat: Double, lon: Double)]) -> String {
        coords.map { String(format: "%.6f,%.6f", $0.lon, $0.lat) }.joined(separator: ";")
    }

    /// GeoJSON is `[lon, lat]`; everything downstream of here wants `[lat, lon]`.
    private static func toPolyline(_ geom: Geometry) -> [[Double]] {
        geom.coordinates.compactMap { pair in
            pair.count == 2 ? [pair[1], pair[0]] : nil
        }
    }

    // MARK: - Wire types

    private struct Geometry: Decodable {
        let coordinates: [[Double]]
    }
    private struct RouteResponse: Decodable {
        let code: String
        let routes: [RouteEntry]
    }
    private struct RouteEntry: Decodable {
        let geometry: Geometry
        let distance: Double
        let duration: Double
    }
    private struct TripResponse: Decodable {
        let code: String
        let trips: [TripEntry]
        let waypoints: [Waypoint]
    }
    private struct TripEntry: Decodable {
        let geometry: Geometry
        let legs: [Leg]
    }
    private struct Leg: Decodable {
        let distance: Double
        let duration: Double
    }
    private struct Waypoint: Decodable {
        let waypointIndex: Int
        enum CodingKeys: String, CodingKey { case waypointIndex = "waypoint_index" }
    }
}
