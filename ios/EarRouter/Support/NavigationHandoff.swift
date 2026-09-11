import Foundation

/// Hands a stop to whichever navigation app the driver uses.
///
/// Always as an address, never as a point — the driver's call, and the split
/// is deliberate. The *map in this app* is drawn from the register's own
/// coordinates, because that is what shows which side of a Gemeindebau the
/// door is on. The *navigation app* gets the address, because a point is
/// something it routes to the nearest bit of road it happens to know, while an
/// address is something it has indexed, can show as a street name the driver
/// recognises, and plans a sensible arrival for.
///
/// This used to send an exactly-known stop as a point. It is the address now
/// for every stop; the point is kept only as the fallback for a stop that has
/// no address text at all — see `url(for:)`.
///
/// Sending the register's own point for a Stiege was weighed and turned down.
/// The register does place each Stiege of a Gemeindebau separately — up to
/// half a kilometre apart under one address at Rennbahnweg 27 — but a Stiege
/// is just as often an internal staircase of one building whose only way in
/// is the street door at the address, and a point drives the driver round to
/// the wrong side of it. The address is right far more often, so it is the
/// only thing sent.
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

    /// The address — see `Stop.navigationAddress` for the form it takes.
    ///
    /// The stored point only for a stop with no address text at all, which no
    /// screen in this app can create but a hand-edited backup could. Even then
    /// through the postcode's own box, not `isFinite`: an unusable row's
    /// stored `0, 0` is finite, and handing that over would navigate the
    /// driver confidently into the Atlantic.
    static func url(for stop: Stop) -> URL? {
        let p = provider
        let address = stop.navigationAddress
        if !address.isEmpty { return p.address(address) }
        guard Coordinates.isPlausible(lat: stop.lat, lon: stop.lon, forPlz: stop.plz ?? "")
        else { return nil }
        return p.point(lat: stop.lat, lon: stop.lon)
    }
}
