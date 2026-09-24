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

/// What actually happened at a door.
///
/// A tour used to record one bit per stop — delivered, or not yet — and that
/// bit cannot tell "I have not got there" from "I rang for two minutes and
/// nobody came". On this round those are not variations of the same fact. The
/// second one is the reason somebody phones a daughter in Graz, and it was
/// being stored as the absence of a tick.
///
/// Four outcomes, and the line that matters runs between `handedOver` and the
/// rest: the meal is off the van, or it came back. A driver reads the tour as
/// "done / not done" and the office reads it as "who did not get their food",
/// and both have to come out of the same stored answer.
enum DeliveryOutcome: String, Codable, Sendable, CaseIterable {
    /// Into the customer's own hands.
    case delivered
    /// Left with a neighbour, a Rezeption, a Pflegedienst — somebody took it,
    /// and it was not the person whose name is on the row.
    case neighbour
    /// Nobody answered. The meal is still in the van.
    case notHome
    /// Nothing to deliver: abbestellt, im Spital, verstorben. Not a failure and
    /// not a delivery — a door that was never owed a meal today.
    case cancelled

    /// Whether the meal left the van. This is what `Stop.delivered` has always
    /// meant and still means, which is why a neighbour counts and a locked door
    /// does not.
    var handedOver: Bool {
        switch self {
        case .delivered, .neighbour: true
        case .notHome, .cancelled: false
        }
    }

    /// Whether anybody needs to hear about this before tomorrow. Exactly one
    /// outcome does: a meal that came back because nobody opened the door.
    var needsFollowUp: Bool { self == .notHome }

    var label: String {
        switch self {
        case .delivered: "Geliefert"
        case .neighbour: "Bei Nachbarn abgegeben"
        case .notHome: "Nicht angetroffen"
        case .cancelled: "Abbestellt"
        }
    }

    /// The short form, for a row in a list that is already narrow.
    var shortLabel: String {
        switch self {
        case .delivered: "geliefert"
        case .neighbour: "bei Nachbarn"
        case .notHome: "nicht angetroffen"
        case .cancelled: "abbestellt"
        }
    }

    var symbol: String {
        switch self {
        case .delivered: "checkmark.circle.fill"
        case .neighbour: "person.fill.checkmark"
        case .notHome: "bell.slash.fill"
        case .cancelled: "minus.circle.fill"
        }
    }

    /// The three the driver picks from after the plain tick has not applied.
    /// `delivered` is not among them — that one is the big button.
    static var exceptions: [DeliveryOutcome] { [.neighbour, .notHome, .cancelled] }
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
    /// How many physical parcels this delivery is — the Zusteller-Portal's
    /// own bundle count, one per `delivery_bundles` entry. `nil` on every
    /// stop not sourced from the portal, and on a portal stop imported
    /// before this existed.
    ///
    /// `paket` sums what is *inside* every parcel combined, which is exactly
    /// what a VM round wants and exactly wrong for a TK one, where a
    /// household's parcels are near enough unique and carry its name on the
    /// label — see `LadelisteMode` and `Stop.displayPaket`. This is the count
    /// the TK display shows instead.
    var paketCount: Int?
    var notiz: String?
    /// The customer's own number, from the Zusteller-Portal's `customer.phone`
    /// or typed in by hand — distinct from a number merely *mentioned* in
    /// `notiz`, which `PhoneNumbers.find` still reads separately. `nil` on
    /// every stop this app already had before this field existed, and on any
    /// import that carries none.
    var telefon: String?

    var lat: Double = 0
    var lon: Double = 0

    var orderIndex: Int = 0

    /// Whether the meal left the van. Kept exactly as it was — every count, the
    /// map, the backup and the strikethrough on the row all read it — and now
    /// written only through `outcome`, which is the fuller answer it is a
    /// summary of.
    var delivered: Bool = false

    /// What happened at the door, when it was anything other than "not yet".
    /// `nil` is an open stop.
    ///
    /// Deliberately alongside `delivered` rather than replacing it, and the
    /// redundancy is the point. Every row written before this field existed
    /// carries a `delivered` bit and no outcome; read through `outcome` below,
    /// such a row answers `.delivered` on its own, which is both true and
    /// exactly what it always meant. That is what makes this a lightweight
    /// migration instead of a custom one that has to rewrite every stop of
    /// every tour on the phone — on launch, in a van, at seven in the morning.
    var outcomeRaw: String?

    /// When the driver said what happened here. `nil` on an open stop and on
    /// every stop settled before this field existed.
    ///
    /// The one stored fact behind the arrival estimate, the day's report and
    /// "wann war ich gestern bei Frau Gruber" — three questions that had no
    /// answer at all for the sake of one `Date`.
    var settledAt: Date?

    /// No longer used. "Zuerst anfahren" is gone and nothing reads this; the
    /// column stays so the store needs no migration, and backups keep the
    /// field so older files still read.
    var prioritaet: Bool = false

    /// Distance and time from this stop to the next one in driving order.
    /// `nil` on a stop that isn't driven at all, and on the last one.
    var nextLegKm: Double?
    var nextLegMin: Double?

    var createdAt: Date = Date()

    /// Only ever `true` on a fixed stop. An excluded stop stays on the route
    /// (still shown, greyed, switchable back on) but is left out of the OSRM
    /// optimization entirely and carries no leg distance (but for a Start's
    /// drive from where the driver is — see `legIsDriven`) — a shift that
    /// starts straight from the warehouse, or ends somewhere other than the
    /// depot, would otherwise be planned around two legs it never drives.
    var excluded: Bool = false

    /// `true` when the driver placed this pin by hand. A hand-placed pin
    /// outranks anything a geocoder has to say about the address, so a
    /// re-check of the route's addresses leaves it alone: the driver stood in
    /// front of the building and told us where it is.
    var pinned: Bool = false

    /// Where the register puts this address's house number on the street: the
    /// entrance, as `ogdwien:ZUGANGSADROGD` has it. What a navigation app is
    /// sent — see `NavigationHandoff`. `lat`/`lon` stay the building or
    /// Stiege, which is what the map and the route planning want.
    ///
    /// `nil` outside Vienna, for an address the register has no entrance for,
    /// and on every stop imported before this existed.
    var entranceLat: Double?
    var entranceLon: Double?

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
        paketCount: Int? = nil,
        notiz: String? = nil,
        telefon: String? = nil,
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
        self.paketCount = paketCount
        self.notiz = notiz
        self.telefon = telefon
        self.lat = lat
        self.lon = lon
        self.orderIndex = orderIndex
        self.delivered = false
        self.outcomeRaw = nil
        self.settledAt = nil
        self.prioritaet = false
        self.createdAt = Date()
        self.excluded = excluded
        self.pinned = pinned
        self.precisionRaw = precision?.rawValue
    }
}

extension Stop {
    /// What happened at this door, or `nil` while it is still open.
    ///
    /// Read-only on purpose. Recording an outcome also stamps the time and
    /// restates `delivered`, and three stored facts that must agree are not
    /// something a property setter should be quietly doing on the way past —
    /// `record(_:at:)` is the one way in, and `RouteStore` is the one caller.
    ///
    /// The fallback in the second line is what lets this ship as a lightweight
    /// migration: a stop ticked off before outcomes existed has no `outcomeRaw`
    /// and a `delivered` bit, and "delivered" is precisely what that bit meant.
    var outcome: DeliveryOutcome? {
        if let raw = outcomeRaw, let known = DeliveryOutcome(rawValue: raw) { return known }
        return delivered ? .delivered : nil
    }

    /// Whether the driver has said anything about this door yet.
    ///
    /// The distinction the tour list is actually sorted by, and not the same as
    /// `delivered`: a customer who was not home is settled — the van has been
    /// there and is not going back on the way past — while the meal never left
    /// it. A stop that is settled drops out of "noch offen" and out of the
    /// next-stop card, and stays visibly undelivered on its row.
    var isSettled: Bool { outcome != nil }

    /// Only ever on a customer. The fixed points are not doors.
    var isOpenDelivery: Bool { kind == .customer && !isSettled }

    /// Lager and Ziel, on a tour that drives them. They are ticked off like a
    /// door — loading at the warehouse and getting back are two stops of the
    /// shift as much as any customer — but they are not deliveries: no meal,
    /// no number, no "nicht angetroffen", and no place in the day's report.
    ///
    /// Not Start. The driver is standing in it when the tour begins.
    var isCheckpoint: Bool { (kind == .via || kind == .end) && !excluded }

    /// Start and Lager can be switched out of a tour. Ziel cannot: without it
    /// the tour ends wherever the optimizer finds cheapest, so its address is
    /// changed instead. A Ziel switched off before that rule can still be
    /// switched back on.
    var canToggleExcluded: Bool {
        switch kind {
        case .start, .via: true
        case .end: excluded
        case .customer: false
        }
    }

    /// Whether the leg stored on this row is part of the day's driving.
    ///
    /// Every stop that is not switched off — and a switched-off Start, whose
    /// leg can only be the drive from where the driver is to the first stop:
    /// see `RouteOptimizer.Nodes.currentLocation`. Left out, every arrival
    /// time before the first door was early by that drive, and "Noch … km"
    /// short by it. Any other switched-off stop's leg is one the van never
    /// drives.
    var legIsDriven: Bool { !excluded || kind == .start }

    /// A stop the tour counts: every customer, and the checkpoints.
    var countsAsStop: Bool { kind == .customer || isCheckpoint }

    /// A stop still to be ticked off, delivery or checkpoint.
    var isOpenStop: Bool { countsAsStop && !isSettled }

    /// A customer whose meal goes in the van: every one of them except those
    /// marked abbestellt. That tick is usually made in the yard, when the
    /// office rings, before a single box is loaded — and the Ladeliste went on
    /// counting the meal, and "Tour vorbereiten" on asking for it to be loaded.
    var isOwedAMeal: Bool { kind == .customer && outcome != .cancelled }

    /// A door answered for in a way that says the van has loaded: any outcome
    /// but abbestellt, which is ticked in the yard as often as not. What ticks
    /// an open Lager — see `RouteStore.record`.
    var passesLager: Bool { kind == .customer && isSettled && outcome != .cancelled }

    /// Records what happened here, or re-opens the stop with `nil`.
    ///
    /// The three facts are written together and only here, so they cannot drift:
    /// the outcome itself, the `delivered` summary every count in the app still
    /// reads, and the time it was said.
    func record(_ outcome: DeliveryOutcome?, at date: Date = Date()) {
        outcomeRaw = outcome?.rawValue
        delivered = outcome?.handedOver ?? false
        settledAt = outcome == nil ? nil : date
    }

    /// Falls back to the geometric centre of Vienna for a row whose stored
    /// coordinates are unusable, so one bad value can never take out the map
    /// for the whole route.
    ///
    /// The whole plausibility box, not just `isFinite`. Every writer of these
    /// two numbers already checks the box — but the default for both is `0`,
    /// which is finite, off the west coast of Africa, and exactly what a row
    /// arriving from a future schema migration would carry. That row used to
    /// put a marker in the Gulf of Guinea, drag the map's whole-route framing
    /// out to fit it, and hand the same point to the navigation app.
    ///
    /// Measured against the box the stop's own postcode implies, which for a
    /// Vienna postcode is still the tight one. A stop filed under 1210 whose
    /// point is in Graz is a bad row however wide the app's reach has become,
    /// and now that the general box covers all of Austria this is the only
    /// place left that says so.
    var coordinate: CLLocationCoordinate2D {
        guard Coordinates.isPlausible(lat: lat, lon: lon, forPlz: plz ?? "") else {
            return CLLocationCoordinate2D(
                latitude: Coordinates.viennaCenter.lat,
                longitude: Coordinates.viennaCenter.lon)
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// "Gentzgasse 129, 1180 Wien, Österreich" — what a navigation app is
    /// handed when it has no pin or entrance to go to: see `NavigationHandoff`.
    ///
    /// Trimmed to street and housenumber. Stiege, Tür and Parzelle are things
    /// the city's register knows and no navigation app does, so
    /// "Gentzgasse 129/1/2/23" sent whole is a search that either fails or
    /// quietly guesses. The Stiege stays on the row and on Jetzt, which is
    /// where the driver reads it — at the door, not at the wheel. `normalize`
    /// first, so a typed "Hauptstr. 5" arrives as "Hauptstraße 5".
    ///
    /// The place is `Postcodes.placeSuffix`, the anchor the geocoder already
    /// uses: "Wien" only where the postcode says Vienna — appended to a
    /// Gerasdorf street it sent the maps app looking in the wrong municipality
    /// — and the country on both, so a search cannot wander off to a 2201 in
    /// Germany.
    var navigationAddress: String {
        let street = AddressText.simplifyHousenumber(AddressText.normalize(strasse ?? ""))
        guard let plz = plz?.trimmed, !plz.isEmpty else { return street }
        let place = Postcodes.placeSuffix(for: plz)
        return street.isEmpty ? place : "\(street), \(place)"
    }

    /// The house number's entrance, when it is known and usable. Checked
    /// against the postcode's box for the same reason `coordinate` is.
    var entrance: CLLocationCoordinate2D? {
        guard let entranceLat, let entranceLon,
              Coordinates.isPlausible(lat: entranceLat, lon: entranceLon, forPlz: plz ?? "")
        else { return nil }
        return CLLocationCoordinate2D(latitude: entranceLat, longitude: entranceLon)
    }

    func setEntrance(_ point: (lat: Double, lon: Double)?) {
        entranceLat = point?.lat
        entranceLon = point?.lon
    }

    /// "Straße, PLZ" — the address as the stop list shows it.
    ///
    /// The city is dropped on purpose. Nearly every stop on every tour is in
    /// Vienna, so "Wien" carries no information here, and the six characters
    /// it costs are exactly what pushed an ordinary address onto a second line
    /// beside the row's two buttons. The postcode is what tells the handful
    /// that are not apart — 2201 reads as "not in town" to anybody who drives
    /// this round. `navigationAddress` keeps the city, because a navigation
    /// app handed a bare street and postcode is a navigation app guessing.
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
    ///
    /// Through `coordinate`, not off the stored pair directly. Every other
    /// consumer of a stop's position already defends against an unusable one —
    /// the map frames around the fallback, the navigation handoff refuses to
    /// send it as a point — and planning was the one that did not. A row
    /// carrying the default `0, 0` went to OSRM as a point in the Gulf of
    /// Guinea, which does not degrade to a slightly wrong route: OSRM answers
    /// `NoSegment` for the whole request, so one unusable row left the entire
    /// tour unroutable, told the driver to go and check their pins, and offered
    /// a retry that could never succeed.
    var planningSnapshot: StopCoord {
        let c = coordinate
        return StopCoord(id: id, lat: c.latitude, lon: c.longitude)
    }

    /// Display order, with the id breaking ties.
    ///
    /// `orderIndex` is meant to be unique across a route and normally is — but
    /// "normally" is not an ordering. `sorted(by:)` makes no promise about
    /// equal elements, so two stops that ever did share an index could come
    /// back in either order, and a list that reshuffles its own rows between
    /// two draws of the same data is the kind of thing a driver stops trusting.
    static func displayBefore(_ a: Stop, _ b: Stop) -> Bool {
        a.orderIndex != b.orderIndex
            ? a.orderIndex < b.orderIndex
            : UUID.idOrderedBefore(a.id, b.id)
    }

    /// Creation order, with the id breaking ties.
    ///
    /// The tie is not hypothetical here. A `Date` around now holds about 240 ns
    /// of resolution, and `RouteStore.createRoute` builds Start, Lager and Ziel
    /// in three consecutive statements — comfortably inside that. The optimizer
    /// sorts by this twice, once to plan and once to check afterwards whether
    /// the route it planned is still the route on disk; two ties ordered
    /// differently by those two sorts would make a route that nothing had
    /// touched compare as changed, and leave it flagged "Route nicht aktuell"
    /// with a retry that can never clear it.
    static func createdBefore(_ a: Stop, _ b: Stop) -> Bool {
        a.createdAt != b.createdAt
            ? a.createdAt < b.createdAt
            : UUID.idOrderedBefore(a.id, b.id)
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
