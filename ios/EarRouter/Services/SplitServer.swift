import Foundation

/// The split server at ear-split-api.ringtwo.win (`split-server/` in this
/// repository): one phone sends a person's part of a split tour, another
/// lists the day's parts and loads one as its tour.
///
/// A part is the JSON `SplitState.serverPart` writes — the tour, the day and
/// one person's stops, each with the customer's Globale Infos where the
/// sending phone had any.
///
/// Every call carries an API key, made by the admin in the server's web UI
/// and typed in once on this phone. The parts hold customers' names and
/// addresses, and the URL is public.
enum SplitServer {
    static let baseURL = URL(string: "https://ear-split-api.ringtwo.win")!
    static let keyDefaultsKey = "splitServerKey"

    static var key: String? {
        UserDefaults.standard.string(forKey: keyDefaultsKey)?.trimmed.nilIfEmpty
    }

    // MARK: The part

    /// `stockwerk` and `notiz` are the customer's Globale Infos; `paket`,
    /// `pakete`, `telefon` and `lieferhinweis` are today's delivery — what the
    /// Ladeliste and "Anrufen" need on the phone that loads the part.
    struct Stop: Codable, Sendable, Hashable {
        var name: String
        var address: String
        var plz: String?
        var stockwerk: String?
        var notiz: String?
        var paket: String?
        var pakete: Int?
        var telefon: String?
        var lieferhinweis: String?
    }

    struct Person: Codable, Sendable, Hashable {
        var person: Int?
        var stops: [Stop]
    }

    struct Part: Codable, Sendable, Hashable {
        var tour: String
        var date: String?
        var persons: [Person]

        var stops: [Stop] { persons.flatMap(\.stops) }

        /// The stops as import entries, with today's Paket, phone and note.
        /// The Globale Infos are not in them — they belong to the customer,
        /// not to today's stop; see `infos`.
        var entries: [CustomerJSON] {
            stops.map {
                CustomerJSON(
                    kunde: $0.name.trimmed, strasse: $0.address.trimmed,
                    plz: $0.plz?.trimmed ?? "", paket: $0.paket?.trimmed.nilIfEmpty,
                    notiz: $0.lieferhinweis?.trimmed.nilIfEmpty,
                    telefon: $0.telefon?.trimmed.nilIfEmpty, paketCount: $0.pakete)
            }
        }

        /// What the sender knew about each customer, by `StockwerkKey`.
        var infos: [String: CustomerInfo] {
            var out: [String: CustomerInfo] = [:]
            for s in stops {
                let info = CustomerInfo(stockwerk: s.stockwerk, notiz: s.notiz)
                guard !info.isBlank,
                    let key = StockwerkKey.make(kunde: s.name, strasse: s.address, plz: s.plz)
                else { continue }
                out[key] = info
            }
            return out
        }
    }

    /// One stored part, as the list shows it.
    struct Summary: Codable, Sendable, Hashable, Identifiable {
        let id: Int
        let tour: String
        let date: String
        let person: Int?
        let stops: Int
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case id, tour, date, person, stops
            case createdAt = "created_at"
        }

        var title: String {
            person.map { "\(tour) · P\($0)" } ?? tour
        }
    }

    // MARK: Calls

    static func upload(_ body: Data) async throws -> Summary {
        try await call("POST", "/api/parts", body: body)
    }

    /// The parts of the last `days` days, newest first.
    static func list(days: Int = 30) async throws -> [Summary] {
        struct Answer: Decodable { let parts: [Summary] }
        let answer: Answer = try await call("GET", "/api/parts?days=\(days)")
        return answer.parts
    }

    static func part(_ id: Int) async throws -> Part {
        struct Answer: Decodable { let part: Part }
        let answer: Answer = try await call("GET", "/api/parts/\(id)")
        return answer.part
    }

    static func delete(_ id: Int) async throws {
        struct Answer: Decodable { let ok: Bool }
        let _: Answer = try await call("DELETE", "/api/parts/\(id)")
    }

    /// The server's error shape: `{"detail": "…"}`, in German.
    private struct Problem: Decodable { let detail: String }

    private static func call<T: Decodable>(
        _ method: String, _ path: String, body: Data? = nil
    ) async throws -> T {
        guard let key else {
            throw AppError.message("Für den Split-Server fehlt der API-Schlüssel.")
        }
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw AppError.message("Ungültige Adresse.")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppError.message("Der Split-Server ist nicht erreichbar.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 {
                // Forgotten, so the next send or load asks for it again
                // instead of failing the same way until it is found in a menu.
                UserDefaults.standard.removeObject(forKey: keyDefaultsKey)
                throw AppError.message("Der API-Schlüssel für den Split-Server stimmt nicht – bitte neu eingeben.")
            }
            let detail = (try? JSONDecoder().decode(Problem.self, from: data))?.detail
            throw AppError.message(detail ?? "Der Split-Server antwortet mit Fehler \(status).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AppError.message("Die Antwort des Split-Servers ist nicht lesbar.")
        }
    }

    // MARK: Days

    /// "2026-11-06", the day in Vienna.
    static func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func date(of day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Vienna")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - The portal's own word on a loaded part

extension SplitServer {
    /// What the portal said about a loaded part — enough for the review
    /// screen to tell the driver which Paket, phone and note came from the
    /// portal and which only from the sending phone.
    struct PortalResult: Sendable {
        enum Outcome: Sendable, Equatable {
            /// The portal answered; see `missing` and `noDetail` for stops it
            /// could not help with.
            case checked
            /// This phone has no Zusteller-Portal login.
            case noLogin
            /// Login or list failed — the portal's own message.
            case unreachable(String)
            /// No tour of the part's name on the portal.
            case tourNotFound
            /// The tour exists but has no open deliveries that day.
            case noDeliveries
        }

        var entries: [CustomerJSON]
        var outcome: Outcome
        /// Positions of stops the portal's list for that day does not have.
        var missing: Set<Int> = []
        /// Positions of stops found, but whose detail call did not answer.
        var noDetail: Set<Int> = []

        /// One line for the top of the review, or `nil` when every stop came
        /// from the portal.
        func notice(tour: String, day: String?) -> String? {
            let fromSender = "Paket, Telefon und Hinweis kommen vom sendenden Telefon — bitte prüfen."
            let when = day.flatMap(SplitServer.date(of:))
                .map { " am " + $0.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()) } ?? ""
            switch outcome {
            case .noLogin:
                return "Auf diesem Telefon ist kein Zusteller-Portal-Login gespeichert. " + fromSender
            case .unreachable(let why):
                return "Zusteller-Portal nicht erreichbar (\(why)). " + fromSender
            case .tourNotFound:
                return "„\(tour)“ gibt es im Zusteller-Portal nicht. " + fromSender
            case .noDeliveries:
                return "„\(tour)“ hat im Zusteller-Portal\(when) keine offenen Lieferungen. " + fromSender
            case .checked:
                let off = missing.count + noDetail.count
                guard off > 0 else { return nil }
                var parts: [String] = []
                if !missing.isEmpty {
                    parts.append(missing.count == 1
                        ? "1 Kunde ist im Zusteller-Portal nicht zu finden"
                        : "\(missing.count) Kunden sind im Zusteller-Portal nicht zu finden")
                }
                if !noDetail.isEmpty {
                    parts.append(noDetail.count == 1
                        ? "für 1 Kunden hat das Portal nicht geantwortet"
                        : "für \(noDetail.count) Kunden hat das Portal nicht geantwortet")
                }
                return parts.joined(separator: ", ") + ". Dort steht, was das sendende Telefon wusste — markiert."
            }
        }

        /// The mark on one row, or `nil` for a stop the portal answered for.
        func hint(at index: Int) -> String? {
            if outcome != .checked { return nil }  // said once, at the top
            if missing.contains(index) { return "Nicht im Zusteller-Portal — Angaben vom Absender" }
            if noDetail.contains(index) { return "Portal hat nicht geantwortet — Angaben vom Absender" }
            return nil
        }
    }

    /// A loaded part's stops as import entries, with Paket, parcel count,
    /// phone and note taken from this phone's own Zusteller-Portal login —
    /// the same detail call "Als Tour anlegen" makes — rather than trusting
    /// whatever the sending phone knew. Name, address and PLZ stay the
    /// part's: the sender may have corrected an address, and that is where
    /// the meal goes.
    ///
    /// Never throws: whatever the portal cannot answer for keeps what the
    /// part carried, and `PortalResult` says which and why. Only
    /// cancellation stops it, and then it returns the part as it came.
    static func portalEntries(
        for part: Part, onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> PortalResult {
        let fallback = part.entries
        guard let credentials = GourmetCredentialsStore.load() else {
            return PortalResult(entries: fallback, outcome: .noLogin)
        }
        let day = part.date.flatMap(date(of:)) ?? Date()
        let token: String
        let deliveries: [GourmetPortal.Delivery]
        do {
            onProgress("Zusteller-Portal: anmelden …")
            let login = try await GourmetPortal.login(credentials)
            let wanted = AddressText.matchKey(part.tour)
            guard let tour = try await GourmetPortal.tours(token: login)
                .first(where: { AddressText.matchKey($0.name) == wanted })
            else { return PortalResult(entries: fallback, outcome: .tourNotFound) }
            (token, deliveries) = try await GourmetPortal.matchingDeliveries(
                tour: tour, date: day, credentials: credentials
            ) { _ in onProgress("Zusteller-Portal: Lieferungen werden geladen …") }
        } catch is CancellationError {
            return PortalResult(entries: fallback, outcome: .unreachable("abgebrochen"))
        } catch {
            let why = (error as? AppError)?.message ?? "keine Verbindung"
            return PortalResult(entries: fallback, outcome: .unreachable(why))
        }
        guard !deliveries.isEmpty else {
            return PortalResult(entries: fallback, outcome: .noDeliveries)
        }

        let candidates = deliveries.map { d in
            let (name, address) = GourmetPortal.summary(d)
            return Candidate(id: d.id, name: name, address: address,
                             plz: d.deliveryAddress.zip?.trimmed ?? "")
        }
        let picks = match(part.stops, to: candidates)
        let byID = Dictionary(deliveries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wantedDeliveries = picks.compactMap { $0 }.compactMap { byID[$0] }
        // A detail call that fails leaves that stop out; a whole fetch that
        // throws (cancelled) leaves them all — either way they are marked.
        let details = wantedDeliveries.isEmpty ? [:] : ((try? await GourmetPortal.fetchEachDetail(
            for: wantedDeliveries, token: token, credentials: credentials
        ) { done, total in onProgress("Paket \(done) von \(total) wird geladen …") }) ?? [:])

        var result = PortalResult(entries: fallback, outcome: .checked)
        for (i, pick) in picks.enumerated() {
            guard let pick else { result.missing.insert(i); continue }
            guard let detail = details[pick] else { result.noDetail.insert(i); continue }
            var out = fallback[i]
            out.paket = detail.paket ?? fallback[i].paket
            out.paketCount = detail.paketCount ?? fallback[i].paketCount
            out.telefon = detail.telefon ?? fallback[i].telefon
            out.notiz = detail.notiz ?? fallback[i].notiz
            result.entries[i] = out
        }
        return result
    }

    /// A portal delivery as the list shows it.
    struct Candidate: Sendable, Equatable {
        let id: Int
        let name: String
        let address: String
        let plz: String
    }

    /// Which delivery each stop is, by position — `nil` for one the portal
    /// does not have. Name and address first, the way the sender's split
    /// wrote them from the very same list; then the name alone within the
    /// postcode, for a stop whose address the sender corrected. Each
    /// delivery is taken once, so two households at one door stay two.
    static func match(_ stops: [Stop], to candidates: [Candidate]) -> [Int?] {
        func key(_ s: String) -> String { AddressText.matchKey(s) }
        var free = candidates
        var out = [Int?](repeating: nil, count: stops.count)
        func take(_ i: Int, where test: (Candidate) -> Bool, unique: Bool) {
            let hits = free.indices.filter { test(free[$0]) }
            guard let first = hits.first, !unique || hits.count == 1 else { return }
            out[i] = free[first].id
            free.remove(at: first)
        }
        for (i, s) in stops.enumerated() {
            let name = key(s.name), street = AddressText.matchKey(s.address)
            take(i, where: { key($0.name) == name && AddressText.matchKey($0.address) == street },
                 unique: false)
        }
        for (i, s) in stops.enumerated() where out[i] == nil {
            let name = key(s.name), plz = s.plz?.trimmed ?? ""
            guard !name.isEmpty else { continue }
            take(i, where: { key($0.name) == name && (plz.isEmpty || $0.plz == plz) }, unique: true)
        }
        return out
    }
}
