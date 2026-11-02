import CoreLocation
import Foundation
import SwiftUI

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
        /// Guidance inside this app, on the same OSRM route the tour was
        /// planned with — see `GuidanceView`. Everywhere an outside app is
        /// still needed (a toilet, the car's automation) it hands over to
        /// Apple Maps, which is what the URLs below do for it.
        case inApp

        var id: String { rawValue }

        var label: String {
            switch self {
            case .apple: "Karten"
            case .waze: "Waze"
            case .google: "Google Maps"
            case .inApp: "In der App"
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
            case .apple, .inApp:
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
            case .apple, .inApp:
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

    /// Starts navigation to `stop`: in this app when that is the chosen
    /// provider and the stop has a point to drive to, otherwise by opening
    /// `url` — what `url(for:)` gave — in the maps app.
    @MainActor
    static func start(_ stop: Stop, url: URL, openURL: OpenURLAction) {
        if provider == .inApp, let point = guidancePoint(for: stop) {
            GuidanceCoordinator.shared.target = GuidanceTarget(
                title: [stop.kunde, stop.strasse].compactMap { $0 }.first { !$0.isEmpty } ?? "Stopp",
                lat: point.lat, lon: point.lon)
        } else {
            openURL(url)
        }
    }

    /// Where the in-app guidance drives to: the same pin, then entrance, then
    /// building point as the handoff, but always a point — an address alone
    /// is something only an outside app can look up.
    static func guidancePoint(for stop: Stop) -> (lat: Double, lon: Double)? {
        switch destination(for: stop) {
        case .point(let lat, let lon): return (lat, lon)
        case .address, .none:
            let ok = Coordinates.isPlausible(lat: stop.lat, lon: stop.lon, forPlz: stop.plz ?? "")
            return ok ? (stop.lat, stop.lon) : nil
        }
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
