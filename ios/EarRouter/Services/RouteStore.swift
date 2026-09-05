import Foundation
import SwiftData

/// One customer stop as it travels through the JSON bulk editor — the same
/// shape the old backend's `/api/routes/:id/json` accepted, so a list exported
/// from the web app pastes straight into this one.
struct CustomerJSON: Codable, Sendable, Hashable {
    var kunde: String
    var strasse: String
    var plz: String
    var paket: String?
    var notiz: String?

    init(kunde: String, strasse: String, plz: String, paket: String?, notiz: String?) {
        self.kunde = kunde
        self.strasse = strasse
        self.plz = plz
        self.paket = paket
        self.notiz = notiz
    }

    /// A missing required key is a *missing field on one entry*, not a
    /// malformed document.
    ///
    /// Decoded strictly — which is what the synthesised initializer does — one
    /// entry without a `plz` aborted the decode of the whole paste, and the
    /// driver got "Ungültiges JSON: erwarte eine Liste von Kundenstopps" naming
    /// nothing, for thirty stops of which twenty-nine were fine. That is the
    /// same failure `importJSON` already goes out of its way to avoid one layer
    /// further in, where every entry is validated and reported by name. Missing
    /// keys become empty strings here so they reach that check and are reported
    /// the same way. A payload that is genuinely not a list of stops still
    /// fails outright, because then there is no entry to name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kunde = try c.decodeIfPresent(String.self, forKey: .kunde) ?? ""
        strasse = try c.decodeIfPresent(String.self, forKey: .strasse) ?? ""
        plz = try c.decodeIfPresent(String.self, forKey: .plz) ?? ""
        paket = try c.decodeIfPresent(String.self, forKey: .paket)
        notiz = try c.decodeIfPresent(String.self, forKey: .notiz)
    }
}

/// What a bulk import did, and what it could not do.
struct ImportResult: Sendable {
    var inserted = 0
    var updated = 0
    var moved = 0
    var deleted = 0
    /// Entries rejected before any network call — a missing required field,
    /// an over-length value, a PLZ that is not a Vienna district.
    var validationFailures: [(label: String, reason: String)] = []
    /// Addresses no geocoder could place. Deliberately not fatal: everything
    /// else in the batch still saves rather than one bad address blocking all
    /// thirty.
    var geocodeFailures: [(kunde: String, strasse: String, plz: String)] = []
    /// Entries that resolved only approximately — the driver should double
    /// check these before setting off.
    var approximate: [(kunde: String, precision: Precision)] = []
    /// True when something in the paste failed, so no stop was removed this
    /// round — see the deletion step in `importJSON`.
    var deletionsSkipped = false

    var hasProblems: Bool {
        !validationFailures.isEmpty || !geocodeFailures.isEmpty || !approximate.isEmpty
    }
}

@MainActor
enum RouteStore {

    // MARK: - Routes

    /// A new route, pre-seeded with the three fixed points. Their coordinates
    /// are known ahead of time, so this needs no network at all — a route can
    /// always be created, even with no signal.
    @discardableResult
    static func createRoute(name: String, in context: ModelContext) throws -> Route {
        let route = Route(name: name.trimmed.isEmpty ? defaultRouteName() : name.trimmed)
        context.insert(route)

        let start = Stop(
            kind: .start, kunde: "Start", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz, lat: Coordinates.start.lat,
            lon: Coordinates.start.lon, orderIndex: 0)
        let via = Stop(
            kind: .via, kunde: "Lager", strasse: Coordinates.viaAddress,
            plz: Coordinates.viaPlz, lat: Coordinates.via.lat,
            lon: Coordinates.via.lon, orderIndex: 1)
        let end = Stop(
            kind: .end, kunde: "Ziel", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz, lat: Coordinates.start.lat,
            lon: Coordinates.start.lon, orderIndex: 2)

        for s in [start, via, end] {
            s.route = route
            context.insert(s)
        }
        try context.save()
        return route
    }

    /// Built once. This is read from a view body — it is the placeholder in the
    /// "Neue Tour" field — and a fresh `DateFormatter` per render is one of the
    /// more expensive things Foundation offers.
    private static let routeNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_AT")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    static func defaultRouteName() -> String {
        "Tour \(routeNameFormatter.string(from: Date()))"
    }

    static func delete(_ route: Route, in context: ModelContext) throws {
        let id = route.id
        context.delete(route)
        try context.save()
        // The packing checklist lives in `UserDefaults`, outside the store, so
        // the cascade delete does not reach it. Without this every deleted tour
        // leaves its ticks behind in the app's preferences for good.
        LadelisteState.forget(id)
    }

    /// Deletes by id rather than by object, because the caller is a list's
    /// swipe-to-delete: it has row offsets into a live `@Query`, and that array
    /// is refreshed by the save after the first deletion. Resolving every id up
    /// front is what keeps a two-row deletion from taking out a third tour.
    static func delete(ids: [UUID], in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let doomed = try context.fetch(FetchDescriptor<Route>())
            .filter { wanted.contains($0.id) }
        guard !doomed.isEmpty else { return }
        for route in doomed { context.delete(route) }
        try context.save()
        for id in wanted { LadelisteState.forget(id) }
    }

    static func rename(_ route: Route, to name: String, in context: ModelContext) throws {
        let trimmed = String(name.trimmed.prefix(FieldLimits.routeName))
        guard !trimmed.isEmpty else { return }
        route.name = trimmed
        try context.save()
    }

    static func toggleStatus(_ route: Route, in context: ModelContext) throws {
        if route.status == .active {
            route.status = .completed
            route.completedAt = Date()
        } else {
            route.status = .active
            route.completedAt = nil
        }
        try context.save()
    }

    static func resetDelivered(_ route: Route, in context: ModelContext) throws {
        for s in route.stops { s.delivered = false }
        if route.status == .completed {
            route.status = .active
            route.completedAt = nil
        }
        try context.save()
    }

    // MARK: - Stops

    /// Adds a customer stop, geocoding the address unless coordinates were
    /// supplied directly (the pin-drop path, which needs no network).
    @discardableResult
    static func addStop(
        to route: Route,
        kunde: String, strasse: String, plz: String,
        paket: String?, notiz: String?,
        coordinate: (lat: Double, lon: Double)? = nil,
        in context: ModelContext
    ) async throws -> Stop {
        try validateCustomerFields(
            kunde: kunde, strasse: strasse, paket: paket, notiz: notiz)
        guard Districts.isValid(plz) else {
            throw AppError.message("Kein gültiger Wiener Bezirk: \(plz)")
        }
        // `customerCount`, not `customerStops.count`: the answer is a number,
        // and going through the ordered list sorted the whole route to get it.
        guard route.customerCount < maxBulkStops else {
            throw AppError.message(
                "Diese Route hat schon \(maxBulkStops) Kundenstopps — das ist das Maximum "
                    + "für die Routenoptimierung.")
        }

        let lat: Double, lon: Double, precision: Precision?, pinned: Bool

        if let coordinate {
            guard Coordinates.isPlausible(lat: coordinate.lat, lon: coordinate.lon) else {
                throw AppError.message("Ungültige Koordinaten (außerhalb des erwarteten Bereichs).")
            }
            (lat, lon, precision, pinned) = (coordinate.lat, coordinate.lon, nil, true)
        } else {
            let hit = try await Geocoder.shared.geocode(strasse: strasse, plz: plz)
            (lat, lon, pinned) = (hit.lat, hit.lon, false)
            precision = hit.precision == .exact ? nil : hit.precision
        }

        let stop = Stop(
            kind: .customer, kunde: kunde.trimmed, strasse: strasse.trimmed, plz: plz,
            paket: paket?.trimmed.nilIfEmpty, notiz: notiz?.trimmed.nilIfEmpty,
            lat: lat, lon: lon,
            // Appended at the end until the optimizer places it properly.
            orderIndex: nextOrderIndex(in: route),
            precision: precision, pinned: pinned)
        stop.route = route
        context.insert(stop)
        route.needsOptimize = true
        try context.save()

        await RouteOptimizer.optimizeBestEffort(route, in: context)
        return stop
    }

    /// Edits a stop. Re-geocodes only when the address actually changed —
    /// an edited name or note is not a reason to spend a throttled round trip,
    /// or to move a pin the driver placed by hand.
    ///
    /// `forceGeocode` is the one way back from a hand-placed pin: the address
    /// has not changed, so nothing here would otherwise look it up again, and
    /// the pin would quietly outlive the driver's decision to discard it.
    static func updateStop(
        _ stop: Stop,
        kunde: String, strasse: String, plz: String,
        paket: String?, notiz: String?,
        coordinate: (lat: Double, lon: Double)? = nil,
        forceGeocode: Bool = false,
        in context: ModelContext
    ) async throws {
        try validateCustomerFields(
            kunde: kunde, strasse: strasse, paket: paket, notiz: notiz)
        guard Districts.isValid(plz) else {
            throw AppError.message("Kein gültiger Wiener Bezirk: \(plz)")
        }

        let addressChanged =
            AddressText.matchKey(stop.strasse ?? "") != AddressText.matchKey(strasse)
            || stop.plz != plz
        var moved = false

        if let coordinate {
            guard Coordinates.isPlausible(lat: coordinate.lat, lon: coordinate.lon) else {
                throw AppError.message("Ungültige Koordinaten (außerhalb des erwarteten Bereichs).")
            }
            stop.lat = coordinate.lat
            stop.lon = coordinate.lon
            stop.precision = nil
            stop.pinned = true
            moved = true
        } else if addressChanged || forceGeocode {
            let hit = try await Geocoder.shared.geocode(strasse: strasse, plz: plz)
            stop.lat = hit.lat
            stop.lon = hit.lon
            stop.precision = hit.precision == .exact ? nil : hit.precision
            stop.pinned = false
            moved = true
        }

        stop.kunde = kunde.trimmed
        stop.strasse = strasse.trimmed
        stop.plz = plz
        stop.paket = paket?.trimmed.nilIfEmpty
        stop.notiz = notiz?.trimmed.nilIfEmpty

        if moved, let route = stop.route {
            route.needsOptimize = true
            try context.save()
            await RouteOptimizer.optimizeBestEffort(route, in: context)
        } else {
            try context.save()
        }
    }

    static func deleteStop(_ stop: Stop, in context: ModelContext) async throws {
        let route = stop.route
        context.delete(stop)
        route?.needsOptimize = true
        try context.save()
        if let route {
            await RouteOptimizer.optimizeBestEffort(route, in: context)
        }
    }

    static func setDelivered(
        _ stop: Stop, _ delivered: Bool, in context: ModelContext
    ) throws {
        stop.delivered = delivered
        // Deliberately does *not* complete the route on the last tick. A tour
        // being finished is the driver's call, not an inference: they may still
        // have a stop to un-tick, a note to add, or a customer who was not home.
        // Auto-completing also moved the route straight out of the active list
        // from under the screen they were standing on. "Als erledigt markieren"
        // is in the route menu for exactly this.
        try context.save()
    }

    /// Switches a fixed stop off (or back on) for this route.
    static func setExcluded(
        _ stop: Stop, _ excluded: Bool, in context: ModelContext
    ) async throws {
        guard stop.kind.isFixed else { return }
        stop.excluded = excluded
        guard let route = stop.route else { return try context.save() }
        route.needsOptimize = true
        try context.save()
        await RouteOptimizer.optimizeBestEffort(route, in: context)
    }

    /// Moves a pin by hand. Outranks the geocoder from here on.
    static func pinDrop(
        _ stop: Stop, to coordinate: (lat: Double, lon: Double),
        in context: ModelContext
    ) async throws {
        guard Coordinates.isPlausible(lat: coordinate.lat, lon: coordinate.lon) else {
            throw AppError.message("Ungültige Koordinaten (außerhalb des erwarteten Bereichs).")
        }
        stop.lat = coordinate.lat
        stop.lon = coordinate.lon
        stop.precision = nil
        stop.pinned = true
        guard let route = stop.route else { return try context.save() }
        route.needsOptimize = true
        try context.save()
        await RouteOptimizer.optimizeBestEffort(route, in: context)
    }

    // MARK: - Re-check addresses

    /// Re-resolves every approximate stop on the route, in case a geocoder has
    /// caught up since. Hand-placed pins are left alone: the driver stood in
    /// front of the building and told us where it is.
    /// `onProgress` is called with `(done, total)` before each lookup. Every one
    /// of those is a throttled round trip, so a route with thirty approximate
    /// addresses takes the better part of a minute — long enough that a bare
    /// spinner stops reading as "working" and starts reading as "stuck".
    @discardableResult
    static func recheckAddresses(
        _ route: Route, in context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> (improved: Int, unchanged: Int, failed: Int) {
        let candidates = route.customerStops.filter { $0.precision != nil && !$0.pinned }
        var improved = 0, unchanged = 0, failed = 0
        var moved = false

        for (index, stop) in candidates.enumerated() {
            onProgress?(index, candidates.count)
            guard let strasse = stop.strasse, let plz = stop.plz else { continue }
            do {
                let hit = try await Geocoder.shared.geocode(strasse: strasse, plz: plz)
                let newPrecision: Precision? = hit.precision == .exact ? nil : hit.precision
                // Only an actual improvement is written. Re-storing the same
                // approximation would churn the route's geometry for nothing.
                // Compared with a tolerance, not `!=`: two coordinates that
                // differ in the last bit are the same door, and treating them
                // as a move re-optimised the whole route for nothing.
                let movedFar = abs(hit.lat - stop.lat) > 0.000001
                    || abs(hit.lon - stop.lon) > 0.000001
                if newPrecision != stop.precision || movedFar {
                    stop.lat = hit.lat
                    stop.lon = hit.lon
                    stop.precision = newPrecision
                    improved += 1
                    moved = true
                } else {
                    unchanged += 1
                }
            } catch {
                failed += 1
            }
        }

        if moved {
            route.needsOptimize = true
            try? context.save()
            await RouteOptimizer.optimizeBestEffort(route, in: context)
        }
        return (improved, unchanged, failed)
    }

    // MARK: - JSON bulk import

    static func exportJSON(_ route: Route) -> String {
        exportJSON(
            route.customerStops.map {
                CustomerJSON(
                    kunde: $0.kunde ?? "", strasse: $0.strasse ?? "", plz: $0.plz ?? "",
                    paket: $0.paket ?? "", notiz: $0.notiz ?? "")
            })
    }

    /// The same text for a list that is not on a route yet — what the photo
    /// import hands to the JSON editor when a scanned page needs fixing up as
    /// text rather than row by row.
    nonisolated static func exportJSON(_ payload: [CustomerJSON]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }

    /// `nonisolated` because it is a pure decode. Nothing here touches the
    /// store, and pinning it to the main actor only means a future caller
    /// cannot parse a large paste off it.
    nonisolated static func parseImport(_ text: String) throws -> [CustomerJSON] {
        guard let data = text.data(using: .utf8) else {
            throw AppError.message("Ungültiges JSON: erwarte eine Liste von Kundenstopps.")
        }
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([CustomerJSON].self, from: data) { return list }
        // The web app's own export wraps the list in `{"stops": [...]}`.
        struct Wrapper: Decodable { let stops: [CustomerJSON] }
        if let w = try? decoder.decode(Wrapper.self, from: data) { return w.stops }
        throw AppError.message("Ungültiges JSON: erwarte eine Liste von Kundenstopps.")
    }

    /// Replaces the route's customer stops with a pasted list, preserving as
    /// much as possible of what the existing stops carry — above all
    /// `delivered`, which is not in the paste and which a careless
    /// delete-and-reinsert would silently throw away at midday.
    ///
    /// `onProgress` is called with `(done, total)` before each address that
    /// actually has to be looked up — which on a re-paste is none of them, and
    /// on a fresh day's list is all thirty, at a throttled round trip each.
    static func importJSON(
        _ entries: [CustomerJSON], into route: Route, in context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> ImportResult {
        guard entries.count <= maxBulkStops else {
            throw AppError.message(
                "Zu viele Stopps auf einmal (\(entries.count), max. \(maxBulkStops)). "
                    + "Bitte in kleineren Gruppen importieren.")
        }

        var result = ImportResult()

        // --- validate, per entry rather than fatally ---
        // A single stray control character or over-length field in one of up
        // to 97 pasted stops used to abort the whole import with one generic
        // error naming only the first offender — the driver then had to scan
        // however many JSON objects by hand to find it.
        var normalized: [CustomerJSON] = []
        for (idx, e) in entries.enumerated() {
            let kunde = e.kunde.trimmed
            let strasse = e.strasse.trimmed
            let plz = e.plz.trimmed
            let label = [kunde, strasse, plz].first { !$0.isEmpty } ?? "Eintrag \(idx + 1)"

            guard !kunde.isEmpty, !strasse.isEmpty, !plz.isEmpty else {
                result.validationFailures.append(
                    (label, "Kunde, Straße und Bezirk sind Pflichtfelder."))
                continue
            }
            do {
                try validateCustomerFields(
                    kunde: kunde, strasse: strasse, paket: e.paket, notiz: e.notiz)
            } catch let err as AppError {
                result.validationFailures.append((label, err.message))
                continue
            }
            normalized.append(
                CustomerJSON(
                    kunde: kunde, strasse: strasse, plz: plz,
                    paket: e.paket?.trimmed.nilIfEmpty, notiz: e.notiz?.trimmed.nilIfEmpty))
        }

        let existing = route.customerStops
        var matched = Set<UUID>()
        var toUpdate: [(CustomerJSON, Stop)] = []
        var unresolved: [(entry: CustomerJSON, existing: Stop?)] = []

        // --- Pass 1: match on address ---
        // The common case, and the cheap one — an unchanged address means an
        // unchanged location, so there is nothing to geocode and nothing to
        // re-route.
        //
        // Each address bucket carries the stop's name alongside it, because an
        // address alone is not enough to say *which* stop an entry is. Two
        // customers at one door is a case this app goes out of its way to
        // support — one building, two households, two meals. Matching a bucket
        // positionally would silently assume the paste lists them in the same
        // order the store happens to hold them; re-paste with the rows swapped
        // and each one claims the *other's* stop, writing the names over each
        // other while `delivered` stays where it was.
        var byAddress: [AddressKey: [Stop]] = [:]
        for s in existing {
            byAddress[AddressKey(s.strasse ?? "", s.plz ?? ""), default: []].append(s)
        }

        for entry in normalized {
            let key = AddressKey(entry.strasse, entry.plz)
            guard var bucket = byAddress[key], !bucket.isEmpty else {
                unresolved.append((entry, nil))
                continue
            }
            // The same name at the same address is the same stop, whatever
            // order either side lists them in. Falling back to the first
            // unclaimed one when no name matches keeps the behaviour that was
            // right for a customer renamed in place at an unchanged address —
            // an edit of that stop, not a new one.
            let wanted = nameKey(entry.kunde)
            let pos = bucket.firstIndex { nameKey($0.kunde ?? "") == wanted } ?? 0
            let stop = bucket.remove(at: pos)
            byAddress[key] = bucket
            matched.insert(stop.id)
            toUpdate.append((entry, stop))
        }

        // --- Pass 2: match the leftovers on customer name ---
        // Address matching alone cannot tell "Fam. Gruber moved to a new flat"
        // apart from "Fam. Gruber left the route and someone new joined". It
        // resolves both as a delete plus an insert — which loses everything
        // the stop carried that is not in the paste, and what it carries is
        // `delivered`. Re-pasting a corrected list at midday would silently
        // un-tick a customer who had already had their meal.
        //
        // Deliberately conservative: a name must be unambiguous on *both*
        // sides — exactly one unclaimed existing stop and exactly one
        // unclaimed submitted entry — or the pass declines and the
        // delete/insert behaviour stands. Guessing between two customers
        // called "Fam. Gruber" would be worse than not guessing at all.
        var submittedNameCounts: [String: Int] = [:]
        for u in unresolved {
            submittedNameCounts[nameKey(u.entry.kunde), default: 0] += 1
        }
        var existingByName: [String: [Stop]] = [:]
        for s in existing where !matched.contains(s.id) {
            existingByName[nameKey(s.kunde ?? ""), default: []].append(s)
        }
        for i in unresolved.indices {
            let key = nameKey(unresolved[i].entry.kunde)
            guard submittedNameCounts[key] == 1,
                  let ids = existingByName[key], ids.count == 1
            else { continue }
            matched.insert(ids[0].id)
            existingByName.removeValue(forKey: key)
            unresolved[i].existing = ids[0]
        }

        // --- apply the cheap matches ---
        // The address is rewritten too, even though matching on it is what got
        // us here: the match key collapses "Hauptstr. 5" and "Hauptstraße 5"
        // onto one door on purpose, so an entry can carry a tidied spelling of
        // an address the store still holds in its old form. Same door, same
        // coordinates, nothing to geocode — but the list should read back what
        // the driver last pasted rather than a spelling they already corrected.
        // Written only when it actually differs, so an unchanged paste is not
        // turned into a store full of dirty rows.
        //
        // Every field is written only where it actually differs, and the entry
        // counts as "Aktualisiert" only if at least one of them did. Both for
        // the same reason: re-pasting this morning's unchanged list is the
        // normal case, and it used to mark every row in the route dirty and
        // then report "Aktualisiert: 30" for an import that changed nothing.
        for (entry, stop) in toUpdate {
            var changed = false
            if stop.kunde != entry.kunde { stop.kunde = entry.kunde; changed = true }
            if stop.strasse != entry.strasse { stop.strasse = entry.strasse; changed = true }
            if stop.plz != entry.plz { stop.plz = entry.plz; changed = true }
            if stop.paket != entry.paket { stop.paket = entry.paket; changed = true }
            if stop.notiz != entry.notiz { stop.notiz = entry.notiz; changed = true }
            if changed { result.updated += 1 }
        }

        // --- geocode whatever is left ---
        // Invalid postcodes are split off first: no network call is worth
        // spending on a PLZ that cannot possibly be a Vienna address.
        var needsGeocode: [(CustomerJSON, Stop?)] = []
        for u in unresolved {
            guard Districts.isValid(u.entry.plz) else {
                result.geocodeFailures.append(
                    (u.entry.kunde, u.entry.strasse, u.entry.plz))
                continue
            }
            needsGeocode.append((u.entry, u.existing))
        }

        // Handed out one at a time as stops are inserted. Read off the route
        // inside the loop — which is what this did — every insert re-scanned
        // every stop on the route to find the highest index, and relied on
        // SwiftData having already threaded the new stop onto the inverse
        // relationship for the next one to see it. A counter needs neither.
        var nextIndex = nextOrderIndex(in: route)

        var moved = false
        for (index, (entry, existingStop)) in needsGeocode.enumerated() {
            onProgress?(index, needsGeocode.count)
            let hit: GeocodeResult
            do {
                hit = try await Geocoder.shared.geocode(
                    strasse: entry.strasse, plz: entry.plz)
            } catch {
                result.geocodeFailures.append((entry.kunde, entry.strasse, entry.plz))
                continue
            }

            let precision: Precision? = hit.precision == .exact ? nil : hit.precision
            if let precision {
                result.approximate.append((entry.kunde, precision))
            }

            if let stop = existingStop {
                // A customer who moved — edited in place, so the delivered tick
                // and everything else the stop carries survives.
                stop.kunde = entry.kunde
                stop.strasse = entry.strasse
                stop.plz = entry.plz
                stop.paket = entry.paket
                stop.notiz = entry.notiz
                stop.lat = hit.lat
                stop.lon = hit.lon
                stop.precision = precision
                stop.pinned = false
                result.moved += 1
            } else {
                let stop = Stop(
                    kind: .customer, kunde: entry.kunde, strasse: entry.strasse,
                    plz: entry.plz, paket: entry.paket, notiz: entry.notiz,
                    lat: hit.lat, lon: hit.lon,
                    orderIndex: nextIndex,
                    precision: precision)
                nextIndex += 1
                stop.route = route
                context.insert(stop)
                result.inserted += 1
            }
            moved = true
        }

        // --- delete what the paste dropped ---
        //
        // If anything failed, we cannot tell "this address was genuinely
        // removed" from "this is an edited address that just failed to
        // resolve" — both look identical here, as "not in `matched`". So a
        // round with any failure deletes nothing at all, rather than risk
        // dropping a customer who was only ever the victim of an unrelated typo
        // elsewhere in the same paste.
        //
        // Validation failures count, not just geocoding ones: an entry that
        // never passed validation never got a chance to match anything either.
        // Without that, a paste where *every* entry was rejected has zero
        // geocode failures, nothing skips deletion, and every customer stop on
        // the route is deleted as "no longer present" — a whole tour wiped by
        // one malformed paste, which is the worst thing this screen could do.
        result.deletionsSkipped =
            !result.geocodeFailures.isEmpty || !result.validationFailures.isEmpty
        if !result.deletionsSkipped {
            for stop in existing where !matched.contains(stop.id) {
                context.delete(stop)
                result.deleted += 1
                moved = true
            }
        }

        if moved {
            route.needsOptimize = true
        }
        try context.save()
        if moved {
            await RouteOptimizer.optimizeBestEffort(route, in: context)
        }
        return result
    }

    // MARK: - Validation

    /// Guards every value that ends up stored, or sent to a shared third-party
    /// service. Nominatim enforces its usage policy per *client*, so a client
    /// that sends it garbage risks the whole app getting blocked.
    nonisolated static func validateCustomerFields(
        kunde: String, strasse: String, paket: String?, notiz: String?
    ) throws {
        try checkLength(kunde, "Kunde", FieldLimits.kunde)
        try checkLength(strasse, "Straße", FieldLimits.strasse)
        if let paket { try checkLength(paket, "Paket", FieldLimits.paket) }
        if let notiz { try checkLength(notiz, "Notiz", FieldLimits.notiz) }

        try checkNoControlChars(kunde, "Kunde", allowNewlines: false)
        try checkNoControlChars(strasse, "Straße", allowNewlines: false)
        if let paket { try checkNoControlChars(paket, "Paket", allowNewlines: false) }
        if let notiz { try checkNoControlChars(notiz, "Notiz", allowNewlines: true) }
    }

    private nonisolated static func checkLength(
        _ value: String, _ field: String, _ max: Int
    ) throws {
        guard value.count <= max else {
            throw AppError.message("\(field) ist zu lang (max. \(max) Zeichen).")
        }
    }

    private nonisolated static func checkNoControlChars(
        _ value: String, _ field: String, allowNewlines: Bool
    ) throws {
        for scalar in value.unicodeScalars {
            let isNewline = scalar == "\n" || scalar == "\r"
            if allowNewlines && isNewline { continue }
            if scalar == "\t" { continue }
            if CharacterSet.controlCharacters.contains(scalar) {
                throw AppError.message("\(field) enthält ungültige Steuerzeichen.")
            }
        }
    }

    // MARK: - Ordering

    /// Where a newly added stop goes: after everything already on the route.
    ///
    /// One pass, no intermediate array — this is called once per inserted stop
    /// during a bulk import of up to 97 of them. The position is provisional in
    /// any case: the optimizer rewrites every `orderIndex` as soon as it has an
    /// answer, and until it does the stop belongs at the end of the list rather
    /// than wherever an unset index would sort it.
    private static func nextOrderIndex(in route: Route) -> Int {
        var highest = 0
        for s in route.stops where s.orderIndex > highest { highest = s.orderIndex }
        return highest + 1
    }

    // MARK: - Matching keys

    /// Address plus postcode, in the normalized form that survives being
    /// re-exported by a different system.
    private struct AddressKey: Hashable {
        let street: String
        let plz: String
        init(_ strasse: String, _ plz: String) {
            self.street = AddressText.matchKey(strasse)
            self.plz = plz.trimmed
        }
    }

    private static func nameKey(_ kunde: String) -> String {
        kunde.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ").lowercased()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
