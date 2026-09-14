import Foundation
import Security

/// Google Routes' traffic-aware driving route and waypoint optimizer.
actor GoogleRoutesClient {
    static let shared = GoogleRoutesClient()

    private let endpoint = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 35
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": upstreamUserAgent]
        return URLSession(configuration: config)
    }()

    func routeLeg(from a: (lat: Double, lon: Double), to b: (lat: Double, lon: Double)) async throws -> (distance: Double, duration: Double, geometry: [[Double]]) {
        let response = try await compute(origin: a, destination: b, intermediates: [], optimize: false)
        guard let route = response.routes.first else { throw AppError.routerUnavailable }
        return (route.distanceMeters, try Self.seconds(route.duration), Self.decodePolyline(route.polyline.encodedPolyline))
    }

    func trip(coords: [(lat: Double, lon: Double)], fixFirst: Bool, fixLast: Bool) async throws -> (order: [Int], legs: [(Double, Double)], geometry: [[Double]]) {
        guard fixFirst, fixLast else {
            throw AppError.message("Google Verkehr braucht einen festen Start und ein festes Ziel. Bitte Start und Ziel einschalten oder OSRM wählen.")
        }
        guard coords.count >= 2, coords.count <= googleMaxTripCoords else {
            throw AppError.message("Google Verkehr kann diese Tour mit höchstens 25 frei sortierbaren Stopps planen. Bitte die Tour aufteilen oder OSRM wählen.")
        }
        let response = try await compute(origin: coords[0], destination: coords[coords.count - 1], intermediates: Array(coords.dropFirst().dropLast()), optimize: true)
        guard let route = response.routes.first else { throw AppError.routerUnavailable }
        let intermediateOrder = try Self.intermediateOrder(
            route.optimizedIntermediateWaypointIndex, count: max(0, coords.count - 2))
        let legs = try route.legs.map { leg in
            (leg.distanceMeters, try Self.seconds(leg.duration))
        }
        guard legs.count + 1 == coords.count else { throw AppError.message("Google Verkehr: unerwartete Etappen-Anzahl") }
        return ([0] + intermediateOrder.map { $0 + 1 } + [coords.count - 1], legs, Self.decodePolyline(route.polyline.encodedPolyline))
    }

    func probe() async -> Bool {
        do { _ = try await routeLeg(from: (48.2082, 16.3738), to: (48.2170, 16.3919)); return true } catch { return false }
    }

    private func compute(origin: (lat: Double, lon: Double), destination: (lat: Double, lon: Double), intermediates: [(lat: Double, lon: Double)], optimize: Bool) async throws -> Response {
        guard let key = GoogleRoutesKeyStore.load() else {
            throw AppError.message("Für Google Verkehr fehlt der API-Schlüssel in Mehr → Erweitert.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("routes.distanceMeters,routes.duration,routes.polyline.encodedPolyline,routes.legs.distanceMeters,routes.legs.duration,routes.optimizedIntermediateWaypointIndex", forHTTPHeaderField: "X-Goog-FieldMask")
        request.httpBody = try JSONEncoder().encode(Request(origin: Point(origin), destination: Point(destination), intermediates: intermediates.map(Point.init), optimizeWaypointOrder: optimize))
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw AppError.message("Google Verkehr hat keine gültige Antwort geliefert.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.failure(statusCode: response.statusCode, data: data)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AppError.message(
                "Google Verkehr hat eine unlesbare Antwort geliefert. Bitte später erneut versuchen.")
        }
    }

    private static func failure(statusCode: Int, data: Data) -> AppError {
        let detail = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
        let text = [detail?.status, detail?.message].compactMap { $0 }.joined(separator: " ")
        switch statusCode {
        case 403 where text.contains("SERVICE_DISABLED"):
            return AppError.message(
                "Die Google Routes API ist für diesen Schlüssel nicht aktiviert. "
                    + "Bitte in Google Cloud aktivieren und danach einige Minuten warten.")
        case 403:
            return AppError.message(
                "Google hat den API-Schlüssel abgelehnt. Bitte Schlüssel, API-Beschränkung und "
                    + "Abrechnung in Google Cloud prüfen.")
        case 429:
            return AppError.message(
                "Google Verkehr hat das Nutzungslimit erreicht. Bitte später erneut versuchen.")
        case 400:
            return AppError.message(
                "Google Verkehr konnte diese Tour nicht berechnen. Bitte die Stopps und Pins prüfen.")
        default:
            return AppError.message("Google Verkehr ist vorübergehend nicht erreichbar (HTTP (statusCode)).")
        }
    }

    private static func seconds(_ duration: String) throws -> Double {
        guard duration.hasSuffix("s"), let seconds = Double(duration.dropLast()) else { throw AppError.message("Google Verkehr: ungültige Fahrzeit") }
        return seconds
    }

    /// Google sends `[-1]` for a route with one intermediate stop: there is no
    /// meaningful permutation, so `-1` means "leave its sole stop where it
    /// is". For two or more stops it returns an actual permutation.
    static func intermediateOrder(_ returned: [Int]?, count: Int) throws -> [Int] {
        if count == 1, returned == [-1] { return [0] }
        let order = returned ?? []
        guard order.count == count, Set(order) == Set(0..<count) else {
            throw AppError.message("Google Verkehr: unerwartete Stopp-Reihenfolge")
        }
        return order
    }

    /// Google's encoded polyline is the standard five-decimal Google format.
    static func decodePolyline(_ value: String) -> [[Double]] {
        let bytes = Array(value.utf8); var index = 0, latitude = 0, longitude = 0; var result: [[Double]] = []
        func next() -> Int? {
            var shift = 0, output = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63; index += 1; output |= (byte & 0x1f) << shift; shift += 5
                if byte < 0x20 { return (output & 1) == 1 ? ~(output >> 1) : output >> 1 }
            }
            return nil
        }
        while let lat = next(), let lon = next() { latitude += lat; longitude += lon; result.append([Double(latitude) / 100_000, Double(longitude) / 100_000]) }
        return result
    }

    private struct Request: Encodable { let origin: Point; let destination: Point; let intermediates: [Point]; let travelMode = "DRIVE"; let routingPreference = "TRAFFIC_AWARE"; let optimizeWaypointOrder: Bool }
    private struct Point: Encodable { let location: Location; init(_ point: (lat: Double, lon: Double)) { location = Location(latLng: LatLng(latitude: point.lat, longitude: point.lon)) } }
    private struct Location: Encodable { let latLng: LatLng }
    private struct LatLng: Encodable { let latitude: Double; let longitude: Double }
    private struct Response: Decodable { let routes: [Route] }
    private struct Route: Decodable { let distanceMeters: Double; let duration: String; let polyline: Polyline; let legs: [Leg]; let optimizedIntermediateWaypointIndex: [Int]? }
    private struct Leg: Decodable { let distanceMeters: Double; let duration: String }
    private struct Polyline: Decodable { let encodedPolyline: String }
    private struct ErrorResponse: Decodable { let error: ErrorDetail }
    private struct ErrorDetail: Decodable { let status: String?; let message: String? }
}

/// This is a billable credential, so it belongs in the Keychain—not a readable
/// preference or a backup. It is entered only by the person who owns the
/// Google Cloud project and stays on that phone.
enum GoogleRoutesKeyStore {
    private static let service = "at.essenfuerdaheim.EarRouter.google-routes"
    private static let account = "routes-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { return false }
        guard let data = value.trimmed.nilIfEmpty?.data(using: .utf8) else { return true }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
