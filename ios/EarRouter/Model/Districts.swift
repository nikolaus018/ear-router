import Foundation

/// A Vienna district: its number, postal code, name and centre.
struct District: Sendable, Hashable, Identifiable {
    let bezirk: Int
    let plz: String
    let name: String
    let lat: Double
    let lon: Double

    var id: String { plz }
    /// "10. Favoriten" — how the picker lists it.
    var label: String { "\(bezirk). \(name)" }
}

enum Districts {
    /// The 23 real Vienna districts. This exact set is also what address
    /// validation accepts, so the picker can never offer something the app
    /// would then refuse.
    static let all: [District] = [
        District(bezirk: 1, plz: "1010", name: "Innere Stadt", lat: 48.2082, lon: 16.3738),
        District(bezirk: 2, plz: "1020", name: "Leopoldstadt", lat: 48.2170, lon: 16.3919),
        District(bezirk: 3, plz: "1030", name: "Landstraße", lat: 48.1990, lon: 16.3939),
        District(bezirk: 4, plz: "1040", name: "Wieden", lat: 48.1928, lon: 16.3695),
        District(bezirk: 5, plz: "1050", name: "Margareten", lat: 48.1897, lon: 16.3567),
        District(bezirk: 6, plz: "1060", name: "Mariahilf", lat: 48.1975, lon: 16.3520),
        District(bezirk: 7, plz: "1070", name: "Neubau", lat: 48.2037, lon: 16.3480),
        District(bezirk: 8, plz: "1080", name: "Josefstadt", lat: 48.2114, lon: 16.3477),
        District(bezirk: 9, plz: "1090", name: "Alsergrund", lat: 48.2255, lon: 16.3560),
        District(bezirk: 10, plz: "1100", name: "Favoriten", lat: 48.1660, lon: 16.3780),
        District(bezirk: 11, plz: "1110", name: "Simmering", lat: 48.1660, lon: 16.4390),
        District(bezirk: 12, plz: "1120", name: "Meidling", lat: 48.1780, lon: 16.3350),
        District(bezirk: 13, plz: "1130", name: "Hietzing", lat: 48.1830, lon: 16.2870),
        District(bezirk: 14, plz: "1140", name: "Penzing", lat: 48.2000, lon: 16.2800),
        District(bezirk: 15, plz: "1150", name: "Rudolfsheim-Fünfhaus", lat: 48.1950, lon: 16.3350),
        District(bezirk: 16, plz: "1160", name: "Ottakring", lat: 48.2140, lon: 16.3120),
        District(bezirk: 17, plz: "1170", name: "Hernals", lat: 48.2330, lon: 16.3080),
        District(bezirk: 18, plz: "1180", name: "Währing", lat: 48.2350, lon: 16.3350),
        District(bezirk: 19, plz: "1190", name: "Döbling", lat: 48.2470, lon: 16.3450),
        District(bezirk: 20, plz: "1200", name: "Brigittenau", lat: 48.2340, lon: 16.3730),
        District(bezirk: 21, plz: "1210", name: "Floridsdorf", lat: 48.2540, lon: 16.4000),
        District(bezirk: 22, plz: "1220", name: "Donaustadt", lat: 48.2280, lon: 16.4700),
        District(bezirk: 23, plz: "1230", name: "Liesing", lat: 48.1330, lon: 16.2980),
    ]

    static let byPlz: [String: District] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.plz, $0) })

    static func isValid(_ plz: String) -> Bool { byPlz[plz] != nil }

    static func name(for plz: String) -> String? { byPlz[plz]?.label }
}

enum Coordinates {
    /// The two fixed route points (Petritschgasse 24 / Oberlaaer Straße 298),
    /// looked up once ahead of time. Creating a route never needs to resolve
    /// these at runtime.
    static let start = (lat: 48.2788118, lon: 16.4356537)
    static let via = (lat: 48.1499425, lon: 16.3587494)

    static let startAddress = "Petritschgasse 24"
    static let startPlz = "1210"
    static let viaAddress = "Oberlaaer Straße 298"
    static let viaPlz = "1100"

    /// Last-resort position for a stop whose stored coordinates are unusable.
    static let viennaCenter = (lat: 48.2082, lon: 16.3738)

    /// A generous bounding box around Vienna and its surroundings — well
    /// outside the city limits in every direction. Just enough to reject
    /// obviously-wrong input (a swapped lat/lon, `0,0`, a fat-fingered extra
    /// digit, a hit that landed in Graz) before it is stored or handed to OSRM.
    static let latRange = 47.7...48.6
    static let lonRange = 15.8...16.8

    static func isPlausible(lat: Double, lon: Double) -> Bool {
        lat.isFinite && lon.isFinite
            && latRange.contains(lat) && lonRange.contains(lon)
    }
}
