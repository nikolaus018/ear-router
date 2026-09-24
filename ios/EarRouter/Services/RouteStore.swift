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
    /// The customer's own number — from the Zusteller-Portal's
    /// `customer.phone` when the entry came from there, typed by hand
    /// otherwise. Optional like `paket` and `notiz`: most sources this app
    /// reads from, a pasted list included, simply do not carry one.
    var telefon: String?

    init(
        kunde: String, strasse: String, plz: String, paket: String?, notiz: String?,
        telefon: String? = nil
    ) {
        self.kunde = kunde
        self.strasse = strasse
        self.plz = plz
        self.paket = paket
        self.notiz = notiz
        self.telefon = telefon
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
        telefon = try c.decodeIfPresent(String.self, forKey: .telefon)
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
    /// The driver stopped the import part-way. What had already resolved is
    /// kept; the rest was never attempted, which is a different thing from
    /// having failed and is reported as such.
    var cancelled = false

    var hasProblems: Bool {
        !validationFailures.isEmpty || !geocodeFailures.isEmpty || !approximate.isEmpty
            || cancelled
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
        for s in route.stops { s.record(nil) }
        if route.status == .completed {
            route.status = .active
            route.completedAt = nil
        }
        try context.save()
    }

    /// What "Lieferstatus zurücksetzen" is about to do, counted at the moment
    /// of asking. One sentence for both places that ask — the tour's menu and
    /// "Tour vorbereiten" — so they cannot describe the same button two ways.
    ///
    /// Settled, not delivered: this clears a "nicht angetroffen" too, and a
    /// dialog that promised to reset three stops while quietly reopening five
    /// was understating what the button does.
    static func resetDeliveredMessage(for route: Route) -> String {
        let n = route.settledCount
        let what = n == 1
            ? "1 abgehakter Stopp wird wieder auf offen gesetzt"
            : "\(n) abgehakte Stopps werden wieder auf offen gesetzt"
        return route.status == .completed
            ? "\(what), und die Tour wird wieder aktiviert."
            : "\(what)."
    }

    // MARK: - Stops

    /// Adds a customer stop, geocoding the address unless coordinates were
    /// supplied directly (the pin-drop path, which needs no network).
    @discardableResult
    static func addStop(
        to route: Route,
        kunde: String, strasse: String, plz: String,
        paket: String?, notiz: String?, telefon: String? = nil,
        coordinate: (lat: Double, lon: Double)? = nil,
        in context: ModelContext
    ) async throws -> Stop {
        try validateCustomerFields(
            kunde: kunde, strasse: strasse, paket: paket, notiz: notiz, telefon: telefon)
        guard Postcodes.isValid(plz) else {
            throw AppError.message("Keine gültige Postleitzahl: \(plz)")
        }
        // `customerCount`, not `customerStops.count`: the answer is a number,
        // and going through the ordered list sorted the whole route to get it.
        guard route.customerCount < maxBulkStops else {
            throw AppError.message(
                "Diese Route hat schon \(maxBulkStops) Kundenstopps — das ist das Maximum "
                    + "für die Routenoptimierung.")
        }

        let lat: Double, lon: Double, precision: Precision?, pinned: Bool
        var entrance: (lat: Double, lon: Double)?

        if let coordinate {
            try checkPin(coordinate, plz: plz)
            (lat, lon, precision, pinned) = (coordinate.lat, coordinate.lon, nil, true)
        } else {
            let hit = try await Geocoder.shared.geocode(strasse: strasse, plz: plz)
            (lat, lon, pinned) = (hit.lat, hit.lon, false)
            precision = hit.precision == .exact ? nil : hit.precision
            entrance = await Geocoder.shared.entrance(strasse: strasse, plz: plz)
        }

        // The driver pressed Abbrechen while the address was being looked up,
        // or the editor's own 30-second budget ran out. Either way the answer
        // arrived after it stopped being wanted: a lookup that resolves from
        // the cache, or a register that answers just as the cancel propagates,
        // reaches here with a perfectly good result and no reason left to
        // write it. Adding the stop anyway is the one outcome the editor's
        // Abbrechen promises will not happen — and the obvious response to a
        // stop that appeared after cancelling is to delete it again.
        try Task.checkCancellation()

        let stop = Stop(
            kind: .customer, kunde: kunde.trimmed, strasse: strasse.trimmed, plz: plz,
            paket: paket?.trimmed.nilIfEmpty, notiz: notiz?.trimmed.nilIfEmpty,
            telefon: telefon?.trimmed.nilIfEmpty,
            lat: lat, lon: lon,
            // Appended at the end until the optimizer places it properly.
            orderIndex: nextOrderIndex(in: route),
            precision: precision, pinned: pinned)
        stop.setEntrance(entrance)
        stop.route = route
        context.insert(stop)
        route.markRoutingStale()
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
        paket: String?, notiz: String?, telefon: String? = nil,
        coordinate: (lat: Double, lon: Double)? = nil,
        forceGeocode: Bool = false,
        in context: ModelContext
    ) async throws {
        try validateCustomerFields(
            kunde: kunde, strasse: strasse, paket: paket, notiz: notiz, telefon: telefon)
        guard Postcodes.isValid(plz) else {
            throw AppError.message("Keine gültige Postleitzahl: \(plz)")
        }

        let addressChanged = Self.addressMoved(stop, toStrasse: strasse, plz: plz)
        var moved = false

        if let coordinate {
            // Against the postcode being written, not the one the stop still
            // carries: the driver may be moving both in the same edit.
            try checkPin(coordinate, plz: plz)
            stop.lat = coordinate.lat
            stop.lon = coordinate.lon
            stop.precision = nil
            stop.pinned = true
            // The pin is what navigation gets now; an entrance for an address
            // typed over in the same edit would be somebody else's door.
            if addressChanged { stop.setEntrance(nil) }
            moved = true
        } else if addressChanged || forceGeocode {
            let hit = try await Geocoder.shared.geocode(strasse: strasse, plz: plz)
            let entrance = await Geocoder.shared.entrance(strasse: strasse, plz: plz)
            // Before the row is touched at all — see `addStop`. This is the
            // only suspension point in the whole edit, so throwing here leaves
            // the stop exactly as the driver found it rather than half-written
            // with a position they cancelled out of.
            try Task.checkCancellation()
            stop.lat = hit.lat
            stop.lon = hit.lon
            stop.precision = hit.precision == .exact ? nil : hit.precision
            stop.pinned = false
            stop.setEntrance(entrance)
            moved = true
        }

        stop.kunde = kunde.trimmed
        stop.strasse = strasse.trimmed
        stop.plz = plz
        stop.paket = paket?.trimmed.nilIfEmpty
        stop.notiz = notiz?.trimmed.nilIfEmpty
        stop.telefon = telefon?.trimmed.nilIfEmpty

        if moved, let route = stop.route {
            route.markRoutingStale()
            try context.save()
            await RouteOptimizer.optimizeBestEffort(route, in: context)
        } else {
            try context.save()
        }
    }

    static func deleteStop(_ stop: Stop, in context: ModelContext) async throws {
        let route = stop.route
        context.delete(stop)
        route?.markRoutingStale()
        try context.save()
        if let route {
            await RouteOptimizer.optimizeBestEffort(route, in: context)
        }
    }

    /// Records what happened at a door, or re-opens it with `nil`.
    ///
    /// Deliberately does *not* complete the route on the last stop. A tour
    /// being finished is the driver's call, not an inference: they may still
    /// have a stop to take back, a note to add, or a door to try again on the
    /// way home. Auto-completing also moved the route straight out of the
    /// active list from under the screen they were standing on. "Tour
    /// abschließen" is on the tour's own screen for exactly this.
    static func record(
        _ outcome: DeliveryOutcome?, for stop: Stop, at date: Date = Date(),
        in context: ModelContext
    ) throws {
        stop.record(outcome, at: date)
        try context.save()
    }

    /// The plain tick, which is still what happens at twenty-nine doors out of
    /// thirty: on means delivered, off means not answered for yet.
    static func setDelivered(
        _ stop: Stop, _ delivered: Bool, in context: ModelContext
    ) throws {
        try record(delivered ? .delivered : nil, for: stop, in: context)
    }

    /// Takes one delivery back, found by the id the undo banner is holding.
    ///
    /// By id rather than by keeping hold of the `Stop`, because the banner
    /// outlives the card it was made from: Jetzt has already moved on to the
    /// next door by the time it appears, and the tour behind it may have been
    /// re-optimised in between. An id still means the same stop afterwards.
    ///
    /// `false` for an id this route no longer has — a stop deleted from
    /// another screen inside the banner's few seconds. Nothing to take back,
    /// and nothing worth telling the driver either: the delivery they were
    /// undoing went with the stop.
    ///
    /// Here rather than in the view so that the rule this screen's one
    /// irreversible-looking action depends on can be tested. The banner is
    /// alive for six seconds, which is long enough for a driver and too short
    /// to drive from a test.
    @discardableResult
    static func undoDelivery(
        _ id: UUID, on route: Route, in context: ModelContext
    ) throws -> Bool {
        guard let stop = route.stops.first(where: { $0.id == id }) else { return false }
        try setDelivered(stop, false, in: context)
        return true
    }

    /// Switches a fixed stop off (or back on) for this route.
    static func setExcluded(
        _ stop: Stop, _ excluded: Bool, in context: ModelContext
    ) async throws {
        guard stop.kind.isFixed else { return }
        stop.excluded = excluded
        guard let route = stop.route else { return try context.save() }
        route.markRoutingStale()
        try context.save()
        await RouteOptimizer.optimizeBestEffort(route, in: context)
    }

    /// Moves a pin by hand. Outranks the geocoder from here on.
    static func pinDrop(
        _ stop: Stop, to coordinate: (lat: Double, lon: Double),
        in context: ModelContext
    ) async throws {
        try checkPin(coordinate, plz: stop.plz ?? "")
        stop.lat = coordinate.lat
        stop.lon = coordinate.lon
        stop.precision = nil
        stop.pinned = true
        guard let route = stop.route else { return try context.save() }
        route.markRoutingStale()
        try context.save()
        await RouteOptimizer.optimizeBestEffort(route, in: context)
    }

    /// Puts the customers in the order the driver dragged them into, and marks
    /// the tour hand-sorted so later edits keep that order. Returns
    /// whether anything moved; if so, the route is flagged and wants
    /// `RouteOptimizer.optimizeBestEffort(_:in:keepOrder: true)` next, which
    /// draws the line and the distances through exactly that order.
    ///
    /// Synchronous, so the list shows the drop in the same frame as the drag.
    /// Customers missing from `customerIDs` keep their place after the ones
    /// named. The fixed points are not in the list at all — they stay at the
    /// top and the bottom whatever was dragged past them.
    @discardableResult
    static func reorder(
        _ route: Route, customerIDs: [UUID], in context: ModelContext
    ) throws -> Bool {
        let order = customers(of: route, orderedBy: customerIDs)
        guard order.map(\.id) != route.customerStops.map(\.id) else { return false }
        writeOrder(order, of: route)
        try context.save()
        return true
    }

    /// The route's customers in the order `customerIDs` names them, followed
    /// by any it does not name, in the place they already had.
    private static func customers(of route: Route, orderedBy customerIDs: [UUID]) -> [Stop] {
        // Not a stop deleted in the same unsaved round — an import deletes
        // before it orders.
        let customers = route.customerStops.filter { !$0.isDeleted }
        let byID = Dictionary(customers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let named = customerIDs.compactMap { byID[$0] }
        let namedIDs = Set(named.map(\.id))
        return named + customers.filter { !namedIDs.contains($0.id) }
    }

    /// Writes `order` onto the customers and marks the tour sorted by hand:
    /// the fixed points stay at the top and the bottom whatever order the
    /// customers are in, and the stale leg distances go until the route is
    /// drawn through the new order. Does not save.
    private static func writeOrder(_ order: [Stop], of route: Route) {
        let fixed = route.orderedStops.filter { $0.kind != .customer }
        let head = fixed.filter { $0.kind != .end }
        let tail = fixed.filter { $0.kind == .end }
        for (index, stop) in (head + order + tail).enumerated() {
            stop.orderIndex = index
            stop.nextLegKm = nil
            stop.nextLegMin = nil
        }
        route.handOrdered = true
        route.markRoutingStale()
    }

    // MARK: - Re-check addresses

    /// Re-resolves every approximate stop on the route, in case a geocoder has
    /// caught up since. Hand-placed pins are left alone: the driver stood in
    /// front of the building and told us where it is.
    /// `onProgress` is called with `(done, total)` before each lookup. Every one
    /// of those is a throttled round trip, so a route with thirty approximate
    /// addresses takes the better part of a minute — long enough that a bare
    /// spinner stops reading as "working" and starts reading as "stuck".
    ///
    /// `stored` is false when the improvements could not be written. It is the
    /// one outcome here that is not about an address: `try?` on that save meant
    /// a store in trouble reported "12 verbessert" over twelve corrections that
    /// went nowhere, and the driver set off on pins the app had already told
    /// them were fixed.
    @discardableResult
    static func recheckAddresses(
        _ route: Route, in context: ModelContext,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> (improved: Int, unchanged: Int, failed: Int, stored: Bool) {
        let candidates = route.customerStops.filter { $0.precision != nil && !$0.pinned }
        var improved = 0, unchanged = 0, failed = 0
        var moved = false

        for (index, stop) in candidates.enumerated() {
            // Stops the whole run rather than the one address. Cancelled and
            // caught below as an ordinary failure — which is what this did —
            // the loop marched through all thirty remaining addresses anyway,
            // at a throttled round trip each, and reported every one of them as
            // "weiter offen".
            if Task.isCancelled { break }
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
                // A *worse* answer is not an answer. The register can come back
                // with only a district for an address it previously placed on
                // the right street — a transient reindex, a query that fuzzed
                // differently — and writing that back moved a usable pin to the
                // middle of the Bezirk and reported it as "verbessert". This
                // screen exists to improve approximate stops; it must never be
                // able to make one worse.
                guard isAtLeastAsGood(newPrecision, as: stop.precision) else {
                    unchanged += 1
                    continue
                }
                if newPrecision != stop.precision || movedFar {
                    stop.lat = hit.lat
                    stop.lon = hit.lon
                    stop.precision = newPrecision
                    // Looked up again below, for the address as it now resolves.
                    stop.setEntrance(nil)
                    improved += 1
                    moved = true
                } else {
                    unchanged += 1
                }
            } catch is CancellationError {
                break
            } catch {
                failed += 1
            }
        }

        // Every stop still without an entrance gets one looked up — which is
        // also how a tour imported before entrances existed catches up.
        let filled = Task.isCancelled ? 0 : await fillEntrances(route.customerStops)

        guard moved else {
            guard filled > 0 else { return (improved, unchanged, failed, true) }
            do {
                try context.save()
            } catch {
                context.rollback()
                return (improved, unchanged, failed, false)
            }
            return (improved, unchanged, failed, true)
        }

        route.markRoutingStale()
        do {
            try context.save()
        } catch {
            // Wound back, so the route keeps the pins it had rather than
            // holding corrections in memory that the next unrelated write would
            // either flush or lose. Nothing was improved, because nothing was
            // kept — and the caller is told so rather than shown a total.
            context.rollback()
            return (0, unchanged, failed, false)
        }
        await RouteOptimizer.optimizeBestEffort(route, in: context)
        return (improved, unchanged, failed, true)
    }

    /// Whether `candidate` places a stop at least as precisely as `current`.
    /// `nil` is the best answer there is — an exact match, or a hand-placed pin.
    ///
    /// Not `private`: this is the rule that decides whether a re-check is
    /// allowed to overwrite a pin, and it is worth a test of its own.
    nonisolated static func isAtLeastAsGood(_ candidate: Precision?, as current: Precision?) -> Bool {
        func rank(_ p: Precision?) -> Int {
            switch p {
            case .none, .some(.exact): 0
            case .some(.street): 1
            case .some(.district): 2
            }
        }
        return rank(candidate) <= rank(current)
    }

    // MARK: - JSON bulk import

    static func exportJSON(_ route: Route) -> String {
        let payload = route.customerStops.map {
            CustomerJSON(
                kunde: $0.kunde ?? "", strasse: $0.strasse ?? "", plz: $0.plz ?? "",
                paket: $0.paket ?? "", notiz: $0.notiz ?? "", telefon: $0.telefon ?? "")
        }
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
    ///
    /// `keepOrder` is a list the driver has put in the order they drive it:
    /// the tour takes that order and is marked sorted by hand, so the routing
    /// afterwards draws the line through it instead of solving a new one.
    /// `reroute: false` leaves that routing to the caller; only tests use it.
    static func importJSON(
        _ entries: [CustomerJSON], into route: Route, in context: ModelContext,
        keepOrder: Bool = false, reroute: Bool = true,
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
                    (label, "Kunde, Straße und PLZ sind Pflichtfelder."))
                continue
            }
            do {
                try validateCustomerFields(
                    kunde: kunde, strasse: strasse, paket: e.paket, notiz: e.notiz,
                    telefon: e.telefon)
            } catch let err as AppError {
                result.validationFailures.append((label, err.message))
                continue
            }
            normalized.append(
                CustomerJSON(
                    kunde: kunde, strasse: strasse, plz: plz,
                    paket: e.paket?.trimmed.nilIfEmpty, notiz: e.notiz?.trimmed.nilIfEmpty,
                    telefon: e.telefon?.trimmed.nilIfEmpty))
        }

        let existing = route.customerStops
        let match = Self.match(normalized, against: existing)
        let matched = match.matched
        let toUpdate = match.toUpdate
        let unresolved = match.unresolved

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
            if stop.telefon != entry.telefon { stop.telefon = entry.telefon; changed = true }
            if changed { result.updated += 1 }
        }

        // --- geocode whatever is left ---
        // Invalid postcodes are split off first: no network call is worth
        // spending on a PLZ that cannot possibly be an Austrian address.
        var needsGeocode: [(CustomerJSON, Stop?)] = []
        for u in unresolved {
            guard Postcodes.isValid(u.entry.plz) else {
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
            // Checked here as well as by the lookup below: an address already
            // in the cache comes back without ever reaching a cancellation
            // point, so a re-import of a known list carried on inserting stops
            // after "Stoppen" had been pressed.
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            onProgress?(index, needsGeocode.count)
            let hit: GeocodeResult
            do {
                hit = try await Geocoder.shared.geocode(
                    strasse: entry.strasse, plz: entry.plz)
            } catch is CancellationError {
                // Everything resolved so far is kept and saved below — the
                // stops are real and re-pasting the same list will not look
                // them up again. What a cancelled run must not do is carry on
                // through the rest at a throttled round trip each, nor record
                // the addresses it never tried as failures the driver then goes
                // hunting for. `deletionsSkipped` covers the rest: an
                // interrupted run has not seen enough to delete anything.
                result.cancelled = true
                break
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
                stop.telefon = entry.telefon
                stop.lat = hit.lat
                stop.lon = hit.lon
                stop.precision = precision
                stop.pinned = false
                stop.setEntrance(nil)
                result.moved += 1
            } else {
                let stop = Stop(
                    kind: .customer, kunde: entry.kunde, strasse: entry.strasse,
                    plz: entry.plz, paket: entry.paket, notiz: entry.notiz,
                    telefon: entry.telefon,
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
            || result.cancelled
        if !result.deletionsSkipped {
            for stop in existing where !matched.contains(stop.id) {
                context.delete(stop)
                result.deleted += 1
                moved = true
            }
        }

        // The driver's own order, when the list came in one. Matched again
        // rather than threaded through the passes above: every entry that made
        // it onto the tour now sits at its own address under its own name, so
        // the matcher hands the stops back in the list's order.
        if keepOrder {
            let listed = Self.match(normalized, against: route.customerStops.filter { !$0.isDeleted })
                .toUpdate.map(\.1.id)
            writeOrder(customers(of: route, orderedBy: listed), of: route)
            moved = true
        }

        if moved {
            route.markRoutingStale()
        }
        // New and moved stops, and any already on the route from before
        // entrances existed. Best effort: a stop left without one is still
        // navigated to by its address.
        if !result.cancelled {
            await fillEntrances(route.customerStops)
        }
        try context.save()
        if moved && reroute {
            await RouteOptimizer.optimizeBestEffort(route, in: context)
        }
        return result
    }

    /// Looks up the entrance for every stop that should have one and does
    /// not: Viennese, not pinned by hand. Six at a time — the register has no
    /// published rate limit, and a tour of thirty should not take thirty
    /// seconds. Returns how many were written; does not save.
    @discardableResult
    static func fillEntrances(_ stops: [Stop]) async -> Int {
        let wanted = stops.filter {
            $0.kind == .customer && !$0.pinned && $0.entranceLat == nil
                && Postcodes.isVienna($0.plz ?? "")
                && !($0.strasse?.trimmed.isEmpty ?? true)
        }
        guard !wanted.isEmpty else { return 0 }

        struct Job: Sendable { let id: UUID; let strasse: String; let plz: String }
        struct Found: Sendable { let id: UUID; let lat: Double; let lon: Double }
        var jobs = wanted.map { Job(id: $0.id, strasse: $0.strasse ?? "", plz: $0.plz ?? "") }
            .makeIterator()

        var found: [UUID: Found] = [:]
        await withTaskGroup(of: Found?.self) { group in
            func start(_ job: Job) {
                group.addTask {
                    guard let p = await Geocoder.shared.entrance(
                        strasse: job.strasse, plz: job.plz)
                    else { return nil }
                    return Found(id: job.id, lat: p.lat, lon: p.lon)
                }
            }
            for _ in 0..<6 {
                guard let job = jobs.next() else { break }
                start(job)
            }
            for await result in group {
                if let result { found[result.id] = result }
                if let job = jobs.next() { start(job) }
            }
        }

        var written = 0
        for stop in wanted {
            guard let f = found[stop.id] else { continue }
            stop.setEntrance((f.lat, f.lon))
            written += 1
        }
        return written
    }

    // MARK: - Validation

    /// Guards every value that ends up stored, or sent to a shared third-party
    /// service. Nominatim enforces its usage policy per *client*, so a client
    /// that sends it garbage risks the whole app getting blocked.
    nonisolated static func validateCustomerFields(
        kunde: String, strasse: String, paket: String?, notiz: String?, telefon: String? = nil
    ) throws {
        try checkLength(kunde, "Kunde", FieldLimits.kunde)
        try checkLength(strasse, "Straße", FieldLimits.strasse)
        if let paket { try checkLength(paket, "Paket", FieldLimits.paket) }
        if let notiz { try checkLength(notiz, "Notiz", FieldLimits.notiz) }
        if let telefon { try checkLength(telefon, "Telefon", FieldLimits.telefon) }

        try checkNoControlChars(kunde, "Kunde", allowNewlines: false)
        try checkNoControlChars(strasse, "Straße", allowNewlines: false)
        if let paket { try checkNoControlChars(paket, "Paket", allowNewlines: false) }
        if let notiz { try checkNoControlChars(notiz, "Notiz", allowNewlines: true) }
        if let telefon { try checkNoControlChars(telefon, "Telefon", allowNewlines: false) }
    }

    /// Whether an edit moves the stop to a different address.
    ///
    /// The one thing that makes `updateStop` look the address up again — and
    /// therefore the one thing that decides whether a hand-placed pin survives
    /// the save, because a pin belongs to the building it was dropped on and
    /// not to whatever address is typed over it afterwards.
    ///
    /// Not private, because the stop editor's footer is in the business of
    /// telling the driver which of those is about to happen, and it had its own
    /// copy of the answer: "Position von Hand gesetzt — die Adresse wird nicht
    /// neu gesucht", still on screen while the driver was busy typing the very
    /// change that would discard that pin. One rule, read by the screen that
    /// promises it and the code that keeps the promise.
    ///
    /// Through `matchKey`, so re-typing "Hauptstr. 5" as "Hauptstraße 5" is not
    /// a move: it is the same door, spelled the way this app spells it.
    static func addressMoved(_ stop: Stop, toStrasse strasse: String, plz: String) -> Bool {
        AddressText.matchKey(stop.strasse ?? "") != AddressText.matchKey(strasse)
            || stop.plz != plz
    }

    /// Refuses a hand-placed pin the app would not read back.
    ///
    /// Measured against the box the stop's own postcode implies, because that
    /// is the box everything downstream reads it through: `Stop.coordinate`
    /// falls back to the centre of Vienna for a point outside it, and the map,
    /// the route planning and the navigation handoff all go through there.
    ///
    /// Checked against the country-wide box instead — which is what this did —
    /// the two disagreed for exactly one kind of input: a pin dropped far from
    /// a Vienna address. A stop filed under 1210 with a pin in Graz was
    /// *accepted*, stored, and then silently drawn, planned and navigated to at
    /// Stephansplatz, with the row still wearing the "von Hand gesetzt" mark.
    /// A point the app will not use is one to refuse while the driver is still
    /// looking at the map they placed it on.
    nonisolated static func checkPin(
        _ coordinate: (lat: Double, lon: Double), plz: String
    ) throws {
        guard Coordinates.isPlausible(
            lat: coordinate.lat, lon: coordinate.lon, forPlz: plz)
        else {
            throw AppError.message(
                plz.isEmpty
                    ? "Ungültige Koordinaten (außerhalb des erwarteten Bereichs)."
                    : "Der Pin liegt zu weit von der PLZ \(plz) entfernt. Bitte ihn "
                        + "bei der Adresse setzen.")
        }
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
    ///
    /// Not private, for the reason `isAtLeastAsGood` is not: it is a rule with
    /// a claim attached, and the claim is the sentence above.
    static func nextOrderIndex(in route: Route) -> Int {
        var highest = 0
        for s in route.stops where s.orderIndex > highest { highest = s.orderIndex }
        return highest + 1
    }

    // MARK: - Matching a paste against the route

    /// Which submitted entry is which stop already on the route.
    ///
    /// Extracted so that `importJSON` and `deletionPreview` cannot drift apart:
    /// the preview's whole job is to name the customers the import is about to
    /// delete, and it can only do that honestly if it decides "matched" by
    /// exactly the same rules the import will.
    struct PasteMatch {
        /// Entries that landed on a stop whose address already matches — the
        /// cheap case, with nothing to geocode.
        var toUpdate: [(CustomerJSON, Stop)] = []
        /// Entries with no address match. `existing` is set where pass 2 could
        /// still tie the entry to a stop by name — a customer who moved.
        var unresolved: [(entry: CustomerJSON, existing: Stop?)] = []
        /// Every stop the paste accounted for. Anything on the route that is
        /// not in here is a customer the paste dropped.
        var matched = Set<UUID>()
    }

    static func match(_ entries: [CustomerJSON], against existing: [Stop]) -> PasteMatch {
        var out = PasteMatch()

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

        for entry in entries {
            let key = AddressKey(entry.strasse, entry.plz)
            guard var bucket = byAddress[key], !bucket.isEmpty else {
                out.unresolved.append((entry, nil))
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
            out.matched.insert(stop.id)
            out.toUpdate.append((entry, stop))
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
        for u in out.unresolved {
            submittedNameCounts[nameKey(u.entry.kunde), default: 0] += 1
        }
        var existingByName: [String: [Stop]] = [:]
        for s in existing where !out.matched.contains(s.id) {
            existingByName[nameKey(s.kunde ?? ""), default: []].append(s)
        }
        for i in out.unresolved.indices {
            let key = nameKey(out.unresolved[i].entry.kunde)
            guard submittedNameCounts[key] == 1,
                  let ids = existingByName[key], ids.count == 1
            else { continue }
            out.matched.insert(ids[0].id)
            existingByName.removeValue(forKey: key)
            out.unresolved[i].existing = ids[0]
        }

        return out
    }

    /// The customers on the route that this paste does not mention, by name —
    /// which is to say, the ones applying it would delete.
    ///
    /// Asked *before* the import runs, because after it there is nothing to
    /// ask. Deleting a stop from the list confirms first; deleting a tour
    /// confirms twice. Applying a paste deleted as many customer stops as it
    /// liked and said nothing at all — and the two ways to trigger it are the
    /// two most ordinary things anyone does on that screen: tapping "Leeren",
    /// which used to leave behind a valid empty list, and losing a few lines to
    /// a fat-fingered selection in a monospace editor on a phone. Everything
    /// those stops carried — the Paket, the Notiz, the delivered tick from this
    /// morning — went with them.
    ///
    /// Entries that would fail validation are excluded first, exactly as the
    /// import excludes them, because an import carrying a failure deletes
    /// nothing at all.
    static func deletionPreview(
        _ entries: [CustomerJSON], in route: Route
    ) -> (names: [String], blockedByFailures: Bool) {
        var valid: [CustomerJSON] = []
        var anyFailed = false
        for e in entries {
            let kunde = e.kunde.trimmed
            let strasse = e.strasse.trimmed
            let plz = e.plz.trimmed
            guard !kunde.isEmpty, !strasse.isEmpty, !plz.isEmpty,
                  (try? validateCustomerFields(
                    kunde: kunde, strasse: strasse, paket: e.paket, notiz: e.notiz,
                    telefon: e.telefon)) != nil
            else {
                anyFailed = true
                continue
            }
            valid.append(
                CustomerJSON(
                    kunde: kunde, strasse: strasse, plz: plz,
                    paket: e.paket?.trimmed.nilIfEmpty, notiz: e.notiz?.trimmed.nilIfEmpty,
                    telefon: e.telefon?.trimmed.nilIfEmpty))
        }

        // A round with any failure in it deletes nothing — the import says so
        // itself — so there is nothing to warn about.
        guard !anyFailed else { return ([], true) }

        let existing = route.customerStops
        let matched = match(valid, against: existing).matched
        let names = existing
            .filter { !matched.contains($0.id) }
            .map { $0.kunde?.trimmed.nilIfEmpty ?? $0.listAddress.nilIfEmpty ?? "Stopp" }
        return (names, false)
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
