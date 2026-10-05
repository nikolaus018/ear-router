import Foundation
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "osrm")

/// OSRM — the routing engine. Two calls do everything a tour needs:
/// `routeLeg` for a fixed leg that is never reordered, and `trip` for the
/// multi-stop ordering problem. `snapDistance` is beside them for the toilets.
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
    /// How long the primary gets to answer a two-point call before the public
    /// fallback is tried. This caps the failure the connect timeout does not: a
    /// primary that *accepts* the connection and then stalls (a container still
    /// loading its graph, a captive portal swallowing the request).
    private static let baseDeadline: TimeInterval = 4
    /// Added per waypoint past the first two.
    ///
    /// A flat deadline was wrong, and wrong in the direction that hurts most.
    /// `/route` over two points answers in tens of milliseconds; `/trip` over
    /// ninety-seven customers is a travelling-salesman solve, and a self-hosted
    /// instance on a small box takes seconds over it — legitimately. Four
    /// seconds therefore timed out the *healthy* primary on exactly the tours
    /// that need it most, marked it down for a minute, and sent the request to
    /// the public demo server, which is slower, shared, and sitting at its own
    /// hundred-waypoint ceiling. The symptom was "big tours always route via
    /// the demo server", and the cooldown made it stick for the rest of the
    /// morning.
    private static let deadlinePerWaypoint: TimeInterval = 0.15

    /// Never past `timeoutIntervalForRequest`, which is the real ceiling — a
    /// deadline longer than the session's own timeout can never fire.
    static func primaryDeadline(waypoints: Int) -> TimeInterval {
        min(20, baseDeadline + deadlinePerWaypoint * Double(max(0, waypoints - 2)))
    }

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
        let resp: RouteResponse = try await get(path, waypoints: 2)
        guard resp.code == "Ok" else {
            throw Self.failure(code: resp.code)
        }
        guard let route = resp.routes.first else {
            throw AppError.message("OSRM: keine Route gefunden")
        }
        return (route.distance, route.duration, Self.toPolyline(route.geometry))
    }

    /// Distance, duration and geometry along `coords` in exactly the order
    /// given — for a tour the driver has put in order by hand, where nothing
    /// may be moved. Legs are in that order: `legs[i]` runs from `coords[i]`
    /// to `coords[i + 1]`.
    func routeThrough(
        _ coords: [(lat: Double, lon: Double)]
    ) async throws -> (legs: [(Double, Double)], geometry: [[Double]]) {
        guard coords.count >= 2 else {
            throw AppError.message("OSRM: Routenabschnitt mit weniger als zwei Punkten")
        }
        guard coords.count <= osrmMaxTripCoords else {
            throw AppError.message(
                "Zu viele Stopps für die Route (\(coords.count) Wegpunkte, "
                    + "max. \(osrmMaxTripCoords)). Bitte die Route auf mehrere Touren aufteilen.")
        }
        let path = "/route/v1/driving/\(Self.coordString(coords))"
            + "?overview=full&geometries=geojson"
        let resp: RouteResponse = try await get(path, waypoints: coords.count)
        guard resp.code == "Ok" else {
            throw Self.failure(code: resp.code)
        }
        guard let route = resp.routes.first else {
            throw AppError.message("OSRM: keine Route gefunden")
        }
        let legs = route.legs ?? []
        try Self.checkLegCount(legs.count, waypoints: coords.count)
        return (legs.map { ($0.distance, $0.duration) }, Self.toPolyline(route.geometry))
    }

    /// Metres from a point to the nearest road a car may use, from OSRM's
    /// `/nearest` — how far a toilet is from where the van can stand. See
    /// `RestroomUpdater`.
    func snapDistance(lat: Double, lon: Double) async throws -> Double {
        let path = "/nearest/v1/driving/\(Self.coordString([(lat: lat, lon: lon)]))?number=1"
        let resp: NearestResponse = try await get(path, waypoints: 1)
        guard resp.code == "Ok", let nearest = resp.waypoints.first else {
            throw Self.failure(code: resp.code)
        }
        return nearest.distance
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
        let resp: TripResponse = try await get(path, waypoints: coords.count)
        guard resp.code == "Ok" else {
            throw Self.failure(code: resp.code)
        }
        guard let trip = resp.trips.first else {
            throw AppError.message("OSRM: keine Route gefunden")
        }
        // The waypoint count is checked inside `visitingOrder`, along with
        // everything else about the ordering it hands back.
        let order = try Self.visitingOrder(
            waypointIndices: resp.waypoints.map(\.waypointIndex),
            count: coords.count, fixFirst: fixFirst, fixLast: fixLast)

        try Self.checkLegCount(trip.legs.count, waypoints: coords.count)

        return (order, trip.legs.map { ($0.distance, $0.duration) },
                Self.toPolyline(trip.geometry))
    }

    /// Inverts OSRM's waypoint mapping into the visiting order, and refuses
    /// anything that is not a genuine permutation of the points we sent.
    ///
    /// `waypointIndices[i]` is where input point `i` landed in the optimized
    /// order; the caller wants the other direction — "order[position] = input
    /// index" — so it can walk the trip in the order it is driven.
    ///
    /// The validation is the point. A repeated or out-of-range index produces a
    /// route that visits one stop twice and drops another, and the pinned ends
    /// are not a request but a *dependency*: the first visiting position is the
    /// node already written into the route's list and the last is the depot the
    /// tour has to finish at, so a response that quietly moved either would be
    /// walked as if it had not. Every one of those failures yields a route that
    /// looks completely ordinary on screen — right number of rows, plausible
    /// distances — while sending the driver to the wrong doors. Refusing to
    /// reorder at all is enormously better, and that is why this is separated
    /// out from the request: so it can be tested without one.
    static func visitingOrder(
        waypointIndices: [Int], count: Int, fixFirst: Bool, fixLast: Bool
    ) throws -> [Int] {
        guard count > 0, waypointIndices.count == count else {
            throw AppError.message("OSRM: unerwartete Antwort (Stopp-Anzahl stimmt nicht)")
        }

        var order = [Int](repeating: 0, count: count)
        var seen = [Bool](repeating: false, count: count)
        for (inputIndex, position) in waypointIndices.enumerated() {
            guard position >= 0, position < count, !seen[position] else {
                throw AppError.message(
                    "OSRM: unerwartete Antwort (ungültige Stopp-Reihenfolge)")
            }
            seen[position] = true
            order[position] = inputIndex
        }

        if fixFirst && order[0] != 0 {
            throw AppError.message("OSRM: unerwartete Antwort (Startpunkt wurde verschoben)")
        }
        if fixLast && order[count - 1] != count - 1 {
            throw AppError.message("OSRM: unerwartete Antwort (Zielpunkt wurde verschoben)")
        }
        return order
    }

    /// A non-roundtrip trip over n waypoints has exactly n-1 legs.
    ///
    /// Anything else and the caller's per-position indexing silently pairs each
    /// stop with the wrong leg's distance — a route that looks entirely normal
    /// on screen while telling the driver the wrong "x km to the next stop" for
    /// every single row. Separated from the request for the same reason
    /// `visitingOrder` is: it is a check, and a check nothing exercises is a
    /// check that has already stopped working.
    static func checkLegCount(_ legs: Int, waypoints: Int) throws {
        guard legs + 1 == waypoints else {
            throw AppError.message("OSRM: unerwartete Antwort (Etappen-Anzahl stimmt nicht)")
        }
    }

    /// Turns an OSRM status code into something a driver can act on.
    ///
    /// The codes themselves are protocol words — `NoRoute`, `NoSegment`,
    /// `InvalidValue` — and they were going straight into the alert, so a tap on
    /// "Neu optimieren" could answer with "OSRM trip: NoSegment". This app is
    /// otherwise careful never to do that (see the Nominatim path, which logs
    /// its networking errors and shows none of them); routing was the one place
    /// that leaked. The code is still logged, because that is who it is for.
    /// Not private, for the reason `visitingOrder` is not: it is a decision,
    /// it is pure, and it can be checked without a request.
    static func failure(code: String) -> AppError {
        log.error("OSRM refused the request: \(code, privacy: .public)")
        switch code {
        case "NoRoute", "NoTrips", "NoSegment":
            // The likeliest cause by far is a hand-placed pin that ended up
            // somewhere no vehicle can reach — a courtyard, a field, the far
            // side of the Danube — so the message points at the pins.
            return AppError.message(
                "Für diese Stopps lässt sich keine Fahrtroute berechnen. Meistens liegt "
                    + "das an einem Pin abseits der Straße — bitte die Stopps auf der Karte "
                    + "prüfen.")
        case "TooBig":
            return AppError.message(
                "Die Tour hat zu viele Stopps für die Routenoptimierung. Bitte auf mehrere "
                    + "Touren aufteilen.")
        case "NotImplemented":
            // The server answered — it only cannot plan a tour of this shape.
            // "Nicht erreichbar" sent the driver to check a server that was up.
            return AppError.message(
                "Der Routing-Server kann diese Tour so nicht berechnen. Bitte Start oder "
                    + "Ziel wieder einplanen.")
        default:
            return AppError.routerUnavailable
        }
    }

    /// Asks one specific server whether it can route, with no fallback and no
    /// cooldown — what "Verbindung testen" in Erweitert actually means.
    ///
    /// Deliberately not `routeLeg`: that one is built to *succeed*, falling
    /// back to the public demo server whenever the configured one cannot
    /// answer. Used as a connection test it reported "Erreichbar" for a server
    /// that was not, on the strength of a reply from somewhere else entirely —
    /// on the one screen whose whole job is telling the driver whether their
    /// own server is up.
    func probe(base: URL) async -> Bool {
        // Two points on the Ring — a query every OSRM build can answer.
        //
        // `overview=false` because a test needs no geometry, and its own reply
        // type because of that: `overview=false` makes OSRM *omit* the
        // `geometry` field entirely, so decoding the answer as an ordinary
        // `RouteResponse` — whose `geometry` is not optional — failed on a
        // perfectly healthy server and reported it unreachable. Only `code` is
        // read here, which is all "can this server route?" needs.
        let path = "/route/v1/driving/16.3738,48.2082;16.3919,48.2170?overview=false"
        do {
            let resp: ProbeResponse = try await Self.fetch(session, base: base, path: path)
            return resp.code == "Ok"
        } catch {
            log.info("OSRM probe of \(base.absoluteString, privacy: .public) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Transport

    /// GETs an OSRM path against the configured primary, falling back to the
    /// public demo server if the primary cannot be reached or answers with
    /// something that does not parse as OSRM JSON. The point of a self-hosted
    /// instance is speed and not sharing the public server's quota, not
    /// availability — an outage there should not take routing down entirely
    /// when the public server can still answer the same request.
    private func get<T: Decodable & Sendable>(
        _ pathAndQuery: String, waypoints: Int
    ) async throws -> T {
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
                let value: T = try await withDeadline(
                    Self.primaryDeadline(waypoints: waypoints)
                ) {
                    try await Self.fetch(self.session, base: primary, path: pathAndQuery)
                }
                // Recovered (or never down) — clear the earlier verdict so the
                // next failure gets a fresh cooldown, not a leftover one.
                primaryDownSince = nil
                return value
            } catch is CancellationError {
                // The caller walked away. That says nothing about the server, so
                // it must not start a cooldown — a cancelled add-stop would
                // otherwise send the next hour's routing to the public demo
                // server on the strength of a healthy primary the driver simply
                // did not wait for. And there is nothing to fall back *to*: the
                // answer is no longer wanted.
                throw CancellationError()
            } catch let refusal as Refusal where refusal.code == "NotImplemented" && !primaryIsFallback {
                // Not this tour's fault but this server's version: the home
                // OSRM answers a trip with one open end — Ziel switched off —
                // "NotImplemented", and the public server routes it. Up, so no
                // cooldown; this one request goes to the fallback.
                log.warning("primary OSRM cannot do this request, asking the public server")
                primaryDownSince = nil
            } catch let refusal as Refusal {
                // The server is up and has answered: this request cannot be
                // routed. Asking the demo server the same question gets the
                // same answer, and the pin that caused it is what the driver
                // needs to hear about — not a routing service that is fine.
                primaryDownSince = nil
                throw Self.failure(code: refusal.code)
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let refusal as Refusal {
            throw Self.failure(code: refusal.code)
        } catch {
            log.error("public OSRM unreachable: \(error.localizedDescription)")
            throw AppError.routerUnavailable
        }
    }

    /// OSRM said no to this request. A routing answer, not an outage — see
    /// `refusalCode(status:body:)`.
    struct Refusal: Error {
        let code: String
    }

    /// The code in an OSRM refusal, or `nil` when the reply is not one.
    ///
    /// OSRM answers every request it will not route — `NoRoute`, `NoSegment`,
    /// `TooBig`, `InvalidOptions` — with HTTP 400 and its code in the body.
    /// The status was checked before the body was ever read, so each of those
    /// came through as "OSRM HTTP 400": the healthy home server was marked
    /// down for a minute, the request went to the demo server, and the driver
    /// was told the routing service was unreachable. `failure(code:)`, with
    /// its sentence about the pins, never ran at all. A reply that does not
    /// decode as OSRM's own — a tunnel's error page, a proxy's — is still an
    /// outage, and falls back as before.
    static func refusalCode(status: Int, body: Data) -> String? {
        guard !(200..<300).contains(status),
              let reply = try? JSONDecoder().decode(ProbeResponse.self, from: body),
              reply.code != "Ok"
        else { return nil }
        return reply.code
    }

    /// One GET + JSON decode against a single OSRM base — no fallback logic,
    /// just the mechanics `get` needs to try twice.
    private static func fetch<T: Decodable & Sendable>(
        _ session: URLSession, base: URL, path: String
    ) async throws -> T {
        guard let url = URL(string: base.absoluteString + path) else {
            throw AppError.message("OSRM: ungültige URL")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(from: url)
        } catch let e as URLError where e.code == .cancelled {
            // `URLSession` reports a request cancelled along with its task as a
            // `URLError`, not as a `CancellationError`. Left as it comes, the
            // caller above cannot tell it from an outage — and treats a driver
            // tapping Abbrechen as a server that has gone down.
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let code = refusalCode(status: status, body: data) { throw Refusal(code: code) }
            throw AppError.message("OSRM HTTP \(status)")
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
    /// Not private: getting this pair the wrong way round sends every tour in
    /// the app to a different country, and it is one line that never throws.
    static func coordString(_ coords: [(lat: Double, lon: Double)]) -> String {
        coords
            .map {
                String(
                    format: "%.6f,%.6f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    $0.lon, $0.lat)
            }
            .joined(separator: ";")
    }

    /// GeoJSON is `[lon, lat]`; everything downstream of here wants `[lat, lon]`.
    private static func toPolyline(_ geom: Geometry) -> [[Double]] {
        flip(geom.coordinates)
    }

    /// The same swap, taking the raw pairs — so the one line that decides
    /// which hemisphere the route is drawn in can be checked directly.
    static func flip(_ coordinates: [[Double]]) -> [[Double]] {
        coordinates.compactMap { pair in
            pair.count == 2 ? [pair[1], pair[0]] : nil
        }
    }

    // MARK: - Wire types

    private struct Geometry: Decodable {
        let coordinates: [[Double]]
    }
    /// Just OSRM's status word — see `probe` and `refusalCode`.
    private struct ProbeResponse: Decodable {
        let code: String
    }
    private struct RouteResponse: Decodable {
        let code: String
        let routes: [RouteEntry]
    }
    private struct RouteEntry: Decodable {
        let geometry: Geometry
        let distance: Double
        let duration: Double
        /// Only `routeThrough` reads these; `routeLeg` has one and uses the
        /// totals above.
        let legs: [Leg]?
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
    private struct NearestResponse: Decodable {
        let code: String
        let waypoints: [Snapped]
        struct Snapped: Decodable { let distance: Double }
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
