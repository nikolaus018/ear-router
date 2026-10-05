import Foundation

/// The list of toilets in use: the one the app shipped with, until a newer
/// one has been fetched — see `RestroomUpdater`.
///
/// A lock rather than an actor: the map reads this on every frame of a pan,
/// from a view body, and cannot wait for it.
final class RestroomCatalog: @unchecked Sendable {
    static let shared = RestroomCatalog()

    struct Contents: Sendable {
        let all: [Restroom]
        let pins: [RestroomPin]
        let pinsByID: [UUID: RestroomPin]
        /// When the list was fetched. `nil` for the one the app shipped with.
        let updatedAt: Date?

        init(_ all: [Restroom], updatedAt: Date?) {
            self.all = all
            self.pins = all.map { RestroomPin(id: UUID(), restroom: $0, key: $0.key) }
            self.pinsByID = Dictionary(pins.map { ($0.id, $0) }) { first, _ in first }
            self.updatedAt = updatedAt
        }
    }

    private let lock = NSLock()
    private var contents: Contents

    var current: Contents { lock.withLock { contents } }

    private init() {
        contents = Self.fetched() ?? Contents(Self.bundled(), updatedAt: nil)
    }

    /// Puts a freshly fetched list in use and keeps it for the next launch.
    func replace(with rows: [Restroom], at date: Date = Date()) throws {
        let data = try JSONEncoder().encode(rows)
        try FileManager.default.createDirectory(
            at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: Self.file, options: .atomic)
        lock.withLock { contents = Contents(rows, updatedAt: date) }
    }

    private static let file = URL.applicationSupportDirectory.appending(path: "Restrooms.json")

    private static func fetched() -> Contents? {
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([Restroom].self, from: data), !rows.isEmpty
        else { return nil }
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Contents(rows, updatedAt: date)
    }

    private static func bundled() -> [Restroom] {
        guard let url = Bundle.main.url(forResource: "Restrooms", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([Restroom].self, from: data)
        else { return [] }
        return rows
    }
}

/// Fetches the toilets again from the two places they come from — what
/// `Tools/MakeRestrooms.py` does at a desk, done on the phone. The same rules,
/// and they are that file's to explain: no pissoirs, no staffed toilets —
/// those are the ones that charge — and none whose opening hours cannot be
/// read as a plain timetable.
enum RestroomUpdater {
    static let city = URL(string:
        "https://data.wien.gv.at/daten/geo?service=WFS&request=GetFeature&version=1.1.0"
            + "&typeName=ogdwien:WCANLAGEOGD&srsName=EPSG:4326&outputFormat=json")!
    static let oeklo = URL(string:
        "https://d90ejx0yw4gor.cloudfront.net/public-toilet-map/toilets.json")!

    /// Fetches both lists and puts them in use. Returns how many toilets
    /// there are now. Throws, and leaves the list as it was, when either
    /// source cannot be read or comes back implausibly short.
    @discardableResult
    static func refresh() async throws -> Int {
        async let cityData = fetch(city)
        async let oekloData = fetch(oeklo)
        let cityRows = try parseCity(await cityData)
        let oekloRows = try parseOeklo(await oekloData)
        // Half a list is a feed having a bad day, not a city that closed
        // its toilets.
        guard cityRows.count >= 100, oekloRows.count >= 100 else {
            throw AppError.message("Die WC-Daten sind unvollständig angekommen. Bitte später noch einmal.")
        }

        // The walk from the road is asked of OSRM only for a toilet that is
        // new: the rest have theirs, and five hundred requests for a number
        // that does not change is no way to treat a home server.
        let known = Dictionary(
            RestroomCatalog.shared.current.all.map { ($0.key, $0.walk) }) { first, _ in first }
        var rows: [Restroom] = []
        for draft in cityRows + oekloRows {
            var row = draft
            if let walk = known[draft.key] {
                row = draft.with(walk: walk)
            } else if let metres = try? await OSRMClient.shared.snapDistance(
                lat: draft.lat, lon: draft.lon)
            {
                row = draft.with(walk: Int(metres.rounded()))
            }
            rows.append(row)
        }
        rows.sort { ($0.name, $0.lat) < ($1.name, $1.lat) }
        try RestroomCatalog.shared.replace(with: rows)
        return rows.count
    }

    // MARK: - Reading the two lists

    static func parseCity(_ data: Data) throws -> [Restroom] {
        try JSONDecoder().decode(Collection<CityProperties>.self, from: data).features
            .compactMap { feature in
                let p = feature.properties
                let kind = p.KATEGORIE ?? ""
                guard kind != "Pissoir", !kind.contains("mit Wartepersonal"),
                      let point = feature.point,
                      let parsed = hours(p.OEFFNUNGSZEIT ?? "")
                else { return nil }
                let name = tidy([p.STRASSE, p.ONR?.text].compactMap { $0 }.joined(separator: " "))
                guard !name.isEmpty else { return nil }
                return Restroom(
                    name: name, lat: point.lat, lon: point.lon, walk: 0, hours: parsed.table,
                    winterClosed: parsed.winterClosed ? true : nil, oeklo: nil)
            }
    }

    static func parseOeklo(_ data: Data) throws -> [Restroom] {
        try JSONDecoder().decode(Collection<OekloProperties>.self, from: data).features
            .compactMap { feature in
                guard let point = feature.point else { return nil }
                let name = tidy(feature.properties.address)
                    .replacingOccurrences(of: #",\s*Wien$"#, with: "", options: .regularExpression)
                guard !name.isEmpty else { return nil }
                return Restroom(
                    name: name, lat: point.lat, lon: point.lon, walk: 0, hours: nil,
                    winterClosed: nil, oeklo: true)
            }
    }

    /// The city's free-text opening hours as a table of minutes per weekday,
    /// Monday first — `nil` for the table when the toilet never closes, and
    /// `nil` altogether when the text is not a plain timetable.
    static func hours(_ text: String) -> (table: [[Int]?]?, winterClosed: Bool)? {
        var t = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let winter = t.contains("wintersperre")
        t = String(t.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
            .replacingOccurrences(of: "uhr", with: " ")
        guard t.range(of: "jan|feb|mär|apr|mai|jun|jul|aug|sep|okt|nov|dez", options: .regularExpression)
            == nil
        else { return nil }

        var table: [[Int]?] = Array(repeating: nil, count: 7)
        var rest = t
        let whole = NSRange(t.startIndex..., in: t)
        for match in part.matches(in: t, range: whole) {
            func group(_ i: Int) -> String? {
                Range(match.range(at: i), in: t).map { String(t[$0]) }
            }
            guard let from = group(1).flatMap({ days.firstIndex(of: $0) }),
                  let open = group(3).flatMap(Int.init), let close = group(5).flatMap(Int.init)
            else { continue }
            let to = group(2).flatMap { days.firstIndex(of: $0) } ?? from
            let span = [
                open * 60 + (group(4).flatMap(Int.init) ?? 0),
                close * 60 + (group(6).flatMap(Int.init) ?? 0),
            ]
            if from <= to { for day in from...to { table[day] = span } }
            if let matched = group(0) { rest = rest.replacingOccurrences(of: matched, with: "") }
        }
        // Anything left over that is not punctuation is a rule this cannot
        // read — "Lokalöffnungszeiten", "Gesperrt".
        guard table.contains(where: { $0 != nil }),
              rest.allSatisfy({ $0.isWhitespace || $0 == "," || $0 == "+" })
        else { return nil }
        return (table.allSatisfy { $0 == [0, 1440] } ? nil : table, winter)
    }

    /// One space between words and none around them: both lists carry names
    /// with a stray double space, and a name is half of `Restroom.key`.
    private static func tidy(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let days = ["mo", "di", "mi", "do", "fr", "sa", "so"]
    private static let part = try! NSRegularExpression(
        pattern: #"(mo|di|mi|do|fr|sa|so)(?:\s*-\s*(mo|di|mi|do|fr|sa|so))?\s*:?\s*"#
            + #"(\d{1,2})(?:[.:](\d{2}))?\s*-\s*(\d{1,2})(?:[.:](\d{2}))?"#)

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(upstreamUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError.message("Die WC-Daten konnten nicht geladen werden.")
        }
        return data
    }

    // MARK: - Wire types

    private struct Collection<P: Decodable>: Decodable {
        let features: [Feature<P>]
    }
    private struct Feature<P: Decodable>: Decodable {
        let geometry: Geometry?
        let properties: P

        /// GeoJSON is `[lon, lat]`. Rounded as the bundled file is, and
        /// dropped when it is not a place in Austria.
        var point: (lat: Double, lon: Double)? {
            guard let c = geometry?.coordinates, c.count >= 2 else { return nil }
            let lat = (c[1] * 1e6).rounded() / 1e6, lon = (c[0] * 1e6).rounded() / 1e6
            return Coordinates.isPlausible(lat: lat, lon: lon) ? (lat, lon) : nil
        }
    }
    private struct Geometry: Decodable {
        let coordinates: [Double]
    }
    private struct CityProperties: Decodable {
        let STRASSE: String?
        let ONR: Loose?
        let OEFFNUNGSZEIT: String?
        let KATEGORIE: String?
    }
    private struct OekloProperties: Decodable {
        let address: String
    }
    /// A house number the register sends as text or as a number.
    private struct Loose: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                text = s
            } else if let i = try? c.decode(Int.self) {
                text = String(i)
            } else {
                text = ""
            }
        }
    }
}

private extension Restroom {
    func with(walk: Int) -> Restroom {
        Restroom(
            name: name, lat: lat, lon: lon, walk: walk, hours: hours,
            winterClosed: winterClosed, oeklo: oeklo)
    }
}
