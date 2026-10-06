import Foundation

/// The TK tours of the last few weeks as the portal has them, whole — both
/// halves of every split — written out as one JSON file.
///
/// For looking back: how a tour that two drivers shared was actually divided.
/// The app only ever shows a driver the open stops of today, and a driver's own
/// route holds only their half, so without this the other half of a past day is
/// gone. Run by the driver, from the login the app already has; nothing here
/// leaves the phone until the file is shared.
enum PortalDayExport {

    struct Entry: Codable, Equatable, Sendable {
        var id: Int
        var state: String
        var name: String
        var strasse: String
        var plz: String
        var notiz: String?
        var telefon: String?
    }

    struct Day: Codable, Equatable, Sendable {
        var date: String
        var tour: String
        var deliveries: [Entry]
    }

    struct Document: Codable, Equatable, Sendable {
        var exportedAt: Date
        var days: [Day]
    }

    /// "TK 1 DI Vormittag", "TK1", "tk 2 …" — spaces and case folded, so the
    /// tour's spelling does not decide whether it is exported.
    static func isTK(_ tourName: String) -> Bool {
        tourName.uppercased().filter { !$0.isWhitespace }.hasPrefix("TK")
    }

    /// Today and the `count - 1` days before it, newest first.
    static func days(back count: Int, from today: Date = Date()) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna") ?? .current
        return (0..<max(count, 0)).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    /// Logs in once, then asks for every TK tour that runs on each of the last
    /// `daysBack` days. A day nothing ran on, or that the portal no longer
    /// returns anything for, is simply absent.
    static func run(
        daysBack: Int, credentials: GourmetPortal.Credentials,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Document {
        onProgress("Anmelden …")
        let token = try await GourmetPortal.login(credentials)
        let tours = try await GourmetPortal.tours(token: token).filter { isTK($0.name) }
        var out: [Day] = []
        let dates = days(back: daysBack)
        for (index, date) in dates.enumerated() {
            for tour in tours where GourmetPortal.runs(tour, on: date) {
                try Task.checkCancellation()
                onProgress("Tag \(index + 1) von \(dates.count) …")
                let deliveries = try await GourmetPortal.allDeliveries(
                    tour: tour, date: date, token: token)
                guard !deliveries.isEmpty else { continue }
                let entries = deliveries.map { d -> Entry in
                    let (name, address) = GourmetPortal.summary(d)
                    let json = GourmetPortal.customerJSON(from: d)
                    return Entry(
                        id: d.id, state: d.state, name: name, strasse: address,
                        plz: d.deliveryAddress.zip?.trimmed ?? "",
                        notiz: json.notiz?.trimmed.nilIfEmpty, telefon: json.telefon)
                }
                out.append(Day(date: GourmetPortal.isoDate(date), tour: tour.name, deliveries: entries))
            }
        }
        return Document(exportedAt: Date(), days: out)
    }

    /// The document as a file the share sheet can hand on.
    static func write(_ document: Document) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TK-Export-\(GourmetPortal.isoDate(document.exportedAt)).json")
        try encoder.encode(document).write(to: url, options: .atomic)
        return url
    }
}
