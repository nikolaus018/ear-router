import Foundation
import SwiftData
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "store")

/// One customer stop as it travels through the JSON bulk editor — the same
/// shape the old backend's `/api/routes/:id/json` accepted, so a list exported
/// from the web app pastes straight into this one.
struct CustomerJSON: Codable, Sendable, Hashable {
    var kunde: String
    var strasse: String
    var plz: String
    var paket: String?
    var notiz: String?
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

    static func defaultRouteName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_AT")
        f.dateFormat = "dd.MM.yyyy"
        return "Tour \(f.string(from: Date()))"
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
        guard route.customerStops.count < maxBulkStops else {
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
            orderIndex: (route.stops.map(\.orderIndex).max() ?? 0) + 1,
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
    @discardableResult
    static func recheckAddresses(
        _ route: Route, in context: ModelContext
    ) async -> (improved: Int, unchanged: Int, failed: Int) {
        let candidates = route.customerStops.filter { $0.precision != nil && !$0.pinned }
        var improved = 0, unchanged = 0, failed = 0
        var moved = false

        for stop in candidates {
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
        let payload = route.customerStops.map {
            CustomerJSON(
                kunde: $0.kunde ?? "", strasse: $0.strasse ?? "", plz: $0.plz ?? "",
                paket: $0.paket ?? "", notiz: $0.notiz ?? "")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }

    static func parseImport(_ text: String) throws -> [CustomerJSON] {
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
    static func importJSON(
        _ entries: [CustomerJSON], into route: Route, in context: ModelContext
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
        for (entry, stop) in toUpdate {
            stop.kunde = entry.kunde
            stop.paket = entry.paket
            stop.notiz = entry.notiz
            result.updated += 1
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

        var moved = false
        for (entry, existingStop) in needsGeocode {
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
                    orderIndex: (route.stops.map(\.orderIndex).max() ?? 0) + 1,
                    precision: precision)
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
    static func validateCustomerFields(
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

    private static func checkLength(_ value: String, _ field: String, _ max: Int) throws {
        guard value.count <= max else {
            throw AppError.message("\(field) ist zu lang (max. \(max) Zeichen).")
        }
    }

    private static func checkNoControlChars(
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
