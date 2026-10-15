import Foundation
import CoreLocation

/// A stop on the same portal tour that is not on this route — the other
/// driver's share of a tour that is split between two vans, for the map to show
/// so the split can be talked through with the map in front of both.
struct OtherStop: Identifiable, Equatable, Codable, Sendable {
    /// The portal's delivery id.
    let id: Int
    let name: String
    let address: String
    let plz: String
    let notiz: String?
    let telefon: String?
    /// `nil` where no address lookup could place it. Such a stop is kept in the
    /// list and left off the map, as `TourSplitSheet` does.
    let latitude: Double?
    let longitude: Double?
    /// Only on a stop that was one of mine and was handed over: what it carried,
    /// so taking it back does not lose its meals. The portal's list has none.
    var paket: String? = nil
    var paketCount: Int? = nil
    /// One of mine that was handed over, rather than typed in on that side.
    var handedOver: Bool? = nil

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Typed in by the driver — a Nachlieferung or anything else the portal's
    /// list does not have — rather than fetched from it.
    var isManual: Bool { id >= OtherStops.manualBase }
}

enum OtherStops {

    /// Where the ids of hand-added stops start, far above any portal delivery
    /// id, so the two can share one list without meeting.
    static let manualBase = 1_000_000_000

    /// What a route already has, in the form two lists are compared in — the
    /// same folding (`AddressText.matchKey`) re-import matching uses, so "Fam.
    /// Grüber" and "Fam Grueber" are one household here too.
    struct Mine: Equatable, Sendable {
        var names: Set<String> = []
        var addresses: Set<String> = []

        init(names: Set<String> = [], addresses: Set<String> = []) {
            self.names = names
            self.addresses = addresses
        }

        init(stops: [Stop]) {
            for s in stops where s.kind == .customer {
                let name = AddressText.matchKey(s.kunde ?? "")
                if !name.isEmpty { names.insert(name) }
                let address = Self.addressKey(s.strasse ?? "", s.plz ?? "")
                if !address.isEmpty { addresses.insert(address) }
            }
        }

        static func addressKey(_ strasse: String, _ plz: String) -> String {
            let street = AddressText.matchKey(strasse)
            return street.isEmpty ? "" : "\(street)|\(plz.trimmed)"
        }
    }

    /// The deliveries on the tour that are not already this route's.
    ///
    /// Mine is "the same name, or the same door": a customer who has moved flat
    /// is still mine, and so is a second name at an address I am already
    /// driving to — `Mine`'s address key carries the Stiege and Tür, so that is
    /// the same household, not the same building. The portal leaves delivered
    /// doors out of its list, so by the afternoon the other driver's finished
    /// stops are gone from here; this is a picture of what is still to do.
    static func others(
        in deliveries: [GourmetPortal.Delivery], excluding mine: Mine
    ) -> [GourmetPortal.Delivery] {
        deliveries.filter { delivery in
            let (name, address) = GourmetPortal.summary(delivery)
            let nameKey = AddressText.matchKey(name)
            if !nameKey.isEmpty, mine.names.contains(nameKey) { return false }
            let addressKey = Mine.addressKey(address, delivery.deliveryAddress.zip ?? "")
            if !addressKey.isEmpty, mine.addresses.contains(addressKey) { return false }
            return true
        }
    }

    /// Fetches the tour's open deliveries for the link's day, takes away what
    /// the route already has, and places the rest through the geocoder (which
    /// serves the regular doors from its cache).
    static func load(
        link: PortalTourLink, mine: Mine, credentials: GourmetPortal.Credentials,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [OtherStop] {
        let tour = GourmetPortal.Tour(
            id: link.tourID, name: link.tourName, catalogueType: nil, weekday: nil, weekdays: [])
        let (_, deliveries) = try await GourmetPortal.matchingDeliveries(
            tour: tour, date: link.date, credentials: credentials, onProgress: onProgress)
        let rest = others(in: deliveries, excluding: mine)
        let placed = try await PortalPlacement.place(rest) { done, total in
            onProgress("Adresse \(done) von \(total) wird gesucht …")
        }
        let byID = Dictionary(rest.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return placed.map { stop in
            let entry = byID[stop.id].map(GourmetPortal.customerJSON(from:))
            return OtherStop(
                id: stop.id, name: stop.name, address: stop.address, plz: stop.plz,
                notiz: entry?.notiz?.trimmed.nilIfEmpty, telefon: entry?.telefon,
                latitude: stop.coordinate?.latitude, longitude: stop.coordinate?.longitude)
        }
    }

    /// An other-driver stop as a customer entry for this route, with only what
    /// it carries — a Paket only if it was handed over with one, since the
    /// portal's list has none and only its detail call does.
    static func plainEntry(for stop: OtherStop) -> CustomerJSON {
        clamped(CustomerJSON(
            kunde: stop.name, strasse: stop.address, plz: stop.plz, paket: stop.paket,
            notiz: stop.notiz, telefon: stop.telefon, paketCount: stop.paketCount))
    }

    /// An entry cut to the field limits the stop editor enforces, so a long
    /// phone line from the portal ("+436763095249 Schwester Frau Koch …") cannot
    /// refuse a hand-over over text nobody typed. The Paket limit is far past
    /// anything real, and a Notiz is cut rather than refused.
    static func clamped(_ entry: CustomerJSON) -> CustomerJSON {
        var e = entry
        e.kunde = String(e.kunde.trimmed.prefix(FieldLimits.kunde))
        e.strasse = String(e.strasse.trimmed.prefix(FieldLimits.strasse))
        e.notiz = e.notiz.map { String($0.prefix(FieldLimits.notiz)) }
        e.telefon = e.telefon.map { String($0.trimmed.prefix(FieldLimits.telefon)) }
        return e
    }

    /// The portal's stops without those a hand-over already put on the list by
    /// hand. A stop handed over is still on the portal's list as open, so
    /// fetching it again would show it twice — once from the portal, once from
    /// the hand-over.
    static func dropping(_ fetched: [OtherStop], alreadyHeld manual: [OtherStop]) -> [OtherStop] {
        let held = Mine(
            names: Set(manual.map { AddressText.matchKey($0.name) }.filter { !$0.isEmpty }),
            addresses: Set(manual.map { Mine.addressKey($0.address, $0.plz) }.filter { !$0.isEmpty }))
        return fetched.filter { stop in
            let name = AddressText.matchKey(stop.name)
            if !name.isEmpty, held.names.contains(name) { return false }
            let address = Mine.addressKey(stop.address, stop.plz)
            return address.isEmpty || !held.addresses.contains(address)
        }
    }

    /// The link for a route that was made before links were kept, or by a
    /// route of the same name made by hand: the portal tour that has the
    /// route's name and runs on the day it was made. Only when that is exactly
    /// one — a guess between two tours would show somebody else's stops as the
    /// other driver's.
    static func infer(
        for route: Route, credentials: GourmetPortal.Credentials
    ) async throws -> PortalTourLink? {
        let token = try await GourmetPortal.login(credentials)
        let tours = try await GourmetPortal.tours(token: token)
        let name = route.name.trimmed
        let hits = tours.filter { tour in
            guard GourmetPortal.runs(tour, on: route.createdAt) else { return false }
            let tourName = tour.name.trimmed
            // "VM 4 DO Vormittag – 10.09." is how a route is named when an
            // active one already had the plain name — see `suggestedRouteName`.
            return name == tourName || name.hasPrefix(tourName + " –")
        }
        guard hits.count == 1, let tour = hits.first else { return nil }
        return PortalTourLink(tourID: tour.id, tourName: tour.name, date: route.createdAt)
    }
}

/// Puts portal deliveries on the map: each address through the same geocoder a
/// tour uses, which serves the driver's regular doors straight from its cache
/// while the geocoder itself still spaces out any Nominatim fallback. An
/// address nobody can place is kept, without a pin, rather than dropped.
///
/// Shared by the tour split and the map's other-driver layer.
enum PortalPlacement {
    static func place(
        _ deliveries: [GourmetPortal.Delivery],
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [SplitStop] {
        let inputs = deliveries.map { delivery in
            let (name, address) = GourmetPortal.summary(delivery)
            return (
                id: delivery.id, name: name, address: address,
                plz: delivery.deliveryAddress.zip?.trimmed ?? "",
                door: GourmetPortal.doorLine(delivery))
        }
        var placed: [Int: CLLocationCoordinate2D] = [:]
        var exact: Set<Int> = []
        try await withThrowingTaskGroup(of: (Int, CLLocationCoordinate2D?, Bool).self) { group in
            var next = 0
            var done = 0
            func enqueue() {
                guard next < inputs.count else { return }
                let input = inputs[next]
                next += 1
                group.addTask {
                    do {
                        let hit = try await Geocoder.shared.geocode(
                            strasse: input.address, plz: input.plz)
                        return (
                            input.id, CLLocationCoordinate2D(latitude: hit.lat, longitude: hit.lon),
                            hit.precision == .exact)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (input.id, nil, false)
                    }
                }
            }
            for _ in 0..<4 { enqueue() }
            while let (id, coordinate, isExact) = try await group.next() {
                done += 1
                onProgress(done, inputs.count)
                if let coordinate { placed[id] = coordinate }
                if isExact { exact.insert(id) }
                enqueue()
            }
        }
        return inputs.map { input in
            SplitStop(
                id: input.id, name: input.name.isEmpty ? "Ohne Namen" : input.name,
                address: input.address, plz: input.plz, coordinate: placed[input.id],
                exactPoint: exact.contains(input.id), door: input.door)
        }
    }
}

extension PortalPlacement {
    /// A stop typed in on the split screen, put on the map the same way:
    /// left without a pin, rather than refused, where nobody can place it.
    static func place(typed entry: CustomerJSON, id: Int) async -> SplitStop {
        let (coordinate, exact) = await locate(strasse: entry.strasse, plz: entry.plz)
        return SplitStop(
            id: id, name: entry.kunde.trimmed, address: entry.strasse.trimmed, plz: entry.plz.trimmed,
            coordinate: coordinate, exactPoint: exact, typed: entry)
    }

    /// A portal stop at the address the driver corrected it to. Its Paket
    /// still comes from the portal; the address it is delivered to is this.
    static func place(_ stop: SplitStop, at strasse: String, plz: String) async -> SplitStop {
        let (coordinate, exact) = await locate(strasse: strasse, plz: plz)
        return SplitStop(
            id: stop.id, name: stop.name, address: strasse.trimmed, plz: plz.trimmed,
            coordinate: coordinate, exactPoint: exact, addressCorrected: true)
    }

    private static func locate(
        strasse: String, plz: String
    ) async -> (CLLocationCoordinate2D?, exact: Bool) {
        guard let hit = try? await Geocoder.shared.geocode(strasse: strasse, plz: plz) else {
            return (nil, false)
        }
        return (CLLocationCoordinate2D(latitude: hit.lat, longitude: hit.lon), hit.precision == .exact)
    }
}

/// Stops the driver added to the other driver's side by hand: deliveries the
/// portal's list does not carry, like a Nachlieferung that one of the two has
/// to make anyway. Kept per route, beside `PortalTourLink`, and let go of with
/// the route.
enum ManualOtherStops {
    private static func key(_ routeID: UUID) -> String { "portal.extra.\(routeID.uuidString)" }

    static func load(for routeID: UUID) -> [OtherStop] {
        guard let data = UserDefaults.standard.data(forKey: key(routeID)) else { return [] }
        return (try? JSONDecoder().decode([OtherStop].self, from: data)) ?? []
    }

    private static func save(_ stops: [OtherStop], for routeID: UUID) {
        if stops.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(routeID))
        } else if let data = try? JSONEncoder().encode(stops) {
            UserDefaults.standard.set(data, forKey: key(routeID))
        }
    }

    /// Appends one, with an id of its own.
    @discardableResult
    static func add(
        name: String, address: String, plz: String, latitude: Double?, longitude: Double?,
        notiz: String? = nil, telefon: String? = nil, paket: String? = nil,
        paketCount: Int? = nil, handedOver: Bool = false, to routeID: UUID
    ) -> OtherStop {
        var stops = load(for: routeID)
        let id = (stops.map(\.id).max() ?? OtherStops.manualBase - 1) + 1
        let stop = OtherStop(
            id: id, name: name.trimmed.isEmpty ? "Nachlieferung" : name.trimmed,
            address: address.trimmed, plz: plz.trimmed,
            notiz: notiz?.trimmed.nilIfEmpty, telefon: telefon?.trimmed.nilIfEmpty,
            latitude: latitude, longitude: longitude, paket: paket?.trimmed.nilIfEmpty,
            paketCount: paketCount, handedOver: handedOver ? true : nil)
        stops.append(stop)
        save(stops, for: routeID)
        return stop
    }

    static func remove(id: Int, from routeID: UUID) {
        save(load(for: routeID).filter { $0.id != id }, for: routeID)
    }

    // MARK: - Taking a portal stop off the other driver's side

    private static func hiddenKey(_ routeID: UUID) -> String { "portal.hidden.\(routeID.uuidString)" }

    /// The portal deliveries the driver took off the other driver's side: one
    /// that goes to the Lager, say, and is neither van's to deliver. Their ids,
    /// so the portal's list can be fetched again and still leave them out.
    static func hidden(for routeID: UUID) -> Set<Int> {
        Set(UserDefaults.standard.array(forKey: hiddenKey(routeID)) as? [Int] ?? [])
    }

    static func hide(id: Int, for routeID: UUID) {
        var ids = hidden(for: routeID)
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: hiddenKey(routeID))
    }

    static func unhideAll(for routeID: UUID) {
        UserDefaults.standard.removeObject(forKey: hiddenKey(routeID))
    }

    static func forget(_ routeID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(routeID))
        unhideAll(for: routeID)
    }
}
