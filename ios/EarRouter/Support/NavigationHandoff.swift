import CoreLocation
import Foundation

/// Hands a stop to whichever navigation app the driver uses.
///
/// In this order, the driver's call:
///
/// 1. **A pin placed by hand.** The driver stood at the door and said where
///    it is.
/// 2. **The house number's entrance**, from Vienna's register
///    (`Stop.entrance`). Sending the address alone left Waze guessing, and
///    for some addresses guessing wrong.
/// 3. **The address**, for everything else — outside Vienna, and stops whose
///    entrance is not known yet.
///
/// Not the building or Stiege point the map draws. The register places each
/// Stiege of a Gemeindebau separately — up to half a kilometre apart at
/// Rennbahnweg 27 — and a Stiege is often just a staircase inside a building
/// whose only way in is the street door, so that point drives round to the
/// wrong side. The entrance layer has one point per house number, on the
/// street, which is where the van stops.
enum NavigationHandoff {

    enum Provider: String, CaseIterable, Identifiable {
        case apple, waze, google

        var id: String { rawValue }

        var label: String {
            switch self {
            case .apple: "Karten"
            case .waze: "Waze"
            case .google: "Google Maps"
            }
        }

        func point(lat: Double, lon: Double) -> URL? {
            // Six decimal places is ~10 cm — far past what any navigation app
            // resolves, and short enough to keep the URL readable.
            let ll = String(
                format: "%.6f,%.6f",
                locale: Locale(identifier: "en_US_POSIX"),
                lat, lon)
            switch self {
            case .apple:
                return URL(string: "https://maps.apple.com/?daddr=\(ll)&dirflg=d")
            case .waze:
                return URL(string: "https://waze.com/ul?ll=\(ll)&navigate=yes")
            case .google:
                return URL(
                    string:
                        "https://www.google.com/maps/dir/?api=1&destination=\(ll)&travelmode=driving")
            }
        }

        /// The app itself, with nothing asked of it: whatever it is
        /// navigating to stays as it is. See `isUnderWay`.
        var front: URL? {
            switch self {
            case .apple: URL(string: "maps://")
            case .waze: URL(string: "waze://")
            case .google: URL(string: "comgooglemaps://")
            }
        }

        func address(_ addr: String) -> URL? {
            var allowed = CharacterSet.urlQueryAllowed
            // `+` as well as the obvious separators: it is legal in a query
            // string and `urlQueryAllowed` therefore leaves it alone, but the
            // form-encoding convention every maps service decodes with reads it
            // as a space — so an address carrying one arrives with a hole in it.
            allowed.remove(charactersIn: "&=?#+")
            guard let q = addr.addingPercentEncoding(withAllowedCharacters: allowed) else {
                return nil
            }
            switch self {
            case .apple:
                return URL(string: "https://maps.apple.com/?daddr=\(q)&dirflg=d")
            case .waze:
                return URL(string: "https://waze.com/ul?q=\(q)&navigate=yes")
            case .google:
                return URL(
                    string:
                        "https://www.google.com/maps/dir/?api=1&destination=\(q)&travelmode=driving")
            }
        }
    }

    /// Also read directly by `@AppStorage` in the settings screen, so it
    /// lives here rather than being spelled out twice.
    static let providerKey = "maps.provider"

    static var provider: Provider {
        get {
            UserDefaults.standard.string(forKey: providerKey)
                .flatMap(Provider.init(rawValue:)) ?? .apple
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    // MARK: - Already under way

    /// Which stop the navigation app was last sent to, and when.
    ///
    /// Two things start a navigation without a thumb on "Navigation": the tick
    /// at the door ("Geliefert" goes on to the next stop) and the car (the
    /// CarPlay automation, as the phone is plugged back in a minute later).
    /// Both mean the same stop. Sent twice, the navigation app throws away a
    /// route it is already driving and works the same one out again — so the
    /// second one to arrive only brings the app to the front.
    static let lastStopKey = "maps.lastStop"
    static let lastAtKey = "maps.lastAt"

    /// The walk from a door back to the van, generously. Past this the
    /// navigation app may have been closed or sent somewhere else by hand,
    /// and asking again is the safe thing.
    static let underWayFor: TimeInterval = 10 * 60

    static func noteStarted(
        _ stopID: UUID, at now: Date = Date(), in defaults: UserDefaults = .standard
    ) {
        defaults.set(stopID.uuidString, forKey: lastStopKey)
        defaults.set(now, forKey: lastAtKey)
    }

    static func isUnderWay(
        to stopID: UUID, at now: Date = Date(), in defaults: UserDefaults = .standard
    ) -> Bool {
        guard defaults.string(forKey: lastStopKey) == stopID.uuidString,
              let at = defaults.object(forKey: lastAtKey) as? Date
        else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < underWayFor
    }

    /// Pin, then entrance, then address — see the type's own comment.
    ///
    /// Every point through the postcode's own box, not `isFinite`: an unusable
    /// row's stored `0, 0` is finite, and handing that over would navigate the
    /// driver confidently into the Atlantic. The stored building point is
    /// still the last resort for a stop with no address text at all, which no
    /// screen can create but a hand-edited backup could.
    static func url(for stop: Stop) -> URL? {
        destination(for: stop).url(provider)
    }

    enum Destination: Equatable {
        case point(lat: Double, lon: Double)
        case address(String)
        case none

        func url(_ p: Provider) -> URL? {
            switch self {
            case .point(let lat, let lon): p.point(lat: lat, lon: lon)
            case .address(let a): p.address(a)
            case .none: nil
            }
        }
    }

    static func destination(for stop: Stop) -> Destination {
        let plausible = Coordinates.isPlausible(
            lat: stop.lat, lon: stop.lon, forPlz: stop.plz ?? "")
        if stop.pinned, plausible { return .point(lat: stop.lat, lon: stop.lon) }
        if let e = stop.entrance { return .point(lat: e.latitude, lon: e.longitude) }
        let address = stop.navigationAddress
        if !address.isEmpty { return .address(address) }
        return plausible ? .point(lat: stop.lat, lon: stop.lon) : .none
    }
}
