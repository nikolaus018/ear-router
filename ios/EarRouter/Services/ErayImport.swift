import Foundation

/// A whole tour as Eray's planner writes it out — and the customers out of
/// it, which is all this takes. It is a whole plan — where to
/// start, where to finish, which stop comes third — and every part of that
/// plan except the customers themselves belongs to this app already.
///
/// Everything past this file is the import every other source uses: the
/// entries go to `ImportReviewView` to be looked over, and `RouteStore`
/// geocodes, matches and writes them. So a stop from a document and a stop
/// from the portal are the same stop, and the delete protection, the
/// re-import matching and the Ladeliste all behave identically whichever one
/// the driver used this morning.
///
/// What the document carries and this deliberately ignores:
///
/// - `start`/`end`. A route here always starts at the depot, calls at the
///   Lager and comes back — `RouteStore.createRoute` sets all three, and they
///   are not the document's to move.
/// - `order`. Read, so the list can be shown in a settled order rather than
///   an arbitrary one, but not the tour's sequence: `RouteOptimizer` decides
///   that, from the real road network, the way it does for every other
///   import.
/// - `latitude`/`longitude`. Every address is looked up the app's own way
///   instead. Someone else's coordinates would arrive with no precision to
///   judge them by and no entrance, and the register lookup is what puts a
///   stop at the Stiege's own front door rather than the block's centre. The
///   cache means a re-imported list pays for none of it twice.
/// - `priority`, `readyAt`, `deliveryType`, `deliveryDate`. This app routes by
///   driving, not by time windows.
/// - `referenceNumber`, `customerNumber`, `sourceStop`. The office's handles
///   for a delivery; nothing on this side has anywhere to put them.
enum ErayImport {

    // MARK: - Wire shape

    struct Document: Decodable, Sendable {
        /// "VM 1 MO Vormittag · 21.09.2026 · Teil 2/2" — what a tour created
        /// from this document is called.
        var tourName = ""
        var deliveries: [Delivery] = []

        private enum CodingKeys: String, CodingKey { case tourName, deliveries }

        init(tourName: String = "", deliveries: [Delivery] = []) {
            self.tourName = tourName
            self.deliveries = deliveries
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tourName = text(c, .tourName)
            deliveries = try c.decodeIfPresent([Delivery].self, forKey: .deliveries) ?? []
        }
    }

    /// One delivery, read leniently on every field.
    ///
    /// The document comes out of somebody else's tool: a `postalCode` written
    /// as a number rather than a string, a key simply absent, a `quantity`
    /// that changed type between versions. None of that may cost the driver
    /// the other twenty-four stops. What cannot be read becomes empty, and an
    /// empty required field is a warning on that row in Prüfen — where it
    /// costs one tap to fix — rather than a decode error naming nothing.
    struct Delivery: Decodable, Sendable {
        /// The planner's own sequence, 1-based. Optional: a document that
        /// leaves it out is taken to be in order already.
        var order: Int?
        var customerName = ""
        /// "Marktgemeindegasse 44-50/3/8" — the composed line, which is
        /// already the convention the rest of the app reads addresses in.
        var address = ""
        var street = ""
        var houseNumber = ""
        var stairway = ""
        var floor = ""
        var apartment = ""
        var postalCode = ""
        var phone = ""
        /// "1 × Vitalmenü EP TGM5". Passed through as the Paket verbatim —
        /// `PaketParser` already counts both "2x" and "2 ×", so the
        /// Ladeliste adds these up without anything being rewritten here.
        var product = ""
        var notes = ""

        private enum CodingKeys: String, CodingKey {
            case order, customerName, address, street, houseNumber, stairway, floor
            case apartment, postalCode, phone, product, notes
        }

        init(
            order: Int? = nil, customerName: String = "", address: String = "",
            street: String = "", houseNumber: String = "", stairway: String = "",
            floor: String = "", apartment: String = "", postalCode: String = "",
            phone: String = "", product: String = "", notes: String = ""
        ) {
            self.order = order
            self.customerName = customerName
            self.address = address
            self.street = street
            self.houseNumber = houseNumber
            self.stairway = stairway
            self.floor = floor
            self.apartment = apartment
            self.postalCode = postalCode
            self.phone = phone
            self.product = product
            self.notes = notes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order = try? c.decodeIfPresent(Int.self, forKey: .order)
            customerName = text(c, .customerName)
            address = text(c, .address)
            street = text(c, .street)
            houseNumber = text(c, .houseNumber)
            stairway = text(c, .stairway)
            floor = text(c, .floor)
            apartment = text(c, .apartment)
            postalCode = text(c, .postalCode)
            phone = text(c, .phone)
            product = text(c, .product)
            notes = text(c, .notes)
        }
    }

    // MARK: - Reading a pasted document

    /// `nonisolated` for the same reason `RouteStore.parseImport` is: this is
    /// a pure decode, and nothing about it needs the main actor.
    nonisolated static func parse(_ text: String) throws -> Document {
        guard let data = text.data(using: .utf8) else { throw notADocument }
        let decoder = JSONDecoder()

        var document: Document
        if let d = try? decoder.decode(Document.self, from: data) {
            document = d
        } else if let bare = try? decoder.decode([Delivery].self, from: data) {
            // Just the `deliveries` array, pasted out of the middle of a
            // document. Worth accepting: it is one plausible slip, and the
            // only thing lost is the tour's name.
            document = Document(deliveries: bare)
        } else {
            throw notADocument
        }

        guard !document.deliveries.isEmpty else {
            throw AppError.message("Diese Eray-Liste enthält keine Lieferungen.")
        }
        return document
    }

    private static var notADocument: AppError {
        AppError.message(
            "Das ist keine Eray-Liste — erwartet wird ein JSON-Objekt mit „deliveries“.")
    }

    // MARK: - Mapping to the app's own shape

    /// The document's deliveries as customer entries.
    static func entries(from document: Document) -> [CustomerJSON] {
        ordered(document.deliveries).map(entry)
    }

    /// The reading order for Prüfen, and only that — what the tour is
    /// actually driven in is the optimizer's answer, taken after the stops
    /// are written.
    ///
    /// By `order` where the document gives one, by position where it does
    /// not — and by position between two stops claiming the same number, so
    /// a driver checking the list against the planner's own screen sees the
    /// same sequence every time. A document whose array is already sequenced
    /// (every one seen so far) comes back untouched.
    static func ordered(_ deliveries: [Delivery]) -> [Delivery] {
        deliveries.enumerated()
            .sorted { ($0.element.order ?? .max, $0.offset) < ($1.element.order ?? .max, $1.offset) }
            .map(\.element)
    }

    static func entry(_ delivery: Delivery) -> CustomerJSON {
        CustomerJSON(
            kunde: delivery.customerName,
            strasse: streetLine(delivery),
            plz: delivery.postalCode,
            paket: delivery.product.nilIfEmpty,
            notiz: delivery.notes.nilIfEmpty,
            telefon: delivery.phone.nilIfEmpty)
    }

    /// The "{Straße} {Hausnummer}/{Stiege}/{Stock}/{Tür}" line Vienna is
    /// written in and `AddressText` reads back — see its `housenumber`.
    ///
    /// `address` already holds exactly that, so it is taken as it stands.
    /// Composing from the separate fields is the fallback for a document that
    /// left it out, and it is the same assembly `GourmetPortal.streetLine`
    /// does from the portal's own separate fields, down to there being no
    /// space before the slash.
    static func streetLine(_ delivery: Delivery) -> String {
        if !delivery.address.isEmpty { return delivery.address }
        var line = [delivery.street, delivery.houseNumber]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let suffixes = [delivery.stairway, delivery.floor, delivery.apartment]
            .filter { !$0.isEmpty }
        if !suffixes.isEmpty {
            line += (line.isEmpty ? "" : "/") + suffixes.joined(separator: "/")
        }
        return line
    }

    /// What a tour created from this document is called.
    ///
    /// Empty when the document carries no name — `RouteStore.createRoute`
    /// falls back to its own dated default for that, and it is better at it
    /// than this is.
    static func routeName(for document: Document, taken: Set<String> = []) -> String {
        let base = String(document.tourName.trimmed.prefix(FieldLimits.routeName))
        guard !base.isEmpty, taken.contains(base) else { return base }
        // A counted suffix rather than the date `GourmetPortal` appends: the
        // tour's name here already ends in one, and "… 21.09.2026 –
        // 21.09.2026" reads like a mistake.
        for n in 2...99 where !taken.contains("\(base) (\(n))") { return "\(base) (\(n))" }
        return base
    }
}

/// A string, however the document happened to write it. A number where a
/// string was expected is the one type surprise a generator actually
/// produces, and a postcode is the field it produces it on.
private func text<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ key: Key) -> String {
    // `try?` flattens the optional the decode already returns, so each of
    // these binds only where the key is present *and* holds that type.
    if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s.trimmed }
    if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
    // Bounded before the conversion: `Int(_:)` traps on a Double too large to
    // hold, and this is a field somebody else's generator fills.
    if let d = try? c.decodeIfPresent(Double.self, forKey: key), d.magnitude < 1e15 {
        return d == d.rounded() ? String(Int(d)) : String(d)
    }
    return ""
}
