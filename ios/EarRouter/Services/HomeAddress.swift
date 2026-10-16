import Foundation

/// Where the driver lives — the one place a "Pause zu Hause" drives to.
///
/// Stored on the phone in `UserDefaults`, looked up once when it is saved:
/// switching the pause on in the middle of a tour must not wait on a geocoder,
/// and a stretch of road with no signal is exactly where that switch gets
/// flipped.
struct HomeAddress: Equatable, Sendable {
    var strasse: String
    var plz: String
    var lat: Double
    var lon: Double

    enum Keys {
        static let strasse = "home.strasse"
        static let plz = "home.plz"
        static let lat = "home.lat"
        static let lon = "home.lon"
    }

    /// `nil` until one has been saved — or when what is stored is not a
    /// usable position, which would otherwise go to OSRM as a point in the sea.
    static func load(from defaults: UserDefaults = .standard) -> HomeAddress? {
        guard let strasse = defaults.string(forKey: Keys.strasse)?.trimmed.nilIfEmpty,
              let plz = defaults.string(forKey: Keys.plz),
              let lat = defaults.object(forKey: Keys.lat) as? Double,
              let lon = defaults.object(forKey: Keys.lon) as? Double,
              Coordinates.isPlausible(lat: lat, lon: lon)
        else { return nil }
        return HomeAddress(strasse: strasse, plz: plz, lat: lat, lon: lon)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(strasse, forKey: Keys.strasse)
        defaults.set(plz, forKey: Keys.plz)
        defaults.set(lat, forKey: Keys.lat)
        defaults.set(lon, forKey: Keys.lon)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        for key in [Keys.strasse, Keys.plz, Keys.lat, Keys.lon] {
            defaults.removeObject(forKey: key)
        }
    }

    /// The address as one line, the way a stop row shows it.
    var line: String { "\(strasse), \(plz)" }
}
