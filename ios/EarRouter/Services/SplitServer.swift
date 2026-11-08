import Foundation

/// The split server at ear-split-api.ringtwo.win (`split-server/` in this
/// repository): one phone sends a person's part of a split tour, another
/// lists the day's parts and loads one as its tour.
///
/// A part is the JSON `SplitState.serverPart` writes, and the same file
/// "Als JSON senden" shares — the tour, and each person's stops with the
/// customer's name and address, nothing else:
///
///     {"tour": "VM 5 FR Vormittag",
///      "persons": [{"person": 1, "stops": [{"address": "…", "name": "…"}]}]}
///
/// The day travels beside it, as `?date=` on the upload. Paket, phone and
/// note are not in it: the phone that loads a part takes them from its own
/// Zusteller-Portal login — see `portalEntries`.
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

    /// One stop: the customer and the address. `plz` is read if another
    /// sender includes one, and never written — it is not in the format.
    struct Stop: Codable, Sendable, Hashable {
        var name: String
        var address: String
        var plz: String? = nil
    }

    struct Person: Codable, Sendable, Hashable {
        var person: Int?
        var stops: [Stop]
    }

    struct Part: Codable, Sendable, Hashable {
        var tour: String
        var persons: [Person]

        var stops: [Stop] { persons.flatMap(\.stops) }

        /// The stops as import entries: name and address, and a postcode only
        /// where one came along. `portalEntries` fills in the rest.
        var entries: [CustomerJSON] {
            stops.map {
                CustomerJSON(
                    kunde: $0.name.trimmed, strasse: $0.address.trimmed,
                    plz: $0.plz?.trimmed ?? "", paket: nil, notiz: nil)
            }
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

    /// `day` is "2026-11-06", the day the tour is driven.
    static func upload(_ body: Data, day: String) async throws -> Summary {
        try await call("POST", "/api/parts?date=\(day)", body: body)
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

    /// The parts already on the server for `stored`'s tour, day and person,
    /// other than `stored` itself, deleted — so sending a person again
    /// replaces what was there, whichever phone or which split sent it.
    /// Best effort and quiet: returns how many went, and a failure here
    /// never forgets the key or spoils the send that just worked.
    @discardableResult
    static func deleteOlder(than stored: Summary) async -> Int {
        struct Answer: Decodable { let parts: [Summary] }
        guard let answer: Answer = try? await call(
            "GET", "/api/parts?date=\(stored.date)", forgetKeyOnRejection: false)
        else { return 0 }
        let tour = AddressText.matchKey(stored.tour)
        var gone = 0
        for old in answer.parts
        where old.id != stored.id && old.person == stored.person
            && AddressText.matchKey(old.tour) == tour
        {
            struct OK: Decodable { let ok: Bool }
            let done: OK? = try? await call(
                "DELETE", "/api/parts/\(old.id)", forgetKeyOnRejection: false)
            if done != nil { gone += 1 }
        }
        return gone
    }

    /// The server's error shape: `{"detail": "…"}`, in German.
    private struct Problem: Decodable { let detail: String }

    private static func call<T: Decodable>(
        _ method: String, _ path: String, body: Data? = nil, forgetKeyOnRejection: Bool = true
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
            if status == 401, forgetKeyOnRejection {
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
        /// Positions of stops the portal has, but no longer open: "cancel"
        /// (abbestellt) or "done" (schon geliefert) — by position, the state.
        var closed: [Int: String] = [:]

        /// One line for the top of the review, or `nil` when every stop came
        /// from the portal.
        func notice(tour: String, day: String?) -> String? {
            let fromSender = "Es kommen nur Name und Adresse — ohne Paket und Telefon, die PLZ bitte je Stopp eintragen."
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
                let off = missing.count + noDetail.count + closed.count
                guard off > 0 else { return nil }
                var parts: [String] = []
                let cancelled = closed.values.count { $0 == "cancel" }
                let done = closed.count - cancelled
                if cancelled > 0 {
                    parts.append(cancelled == 1
                        ? "1 Kunde ist im Zusteller-Portal abbestellt"
                        : "\(cancelled) Kunden sind im Zusteller-Portal abbestellt")
                }
                if done > 0 {
                    parts.append(done == 1
                        ? "1 Kunde ist im Zusteller-Portal schon erledigt"
                        : "\(done) Kunden sind im Zusteller-Portal schon erledigt")
                }
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
                let what = missing.isEmpty && noDetail.isEmpty
                    ? " — markiert, nach links wischen zum Entfernen."
                    : ". Markiert — dort nur Name und Adresse."
                return parts.joined(separator: ", ") + what
            }
        }

        /// The mark on one row, or `nil` for a stop the portal answered for.
        func hint(at index: Int) -> String? {
            if outcome != .checked { return nil }  // said once, at the top
            if let state = closed[index] {
                return state == "cancel"
                    ? "Im Zusteller-Portal abbestellt — wohl nicht anfahren"
                    : "Im Zusteller-Portal schon erledigt — wohl nicht anfahren"
            }
            if missing.contains(index) { return "Nicht im Zusteller-Portal — nur Name und Adresse" }
            if noDetail.contains(index) { return "Portal hat nicht geantwortet — ohne Paket und Telefon" }
            return nil
        }
    }

    /// A loaded part's stops as import entries, with Paket, parcel count,
    /// phone and note taken from this phone's own Zusteller-Portal login —
    /// the same detail call "Als Tour anlegen" makes — rather than trusting
    /// a part that carries only names and addresses. Name and address stay
    /// the part's — the sender may have corrected an address, and that is
    /// where the meal goes — and the postcode is the portal's.
    ///
    /// Never throws: whatever the portal cannot answer for keeps what the
    /// part carried (and is left for the driver to give a postcode on
    /// Prüfen), and `PortalResult` says which and why. Only
    /// cancellation stops it, and then it returns the part as it came.
    static func portalEntries(
        for part: Part, day dayString: String,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> PortalResult {
        let fallback = part.entries
        guard let credentials = GourmetCredentialsStore.load() else {
            return PortalResult(entries: fallback, outcome: .noLogin)
        }
        let day = date(of: dayString) ?? Date()
        let token: String
        let tour: GourmetPortal.Tour
        let deliveries: [GourmetPortal.Delivery]
        do {
            onProgress("Zusteller-Portal: anmelden …")
            token = try await GourmetPortal.login(credentials)
            let wanted = AddressText.matchKey(part.tour)
            guard let found = try await GourmetPortal.tours(token: token)
                .first(where: { AddressText.matchKey($0.name) == wanted })
            else { return PortalResult(entries: fallback, outcome: .tourNotFound) }
            tour = found
            onProgress("Zusteller-Portal: Lieferungen werden geladen …")
            deliveries = try await GourmetPortal.deliveries(of: found, on: day, token: token)
        } catch is CancellationError {
            return PortalResult(entries: fallback, outcome: .unreachable("abgebrochen"))
        } catch {
            let why = (error as? AppError)?.message ?? "keine Verbindung"
            return PortalResult(entries: fallback, outcome: .unreachable(why))
        }
        // Who is no longer open — cancelled or already delivered — asked only
        // when something did not match: a customer the office cancelled after
        // the part was sent must not read like a lookup that failed.
        func closedDeliveries() async -> [GourmetPortal.Delivery] {
            (try? await GourmetPortal.deliveries(
                of: tour, on: day, token: token, states: GourmetPortal.closedStates)) ?? []
        }
        func candidates(_ list: [GourmetPortal.Delivery]) -> [Candidate] {
            list.map { d in
                let (name, address) = GourmetPortal.summary(d)
                return Candidate(id: d.id, name: name, address: address,
                                 plz: d.deliveryAddress.zip?.trimmed ?? "")
            }
        }
        guard !deliveries.isEmpty else {
            var result = PortalResult(entries: fallback, outcome: .noDeliveries)
            let closed = await closedDeliveries()
            if !closed.isEmpty {
                result.outcome = .checked
                let states = Dictionary(closed.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
                for (i, pick) in match(part.stops, to: candidates(closed)).enumerated() {
                    if let pick, let state = states[pick] { result.closed[i] = state } else { result.missing.insert(i) }
                }
            }
            return result
        }

        let picks = match(part.stops, to: candidates(deliveries))
        let byID = Dictionary(deliveries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wantedDeliveries = picks.compactMap { $0 }.compactMap { byID[$0] }
        // A detail call that fails leaves that stop out; a whole fetch that
        // throws (cancelled) leaves them all — either way they are marked.
        let details = wantedDeliveries.isEmpty ? [:] : ((try? await GourmetPortal.fetchEachDetail(
            for: wantedDeliveries, token: token, credentials: credentials
        ) { done, total in onProgress("Paket \(done) von \(total) wird geladen …") }) ?? [:])

        var result = PortalResult(entries: fallback, outcome: .checked)
        let unmatched = picks.indices.filter { picks[$0] == nil }
        if !unmatched.isEmpty {
            let closed = await closedDeliveries()
            let states = Dictionary(closed.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            let again = match(unmatched.map { part.stops[$0] }, to: candidates(closed))
            for (k, i) in unmatched.enumerated() {
                if let pick = again[k], let state = states[pick] { result.closed[i] = state }
            }
        }
        for (i, pick) in picks.enumerated() {
            guard let pick else {
                if result.closed[i] == nil { result.missing.insert(i) }
                continue
            }
            // The list already has the postcode, even when the detail fails.
            if result.entries[i].plz.isEmpty, let zip = byID[pick]?.deliveryAddress.zip?.trimmed {
                result.entries[i].plz = zip
            }
            guard let detail = details[pick] else { result.noDetail.insert(i); continue }
            var out = result.entries[i]
            // The format carries no postcode; the portal's is the delivery's own.
            if out.plz.isEmpty { out.plz = detail.plz }
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
