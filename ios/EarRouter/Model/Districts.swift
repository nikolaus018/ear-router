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
    /// The 23 real Vienna districts — the quick picks in the editor, the
    /// names in an error message, and the only postcodes the city's own
    /// address register is asked about. No longer the whole of what address
    /// validation accepts: see `Postcodes`.
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

/// Which postal codes this app will accept, of which Vienna's 23 are a
/// special case rather than the whole set.
///
/// It used to be the whole set. A stop was rejected outright unless its
/// postcode was one of the 23, and a coordinate unless it landed in a box
/// drawn around the city — which meant an address in Gerasdorf, Schwechat or
/// Klosterneuburg could not be typed in at all, and the driver's answer was to
/// leave it off the tour and remember it. Meals on Wheels does not stop at the
/// Stadtgrenze.
///
/// So validity is now "a real Austrian postcode", and Vienna keeps only the
/// two things that are genuinely Viennese: the city's own address register,
/// which knows nothing outside the city and is not asked about anything
/// outside it, and the district names.
enum Postcodes {
    /// Four digits, 1000–9999.
    ///
    /// As much as can honestly be checked here. Austria has no postcode
    /// outside that range, and no list of the ~2000 real ones ships with the
    /// app — the geocoder is what actually decides whether 3423 exists, and it
    /// says so with a pin rather than with a rejected form.
    static func isValid(_ plz: String) -> Bool {
        plz.count == 4 && plz.allSatisfy(\.isNumber) && !plz.hasPrefix("0")
    }

    static func isVienna(_ plz: String) -> Bool { Districts.byPlz[plz] != nil }

    /// "1100 — 10. Favoriten" in Vienna, and the bare postcode everywhere
    /// else: naming the place would mean shipping a gazetteer to say
    /// "Gerasdorf bei Wien", and a postcode the driver just typed needs no
    /// caption to be recognised.
    static func label(for plz: String) -> String {
        Districts.byPlz[plz].map { "\(plz) — \($0.label)" } ?? plz
    }

    /// What a geocoding query is anchored to.
    ///
    /// Every lookup used to end in "Wien, Österreich" whatever postcode it
    /// carried, which is how "Kirchenplatz 3, 2201 Österreich" became a
    /// confident pin in the 2nd district: Nominatim is a fuzzy free-text
    /// search and "Wien" is a strong enough token to carry a query on its own.
    static func placeSuffix(for plz: String) -> String {
        isVienna(plz) ? "\(plz) Wien, Österreich" : "\(plz), Österreich"
    }
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

    /// A box around Austria, with room to spare on every border. What it is
    /// for is rejecting input that is wrong rather than distant: a swapped
    /// lat/lon, `0,0`, a fat-fingered extra digit, a hit that landed in
    /// Portugal — before any of it is stored or handed to OSRM.
    ///
    /// It used to be a box around Vienna, doing two jobs at once: this one,
    /// and standing in for "this app only serves Vienna". Now that a stop may
    /// legitimately be in Lower Austria or Burgenland, the second job belongs
    /// to `viennaLatRange` below, which the geocoder still applies to the
    /// addresses that claim a Vienna postcode.
    static let latRange = 46.2...49.2
    static let lonRange = 9.3...17.4

    static func isPlausible(lat: Double, lon: Double) -> Bool {
        lat.isFinite && lon.isFinite
            && latRange.contains(lat) && lonRange.contains(lon)
    }

    /// The old box, still doing its old job for the addresses it applies to.
    ///
    /// A Viennese street name that also exists in Graz or Linz comes back from
    /// Nominatim as a confident top hit hundreds of kilometres away, and the
    /// only thing that ever caught it was the postcode's own geography. That
    /// check is worth keeping exactly where it is still true: an address filed
    /// under 1210 is in Vienna or it is a mistake.
    static let viennaLatRange = 47.7...48.6
    static let viennaLonRange = 15.8...16.8

    static func isInVienna(lat: Double, lon: Double) -> Bool {
        lat.isFinite && lon.isFinite
            && viennaLatRange.contains(lat) && viennaLonRange.contains(lon)
    }

    /// The sanity check that fits the postcode: tight where the postcode says
    /// Vienna, country-wide where it says anywhere else.
    static func isPlausible(lat: Double, lon: Double, forPlz plz: String) -> Bool {
        Postcodes.isVienna(plz)
            ? isInVienna(lat: lat, lon: lon)
            : isPlausible(lat: lat, lon: lon)
    }
}
