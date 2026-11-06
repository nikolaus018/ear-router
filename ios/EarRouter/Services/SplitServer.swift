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

    struct Stop: Codable, Sendable, Hashable {
        var name: String
        var address: String
        var plz: String?
        var stockwerk: String?
        var notiz: String?
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

        /// The stops as import entries. The Globale Infos are not in them —
        /// they belong to the customer, not to today's stop; see `infos`.
        var entries: [CustomerJSON] {
            stops.map {
                CustomerJSON(
                    kunde: $0.name.trimmed, strasse: $0.address.trimmed,
                    plz: $0.plz?.trimmed ?? "", paket: nil, notiz: nil)
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
