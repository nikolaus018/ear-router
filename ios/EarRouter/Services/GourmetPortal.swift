import Foundation
import Security

/// The Zusteller-Portal (`zusteller.gourmet-daheim.at`) speaks to this backend
/// directly from the browser — there is no server of this app's own in
/// between, same as `Upstreams`. Reverse-engineered from that portal's own
/// network traffic: a login that hands back a bearer token, a list of
/// standing tours, and a paginated list of that day's deliveries.
///
/// The one surprise worth writing down: `/supplier/deliveries?tour_id=`
/// does not actually filter on the server — a request for one tour still
/// comes back with deliveries belonging to a dozen others. The portal's own
/// web app copes with this by filtering the page it already has, client-side,
/// against each delivery's `tours` list — so that is what `fetchTourEntries`
/// does too, rather than trusting the query parameter.
enum GourmetPortal {
    static let base = URL(string: "https://odoo.gourmet.at/api")!

    struct Credentials: Sendable, Equatable {
        var username: String
        var password: String
    }

    // MARK: - Wire types

    struct Tour: Decodable, Sendable, Identifiable, Hashable {
        var id: Int
        var name: String
        var catalogueType: String?
        var weekday: String?
        var weekdays: [String]

        enum CodingKeys: String, CodingKey {
            case id, name, weekday, weekdays
            case catalogueType = "catalogue_type"
        }
    }

    struct Address: Decodable, Sendable {
        var street: String?
        var street2: String?
        var staircase: String?
        var flatNumber: String?
        var zip: String?
        var city: String?
        var comment: String?

        enum CodingKeys: String, CodingKey {
            case street, street2, staircase, zip, city, comment
            case flatNumber = "flat_number"
        }
    }

    struct Customer: Decodable, Sendable {
        var firstname: String?
        var lastname: String?
        var comment: String?
    }

    struct TourRef: Decodable, Sendable {
        var id: Int
        var name: String
    }

    struct DeliveryLine: Decodable, Sendable {
        var name: String
        var quantity: Double
    }

    struct DeliveryBundle: Decodable, Sendable {
        var deliveryLines: [DeliveryLine]

        enum CodingKeys: String, CodingKey {
            case deliveryLines = "delivery_lines"
        }
    }

    /// The shape `/supplier/deliveries` and `/supplier/deliveries/{id}` share.
    /// `deliveryBundles` — the Paket — is only ever present on the detail
    /// call; the list is deliberately the short form.
    struct Delivery: Decodable, Sendable, Identifiable {
        var id: Int
        var state: String
        var customer: Customer
        var deliveryAddress: Address
        var tours: [TourRef]
        var deliveryBundles: [DeliveryBundle]?

        enum CodingKeys: String, CodingKey {
            case id, state, customer, tours
            case deliveryAddress = "delivery_address"
            case deliveryBundles = "delivery_bundles"
        }
    }

    struct DeliveryPage: Decodable, Sendable {
        var items: [Delivery]
        var page: Int
        var totalPages: Int

        enum CodingKeys: String, CodingKey {
            case items, page
            case totalPages = "total_pages"
        }
    }

    /// The states a stop still has to be driven in — done and cancelled ones
    /// are excluded, same as the portal's own "deliverable" filter.
    static let openStates = ["draft", "waiting", "confirmed", "assigned"]

    // MARK: - Requests

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private static func commonHeaders(_ request: inout URLRequest, token: String? = nil) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("de", forHTTPHeaderField: "Accept-Language")
        // Required by the backend on every call, browser or not — the same
        // fixed value the web app sends.
        request.setValue("5", forHTTPHeaderField: "sc-website-key")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "x-authorization")
        }
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.message("Keine Antwort vom Zusteller-Portal.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppError.message(loginFailureMessage(for: http.statusCode))
        }
    }

    private static func loginFailureMessage(for status: Int) -> String {
        switch status {
        case 401, 403:
            return "Anmeldung beim Zusteller-Portal fehlgeschlagen. Bitte Benutzername und "
                + "Passwort prüfen."
        default:
            return "Zusteller-Portal antwortet mit Fehler \(status)."
        }
    }

    /// Logs in and hands back the bearer token — good for a very long time
    /// (the portal itself issues tokens valid for months), but fetched fresh
    /// every time here rather than cached, so there is no separate token
    /// refresh path to get wrong.
    static func login(_ credentials: Credentials) async throws -> String {
        var request = URLRequest(url: base.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        commonHeaders(&request)

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
            URLQueryItem(name: "rememberMe", value: "true"),
            // Fixed values the portal's own login always sends, independent
            // of which brand's supplier is logging in.
            URLQueryItem(name: "host", value: "https://staging.essen-fuer-daheim.at"),
            URLQueryItem(name: "check_role", value: "supplier"),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response)

        struct LoginResponse: Decodable { var access_token: String }
        guard let decoded = try? decoder.decode(LoginResponse.self, from: data) else {
            throw AppError.message("Antwort des Zusteller-Portals nicht verstanden.")
        }
        return decoded.access_token
    }

    static func tours(token: String) async throws -> [Tour] {
        var request = URLRequest(url: base.appendingPathComponent("supplier/tours"))
        commonHeaders(&request, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response)
        guard let tours = try? decoder.decode([Tour].self, from: data) else {
            throw AppError.message("Tourenliste des Zusteller-Portals nicht verstanden.")
        }
        return tours
    }

    private static func deliveries(
        date: String, page: Int, pageSize: Int, token: String
    ) async throws -> DeliveryPage {
        var comps = URLComponents(
            url: base.appendingPathComponent("supplier/deliveries"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "delivery_date", value: date),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
        ]
        items.append(contentsOf: openStates.map { URLQueryItem(name: "state", value: $0) })
        comps.queryItems = items

        var request = URLRequest(url: comps.url!)
        commonHeaders(&request, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response)
        guard let page = try? decoder.decode(DeliveryPage.self, from: data) else {
            throw AppError.message("Lieferliste des Zusteller-Portals nicht verstanden.")
        }
        return page
    }

    private static func deliveryDetail(id: Int, token: String) async throws -> Delivery {
        var request = URLRequest(
            url: base.appendingPathComponent("supplier/deliveries/\(id)"))
        commonHeaders(&request, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkOK(response)
        guard let delivery = try? decoder.decode(Delivery.self, from: data) else {
            throw AppError.message("Lieferdaten des Zusteller-Portals nicht verstanden.")
        }
        return delivery
    }

    // MARK: - Tour selection

    /// Which of a tour's weekday fields decide whether it runs on `date` — a
    /// "day" catalogue tour is offered every weekday it lists, a "week" one
    /// only on its single fixed weekday. Mirrors the filter the portal's own
    /// tour picker applies.
    static func runs(_ tour: Tour, on date: Date) -> Bool {
        let day = germanWeekday(for: date)
        if tour.catalogueType == "day" { return tour.weekdays.contains(day) }
        return tour.weekday == day
    }

    static func germanWeekday(for date: Date) -> String {
        let names = [
            "sonntag", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag",
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna") ?? .current
        // `.weekday` is always 1 = Sunday … 7 = Saturday, regardless of the
        // calendar's own first-weekday setting.
        let index = calendar.component(.weekday, from: date) - 1
        return names[index]
    }

    private static func isoDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna") ?? .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 1)
    }

    private static let routeNameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_AT")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    /// A new route's name when it comes from a Gourmet tour rather than the
    /// "Neue Tour" prompt — the tour's own name, which is already how a
    /// driver picking it from the list a moment ago recognised it.
    static func suggestedRouteName(tour: Tour, date: Date) -> String {
        "\(tour.name) – \(routeNameDateFormatter.string(from: date))"
    }

    // MARK: - Fetching one tour's day

    /// Logs in, fetches every open delivery for `date`, keeps the ones
    /// belonging to `tour`, then fetches each one's detail for its Paket —
    /// one request per stop, since the list endpoint never carries it.
    static func fetchTourEntries(
        tour: Tour, date: Date, credentials: Credentials,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> [CustomerJSON] {
        onProgress("Anmelden …")
        let token = try await login(credentials)

        onProgress("Lieferungen werden geladen …")
        let dateString = isoDate(date)
        var all: [Delivery] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let result = try await deliveries(date: dateString, page: page, pageSize: 100, token: token)
            all.append(contentsOf: result.items)
            if page >= result.totalPages || result.items.isEmpty { break }
            page += 1
        }

        let matching = all.filter { delivery in delivery.tours.contains { $0.id == tour.id } }

        var entries: [CustomerJSON] = []
        for (index, delivery) in matching.enumerated() {
            try Task.checkCancellation()
            onProgress("Paket \(index + 1) von \(matching.count) wird geladen …")
            let detail = try await deliveryDetail(id: delivery.id, token: token)
            entries.append(customerJSON(from: detail))
        }
        return entries
    }

    // MARK: - Mapping to the app's own shape

    /// The same "{Straße} {Hausnummer}/{Stiege}/{Tür}" convention
    /// `AddressText` reads back out of a free-text address — built here from
    /// the portal's separate fields instead of parsed from one string.
    static func customerJSON(from delivery: Delivery) -> CustomerJSON {
        let address = delivery.deliveryAddress
        let name = [delivery.customer.firstname, delivery.customer.lastname]
            .compactMap { $0?.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        var strasse = address.street?.trimmed ?? ""
        let suffixes = [address.street2, address.staircase, address.flatNumber]
            .compactMap { $0?.trimmed }
            .filter { !$0.isEmpty }
        if !suffixes.isEmpty {
            // No space before the slash: "Gentzgasse 129/1/23", not
            // "Gentzgasse 129 1/23" — the housenumber is already the tail of
            // `street`, and this is the one delimiter `AddressText` actually
            // looks for when it reads a Stiege or Tür back out of the string.
            strasse += (strasse.isEmpty ? "" : "/") + suffixes.joined(separator: "/")
        }

        let notiz = [address.comment, delivery.customer.comment]
            .compactMap { $0?.trimmed }
            .first { !$0.isEmpty }

        return CustomerJSON(
            kunde: name, strasse: strasse, plz: address.zip?.trimmed ?? "",
            paket: paketText(from: delivery), notiz: notiz)
    }

    private static func paketText(from delivery: Delivery) -> String? {
        let lines = (delivery.deliveryBundles ?? []).flatMap(\.deliveryLines)
        guard !lines.isEmpty else { return nil }
        let parts = lines.map { line -> String in
            guard line.quantity != 1 else { return line.name }
            let quantity =
                line.quantity == line.quantity.rounded()
                ? String(Int(line.quantity)) : String(format: "%.2f", line.quantity)
            return "\(quantity)x \(line.name)"
        }
        return parts.joined(separator: ", ")
    }
}

/// The driver's Zusteller-Portal login, kept in the Keychain rather than
/// `UserDefaults` — it is a real password, not a preference.
enum GourmetCredentialsStore {
    private static let service = "at.essenfuerdaheim.EarRouter.zusteller-portal"
    private static let account = "supplier-login"

    static func load() -> GourmetPortal.Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return GourmetPortal.Credentials(username: stored.username, password: stored.password)
    }

    static func save(_ credentials: GourmetPortal.Credentials) {
        let stored = Stored(username: credentials.username, password: credentials.password)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct Stored: Codable {
        var username: String
        var password: String
    }
}
