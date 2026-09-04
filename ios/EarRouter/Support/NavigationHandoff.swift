import Foundation

/// Hands a stop to whichever navigation app the driver uses.
///
/// There are two genuinely different kinds of destination to hand over: a
/// point, or a string to look up — and which one is right depends on how well
/// this app actually knows the address.
///
/// An exactly-known stop is sent as a *point*, which is the whole value of
/// having resolved it against Vienna's address register: that register pins the
/// registered position of *that* door, including the ones no navigation app can
/// find. Waze has no Kleingarten-Parzellen and no Stiegen, so handing it
/// "Großfeldstraße 9/Parz.68" drops the driver at the colony gate, 130 m and a
/// walk from the plot. There is precedent for the text failing outright too —
/// the warehouse was once stored as "Oberlaa Straße 298", which the app
/// displayed happily and the phone's Maps app searched for in vain.
///
/// An *approximate* stop (the "≈" badge — nearest known housenumber, or
/// district centre) is sent as text on purpose: our point is an admitted guess
/// there, and driving someone confidently to a guess is worse than letting
/// their own navigation app take its own shot at the address.
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
            allowed.remove(charactersIn: "&=?#")
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

    static func url(for stop: Stop) -> URL? {
        let p = provider
        let isExact = stop.precision == nil && stop.lat.isFinite && stop.lon.isFinite
        if isExact {
            return p.point(lat: stop.lat, lon: stop.lon)
        }
        return p.address(stop.fullAddress)
    }
}
