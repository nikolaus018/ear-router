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

    /// How far a Stiege may be from its house number's entrance before the
    /// Stiege itself is the better place to be sent.
    ///
    /// Measured on real buildings: an ordinary house keeps every Stiege within
    /// about 40 m of the entrance (Gentzgasse 129: 9–36 m), so sending the
    /// entrance costs nothing there and avoids the Stiege point's one failure —
    /// a navigation app routing to whichever road is nearest to a courtyard,
    /// round the back. A large Gemeindebau is another thing: Rennbahnweg 27 has
    /// one entrance point for 66 Stiegen up to 429 m away, the Karl-Marx-Hof
    /// up to 437 m. There the entrance is the wrong end of the block.
    static let stiegeDistance: CLLocationDistance = 50

    /// The stop's own point is a Stiege the register matched exactly, and far
    /// enough from the house number's entrance to be worth driving to instead.
    ///
    /// Only for an address that names a Stiege and was placed exactly: without
    /// one, `lat`/`lon` are the house number's own point, which says nothing
    /// about which door is the driver's.
    static func farStiege(_ stop: Stop, entrance: CLLocationCoordinate2D) -> Bool {
        guard stop.precision == nil,
              AddressText.housenumberWithSub(AddressText.normalize(stop.strasse ?? "")) != nil
        else { return false }
        let stiege = CLLocation(latitude: stop.lat, longitude: stop.lon)
        let door = CLLocation(latitude: entrance.latitude, longitude: entrance.longitude)
        return stiege.distance(from: door) > stiegeDistance
    }

    static func destination(for stop: Stop) -> Destination {
        let plausible = Coordinates.isPlausible(
            lat: stop.lat, lon: stop.lon, forPlz: stop.plz ?? "")
        if stop.pinned, plausible { return .point(lat: stop.lat, lon: stop.lon) }
        if let e = stop.entrance {
            if plausible, farStiege(stop, entrance: e) {
                return .point(lat: stop.lat, lon: stop.lon)
            }
            return .point(lat: e.latitude, lon: e.longitude)
        }
        let address = stop.navigationAddress
        if !address.isEmpty { return .address(address) }
        return plausible ? .point(lat: stop.lat, lon: stop.lon) : .none
    }
}
