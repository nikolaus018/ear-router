import Compression
import Foundation
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "geocode")

/// Vienna's address register and its entrance points as they were when the app
/// was built — `Resources/WienAdressen.deflate`, made by
/// `Tools/MakeAddressPack.py`. What the geocoder asks instead of the city's
/// address service when that cannot be reached, so an outage the night before
/// a tour still places the stops at their doors rather than leaving them all
/// to Nominatim.
///
/// It answers in the service's own shape — `OGDFeature`s with a `Ranking` —
/// so everything the geocoder decides about an answer (the right Stiege, "≈"
/// for a neighbour, the wrong-district hint) is decided the same way for
/// both. What it cannot do is the service's fuzzy search: a street is found
/// by `AddressText.matchKey`, or one letter off it, and nothing looser.
///
/// Read the first time it is needed, not at launch: on a day the service is
/// up it is never read at all. A lock rather than an actor, so the geocoder
/// can ask it without another hop.
final class AddressPack: @unchecked Sendable {
    static let shared = AddressPack(load: AddressPack.bundled)

    struct Row: Sendable {
        /// "129/1", "17 Haus 1", "5-7 RINGSTRASSENGALERIEN".
        let number: String
        let plz: String
        let lat: Double
        let lon: Double
    }

    /// One street name as the register spells it, in every postcode it runs
    /// through.
    struct Street: Sendable {
        let name: String
        var addresses: [Row] = []
        var entrances: [Row] = []
    }

    struct Contents: Sendable {
        /// The day the file was made, "2026-10-31".
        let builtOn: String
        /// Keyed on `AddressText.matchKey` of the street name.
        let streets: [String: Street]
    }

    private let load: @Sendable () -> Contents?
    private let lock = NSLock()
    private var loaded: Contents??

    init(load: @escaping @Sendable () -> Contents?) {
        self.load = load
    }

    /// `nil` when the app has no pack, or it cannot be read.
    var contents: Contents? {
        lock.withLock {
            if let loaded { return loaded }
            let started = Date()
            let c = load()
            if let c {
                log.info("address pack read: \(c.streets.count) streets in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
            } else {
                log.error("address pack missing or unreadable")
            }
            loaded = .some(c)
            return c
        }
    }

    private static var bundledURL: URL? {
        Bundle.main.url(forResource: "WienAdressen", withExtension: "deflate")
    }

    private static func bundledText() -> String? {
        guard let url = bundledURL,
              let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .zlib) as Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func bundled() -> Contents? {
        bundledText().flatMap(parse)
    }

    /// "31.10.2026", for the Über screen: when the copy the app ships with was
    /// made. Only the header line is unpacked, not the twenty megabytes after
    /// it — this is read on the main thread, as the screen opens.
    static let bundledDate: String? = {
        guard let url = bundledURL, let packed = try? Data(contentsOf: url) else { return nil }
        var offset = 0
        guard let filter = try? InputFilter(.decompress, using: .zlib, readingFrom: { length in
                  let n = min(length, packed.count - offset)
                  defer { offset += n }
                  return n > 0 ? packed.subdata(in: offset..<offset + n) : nil
              }),
              let head = try? filter.readData(ofLength: 128),
              // Only up to the first newline: the 128 bytes can end halfway
              // through an umlaut in the street line after it, and a strict
              // decode of that fails the whole header.
              let line = head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).first,
              let text = String(data: Data(line), encoding: .utf8),
              let header = text.split(separator: "\t")
                .dropFirst(3).first
        else { return nil }
        let ymd = header.split(separator: "-")
        guard ymd.count == 3 else { return String(header) }
        return "\(ymd[2]).\(ymd[1]).\(ymd[0])"
    }()

    /// The file's text, as `MakeAddressPack.py` writes it. `nil` for anything
    /// that does not start with its header.
    static func parse(_ text: String) -> Contents? {
        var builtOn: String?
        var streets: [String: Street] = [:]
        // The file is sorted by street, so the key — a regex and a fold — is
        // worked out once per street rather than once per line.
        var lastName = ""
        var lastKey = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.first == "#" {
                guard parts.count >= 4, parts[1] == "WienAdressen" else { return nil }
                builtOn = String(parts[3])
                continue
            }
            guard builtOn != nil else { return nil }
            guard parts.count == 6,
                  let lat = Double(parts[4]), let lon = Double(parts[5])
            else { continue }
            let name = String(parts[1])
            if name != lastName {
                lastName = name
                lastKey = AddressText.matchKey(name)
            }
            let row = Row(number: String(parts[2]), plz: String(parts[3]), lat: lat, lon: lon)
            // Appended in place: taken out, appended to and put back, every
            // row copied its street's whole list.
            if parts[0] == "A" {
                streets[lastKey, default: Street(name: name)].addresses.append(row)
            } else {
                streets[lastKey, default: Street(name: name)].entrances.append(row)
            }
        }
        guard let builtOn else { return nil }
        return Contents(builtOn: builtOn, streets: streets)
    }

    // MARK: - Answering like the service

    /// What the address service would answer for `query` — "Gentzgasse
    /// 129/1", "Töllergasse 26A", "Gentzgasse 129" — across every district,
    /// as the service does. `nil` when there is no pack to ask.
    func registerAnswer(for query: String) -> [Geocoder.OGDFeature]? {
        guard let contents else { return nil }
        return Self.registerAnswer(for: query, in: contents)
    }

    /// The ranking follows the service's scale, which is what the geocoder
    /// reads it by: about 0 for the address asked for, a hair above that for
    /// the other doors of the same house, under 1 for a lettered neighbour
    /// ("8B" for "8") and in the hundreds for another number on the street.
    ///
    /// Every row of the street, not the best hundred: the wrong-district hint
    /// reads the postcodes of all of them, and a street through two districts
    /// cut down to its nearest numbers could show only one and send the stop
    /// to the wrong one.
    static func registerAnswer(
        for query: String, in contents: Contents
    ) -> [Geocoder.OGDFeature] {
        let normalized = AddressText.normalize(query)
        let streetPart = AddressText.streetNameOnly(normalized)
        let key = AddressText.matchKey(streetPart)
        var matched: [(Street, Double)] = contents.streets[key].map { [($0, 0)] } ?? []
        if matched.isEmpty {
            // The service's own slack for a typo, kept as narrow as
            // `pickFeature` takes it: one letter, on a long name.
            matched = contents.streets
                .filter { AddressText.isOneTypoApart($0.key, key) }
                .map { ($0.value, 0.0015) }
        }
        guard !matched.isEmpty else { return [] }

        let tail = String(normalized.dropFirst(streetPart.count)).trimmed
        let askedHead = head(tail)
        let askedDigits = askedHead.flatMap(Geocoder.entranceNumber).map(digits)
        let askedSub = AddressText.subAddressOf(normalized)

        var out: [Geocoder.OGDFeature] = []
        for (street, penalty) in matched {
            var bareHouses = Set<String>()
            for row in street.addresses {
                let adresse = "\(street.name) \(row.number)"
                let sub = AddressText.subAddressOf(adresse)
                let rowHead = head(row.number)
                if sub == nil, let rowHead { bareHouses.insert("\(rowHead)|\(row.plz)") }
                let rank = ranking(
                    rowHead: rowHead, rowSub: sub,
                    askedHead: askedHead, askedDigits: askedDigits, askedSub: askedSub)
                out.append(feature(street.name, row, adresse: adresse, ranking: rank + penalty))
            }
            // The register's download carries a house that has Stiegen only as
            // its Stiegen — "Gentzgasse 129/1", "129/2", never "129" itself,
            // which the service answers with a point of its own. The entrance
            // point stands in for it, for the number asked for.
            guard let askedHead else { continue }
            for row in street.entrances
            where head(row.number) == askedHead && !bareHouses.contains("\(askedHead)|\(row.plz)") {
                let adresse = "\(street.name) \(row.number)"
                let rank = askedSub == nil ? 0 : 0.0002
                out.append(feature(street.name, row, adresse: adresse, ranking: rank + penalty))
            }
        }
        return out.sorted { ($0.properties.ranking ?? 0) < ($1.properties.ranking ?? 0) }
    }

    private static func ranking(
        rowHead: String?, rowSub: String?,
        askedHead: String?, askedDigits: String?, askedSub: String?
    ) -> Double {
        guard let askedHead, let rowHead else { return 100 }
        if rowHead == askedHead {
            if rowSub == askedSub { return 0 }
            return askedSub == nil ? 0.0001 : 0.0002
        }
        let rowDigits = Geocoder.entranceNumber(rowHead).map(digits)
        if let rowDigits, rowDigits == askedDigits { return 0.5 }
        guard let a = askedDigits.flatMap({ Int($0) }), let b = rowDigits.flatMap({ Int($0) })
        else { return 1000 }
        // A range the number lies in is the building it is part of: asked for
        // "Heinrich-Collin-Straße 14" the service answers "8-14", and the
        // nearest number by arithmetic — 13, across the road — is 500 m off.
        // Still not the house asked for, so above 1.
        let range = rowHead.split(separator: "-")
        if range.count == 2, let low = Int(digits(String(range[0]))),
           let high = Int(digits(String(range[1]))), low...high ~= a {
            return 10
        }
        return 100 + Double(abs(a - b))
    }

    /// "129" of "129/1", "26a" of "26A Obj. 2", "5-7" of "5-7 RINGSTRASSENGALERIEN".
    private static func head(_ number: String) -> String? {
        let h = number.prefix { $0 != "/" && $0 != " " && $0 != "(" }.lowercased()
        return h.isEmpty ? nil : h
    }

    private static func digits(_ number: String) -> String {
        String(number.prefix { $0.isNumber })
    }

    private static func feature(
        _ street: String, _ row: Row, adresse: String, ranking: Double
    ) -> Geocoder.OGDFeature {
        Geocoder.OGDFeature(
            geometry: Geocoder.OGDGeometry(coordinates: [row.lon, row.lat]),
            properties: Geocoder.OGDProperties(
                streetName: street, postalCode: row.plz, kategorie: "Adresse",
                adresse: adresse, ranking: ranking, streetNumber: row.number))
    }

    // MARK: - Answering like the entrance layer

    /// What the entrance layer would answer for its `NAME LIKE 'street
    /// digits%' AND PLZ = plz` query. `nil` when there is no pack to ask.
    func entrances(street: String, number: String, plz: String) -> [Geocoder.EntranceFeature]? {
        guard let contents else { return nil }
        return Self.entrances(street: street, number: number, plz: plz, in: contents)
    }

    static func entrances(
        street: String, number: String, plz: String, in contents: Contents
    ) -> [Geocoder.EntranceFeature] {
        let prefix = digits(number)
        guard let found = contents.streets[AddressText.matchKey(street)] else { return [] }
        return found.entrances
            .filter { $0.plz == plz && $0.number.hasPrefix(prefix) }
            .map {
                Geocoder.EntranceFeature(
                    geometry: Geocoder.OGDGeometry(coordinates: [$0.lon, $0.lat]),
                    properties: Geocoder.EntranceProperties(number: $0.number, plz: $0.plz))
            }
    }
}
