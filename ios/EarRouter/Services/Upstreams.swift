import Foundation

/// The three external services this app calls. There is no backend of its
/// own any more — the phone talks to these directly.
struct Upstreams: Sendable, Equatable {
    /// Vienna OGD "Adressservice Wien" `GetAddressInfo` — tried first for
    /// geocoding. The city's own ground-truth building register, so it covers
    /// real, currently-occupied addresses that OSM sometimes has not caught up
    /// on yet. Docs: https://digitales.wien.gv.at/adressservice-doku
    var wienOGD: URL
    /// Nominatim (OpenStreetMap) `/search` — the geocoding fallback.
    var nominatim: URL
    /// OSRM base URL, no trailing slash — routing and trip optimization.
    var osrm: URL

    static let defaultWienOGD = URL(
        string: "https://data.wien.gv.at/daten/OGDAddressService.svc/GetAddressInfo")!
    static let defaultNominatim = URL(
        string: "https://nominatim.openstreetmap.org/search")!
    /// The self-hosted OSRM, reachable from anywhere over a Cloudflare tunnel.
    /// The old LAN address it replaced could only ever be reached from home,
    /// which is exactly the wrong place for a phone in a van.
    static let defaultOSRM = URL(string: "https://osrm.ringtwo.win")!

    /// Used only when the configured OSRM is unreachable. Not itself
    /// configurable: it is a last resort, not a deployment choice.
    static let publicOSRMFallback = URL(string: "https://router.project-osrm.org")!

    static let `default` = Upstreams(
        wienOGD: defaultWienOGD, nominatim: defaultNominatim, osrm: defaultOSRM)

    /// Reads the OSRM override the user can set in Mehr → Erweitert;
    /// falls back to the built-in default for anything unparseable.
    static var current: Upstreams {
        var u = Upstreams.default
        if let raw = UserDefaults.standard.string(forKey: Keys.osrmURL),
           let url = overrideURL(raw) {
            u.osrm = url
        }
        return u
    }

    /// The parsed form of a typed server address, or `nil` when it is not
    /// something this app can call.
    ///
    /// HTTPS only, and that is not a stylistic preference: the app ships no App
    /// Transport Security exception, so a plain-`http` address is refused by the
    /// system before the request ever leaves the phone. Accepting one here —
    /// like accepting `ftp://osrm.example.com`, which "has a scheme and a host"
    /// used to — would have the settings screen confirm an address as valid and
    /// then have every routing call fail against it, with nothing on screen
    /// explaining why.
    static func overrideURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmed.trimmingSuffix("/")),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// Whether a non-empty typed address would actually be used. The settings
    /// screen says so out loud, because the fallback is otherwise silent.
    static func isUsableOverride(_ raw: String) -> Bool {
        overrideURL(raw) != nil
    }

    enum Keys {
        static let osrmURL = "upstream.osrm.url"
        static let routingEngine = "routing.engine"
    }
}

/// The engine that chooses the stop order and calculates the driven line.
enum RoutingEngine: String, CaseIterable, Identifiable, Sendable {
    case osrm
    case googleTraffic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .osrm: "OSRM"
        case .googleTraffic: "Google Verkehr"
        }
    }

    static var current: RoutingEngine {
        RoutingEngine(rawValue: UserDefaults.standard.string(forKey: Upstreams.Keys.routingEngine) ?? "")
            ?? .osrm
    }
}

/// Sent on every outbound call. Nominatim's usage policy requires a calling
/// application to identify itself so a misbehaving client can be traced or
/// blocked individually instead of the shared server being locked down for
/// everyone. Wien-OGD does not require it, but there is no reason to be
/// anonymous there either — and the public OSRM demo server outright rejects
/// a request with no `User-Agent` at all (403).
let upstreamUserAgent = "EAR-Router-iOS/1.0 (local delivery route planner)"

/// OSRM's public demo server refuses a `/trip` request with more waypoints
/// than this (`max-trip-size`, 100 by default). Checked before sending, so an
/// oversized route gets a German sentence explaining the real limit instead of
/// an opaque relayed "TooBig".
let osrmMaxTripCoords = 100

/// Compute Routes supports at most 25 intermediate stopovers. Origin and
/// destination make 27 coordinates in the shape used by this app.
let googleMaxTripCoords = 27

/// The trip cap minus the three fixed points, i.e. how many customers can go
/// on one route.
let maxBulkStops = 97

/// Field limits. Enforced in the editors so a too-long value is refused while
/// it is being typed, rather than after a round trip.
enum FieldLimits {
    static let kunde = 120
    static let strasse = 200
    static let paket = 200
    static let notiz = 1000
    static let telefon = 40
    static let routeName = 200
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        // Every string ends with the empty string, and removing none of it
        // changes nothing — so without this the loop never terminates.
        guard !suffix.isEmpty else { return self }
        var s = self
        while s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}

/// A failure worth showing the driver, in the language they read.
struct AppError: LocalizedError, Sendable {
    let message: String
    /// A hint the UI can act on — e.g. offering a one-tap district correction.
    var recovery: Recovery?

    enum Recovery: Sendable, Equatable {
        /// The address exists, but the register files it under this postcode.
        case wrongDistrict(actualPlz: String)
        /// No geocoder has this address; the driver can drop a pin instead.
        case notFound
    }

    var errorDescription: String? { message }

    static func message(_ m: String) -> AppError { AppError(message: m) }

    static let geocoderUnavailable = AppError(
        message: "Geocoding-Dienst nicht erreichbar. Bitte später erneut versuchen "
            + "oder den Pin von Hand setzen.")
    static let routerUnavailable = AppError(
        message: "Routing-Dienst nicht erreichbar.")

    static func notFound(_ query: String) -> AppError {
        AppError(
            message: "Adresse nicht gefunden: \(query). Bitte Schreibweise prüfen "
                + "oder den Pin von Hand setzen.",
            recovery: .notFound)
    }

    static func wrongDistrict(_ query: String, actualPlz: String) -> AppError {
        let name = Districts.name(for: actualPlz) ?? actualPlz
        return AppError(
            message: "„\(query)“ liegt laut Adressregister in \(actualPlz) (\(name)), "
                + "nicht in der gewählten PLZ.",
            recovery: .wrongDistrict(actualPlz: actualPlz))
    }
}
