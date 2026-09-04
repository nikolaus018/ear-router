import Foundation
import SwiftData
import CoreLocation

/// Where a stop sits in the shape of a tour. Every route gets the same three
/// fixed points, but not every tour actually drives them — see `excluded`.
enum StopKind: String, Codable, Sendable, CaseIterable {
    /// The depot the van starts at (Petritschgasse 24).
    case start
    /// The warehouse the meals are loaded at (Oberlaaer Straße 298).
    case via
    /// Where the tour finishes.
    case end
    /// An actual delivery.
    case customer

    var isFixed: Bool { self != .customer }
}

/// How much the stored coordinates can be trusted.
///
/// `nil` on a `Stop` means an exact match, or that a human placed the pin.
/// `street`/`district` mean geocoding only found an approximate fallback —
/// surfaced in the UI so a driver knows to double check before setting off,
/// instead of an approximation silently pretending to be precise.
enum Precision: String, Codable, Sendable {
    case exact
    case street
    case district
}

@Model
final class Stop {
    /// Stable across exports and re-imports, unlike SwiftData's own
    /// `PersistentIdentifier`, which is not meaningful outside this store.
    var id: UUID = UUID()

    /// Stored raw for the same reason as `Route.statusRaw`.
    var kindRaw: String = StopKind.customer.rawValue
    var kind: StopKind {
        get { StopKind(rawValue: kindRaw) ?? .customer }
        set { kindRaw = newValue.rawValue }
    }

    var kunde: String?
    var strasse: String?
    var plz: String?
    var paket: String?
    var notiz: String?

    var lat: Double = 0
    var lon: Double = 0

    var orderIndex: Int = 0
    var delivered: Bool = false

    /// Distance and time from this stop to the next one in driving order.
    /// `nil` on a stop that isn't driven at all, and on the last one.
    var nextLegKm: Double?
    var nextLegMin: Double?

    var createdAt: Date = Date()

    /// Only ever `true` on a fixed stop. An excluded stop stays on the route
    /// (still shown, greyed, switchable back on) but is left out of the OSRM
    /// optimization entirely and carries no leg distance — a shift that
    /// starts straight from the warehouse, or ends somewhere other than the
    /// depot, would otherwise be planned around two legs it never drives.
    var excluded: Bool = false

    /// `true` when the driver placed this pin by hand. A hand-placed pin
    /// outranks anything a geocoder has to say about the address, so a
    /// re-check of the route's addresses leaves it alone: the driver stood in
    /// front of the building and told us where it is.
    var pinned: Bool = false

    var precisionRaw: String?
    var precision: Precision? {
        get { precisionRaw.flatMap(Precision.init(rawValue:)) }
        set { precisionRaw = newValue?.rawValue }
    }

    var route: Route?

    init(
        kind: StopKind,
        kunde: String? = nil,
        strasse: String? = nil,
        plz: String? = nil,
        paket: String? = nil,
        notiz: String? = nil,
        lat: Double,
        lon: Double,
        orderIndex: Int = 0,
        precision: Precision? = nil,
        pinned: Bool = false,
        excluded: Bool = false
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.kunde = kunde
        self.strasse = strasse
        self.plz = plz
        self.paket = paket
        self.notiz = notiz
        self.lat = lat
        self.lon = lon
        self.orderIndex = orderIndex
        self.delivered = false
        self.createdAt = Date()
        self.excluded = excluded
        self.pinned = pinned
        self.precisionRaw = precision?.rawValue
    }
}

extension Stop {
    /// Falls back to the geometric centre of Vienna for a row whose stored
    /// coordinates are unusable, so one bad value can never take out the map
    /// for the whole route.
    var coordinate: CLLocationCoordinate2D {
        guard lat.isFinite, lon.isFinite else {
            return CLLocationCoordinate2D(
                latitude: Coordinates.viennaCenter.lat,
                longitude: Coordinates.viennaCenter.lon)
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// "Straße, PLZ Wien" — the form handed to a maps app for navigation.
    var fullAddress: String {
        let street = strasse?.trimmed ?? ""
        guard let plz, !plz.isEmpty else { return street }
        return street.isEmpty ? "\(plz) Wien" : "\(street), \(plz) Wien"
    }

    /// "Straße, PLZ" — the address as the stop list shows it.
    ///
    /// The city is dropped on purpose. Every stop on every tour is in Vienna,
    /// so "Wien" carries no information here, and the six characters it costs
    /// are exactly what pushed an ordinary address onto a second line beside
    /// the row's two buttons. `fullAddress` keeps it, because a navigation app
    /// handed a bare street and postcode is a navigation app guessing.
    var listAddress: String {
        let street = strasse?.trimmed ?? ""
        guard let plz, !plz.isEmpty else { return street }
        return street.isEmpty ? plz : "\(street), \(plz)"
    }

    /// The label shown in the stop list for a fixed point.
    var fixedTitle: String {
        switch kind {
        case .start: "Start"
        case .via: "Lager"
        case .end: "Ziel"
        case .customer: kunde ?? "Stopp"
        }
    }

    /// A plain, `Sendable` snapshot of everything route planning needs. The
    /// optimizer works on these rather than on the model objects, so no
    /// SwiftData context is ever held across a network call.
    var planningSnapshot: StopCoord {
        StopCoord(id: id, lat: lat, lon: lon)
    }
}

/// One point in the planning problem — id plus position, nothing else.
struct StopCoord: Sendable, Hashable {
    let id: UUID
    let lat: Double
    let lon: Double
}

extension UUID {
    /// A stable total order over ids, compared byte by byte.
    ///
    /// `uuidString` would be the obvious way to write this, and it is what the
    /// map's change keys used to do — but it allocates a fresh 36-character
    /// `String` for *every* comparison. Sorting a hundred stops is ~700
    /// comparisons, and those keys are rebuilt on every camera frame while the
    /// driver pans the map. This compares the 16 bytes directly and allocates
    /// nothing.
    static func idOrderedBefore(_ a: UUID, _ b: UUID) -> Bool {
        let x = a.uuid, y = b.uuid
        if x.0 != y.0 { return x.0 < y.0 }
        if x.1 != y.1 { return x.1 < y.1 }
        if x.2 != y.2 { return x.2 < y.2 }
        if x.3 != y.3 { return x.3 < y.3 }
        if x.4 != y.4 { return x.4 < y.4 }
        if x.5 != y.5 { return x.5 < y.5 }
        if x.6 != y.6 { return x.6 < y.6 }
        if x.7 != y.7 { return x.7 < y.7 }
        if x.8 != y.8 { return x.8 < y.8 }
        if x.9 != y.9 { return x.9 < y.9 }
        if x.10 != y.10 { return x.10 < y.10 }
        if x.11 != y.11 { return x.11 < y.11 }
        if x.12 != y.12 { return x.12 < y.12 }
        if x.13 != y.13 { return x.13 < y.13 }
        if x.14 != y.14 { return x.14 < y.14 }
        return x.15 < y.15
    }
}
