import Foundation
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "geocode")

/// A resolved address.
struct GeocodeResult: Sendable {
    let lat: Double
    let lon: Double
    let displayName: String
    let precision: Precision
}

/// Turns "Gentzgasse 129/1" + "1180" into coordinates.
///
/// Vienna's own address register is tried first (`data.wien.gv.at`) — the
/// city's ground-truth building register, not community-mapped OSM data, so it
/// covers real, currently-occupied addresses that Nominatim sometimes has not
/// caught up on. Nominatim stays as the fallback for anything it does not
/// recognize. An address neither can find falls through to manual pin-drop.
///
/// An actor because of the Nominatim throttle: the usage policy is one request
/// per second from a *client*, and a bulk import firing thirty concurrent
/// lookups would blow straight through it.
actor Geocoder {
    static let shared = Geocoder()

    /// Nominatim's usage policy: at most ~1 request/second from one client,
    /// enforced here rather than trusting every call site to remember.
    private static let nominatimMinInterval: TimeInterval = 1.1
    private var nominatimLast: Date?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 25
        c.httpAdditionalHeaders = ["User-Agent": upstreamUserAgent]
        return URLSession(configuration: c)
    }()

    // MARK: - Entry point

    /// The full cascade, in the order each strategy can place the van most
    /// precisely. Throws `AppError` with a `.wrongDistrict` recovery when the
    /// register knows the address but files it under a different postcode —
    /// which is by far the likeliest reason a lookup fails, and turns a vague
    /// pin into a one-tap fix.
    func geocode(strasse: String, plz: String) async throws -> GeocodeResult {
        let originalQuery = "\(strasse.trimmed), \(plz) Wien, Österreich"
        // Cached on the *normalized* form, not the raw input: "Hauptstr. 5",
        // "Hauptstrasse 5" and "Hauptstraße  5" are one address written three
        // ways and all resolve identically, so keying on the raw text would
        // pay a throttled round trip again for each spelling.
        let normalized = AddressText.normalize(strasse)
        let key = "\(normalized.lowercased()), \(plz) wien, österreich"

        if let hit = await GeocodeCache.shared.lookup(key) {
            // A cached *district centroid* is the app admitting it never found
            // this address — and the likeliest reason is that the district it
            // was filed under is wrong. Worth one unthrottled register call to
            // say so, because otherwise the cache keeps that vague pin (and
            // the mystery behind it) alive for the whole TTL. Exact and
            // street-level hits are served straight from the cache, so this
            // costs nothing on the common path.
            if hit.precision == .district,
               let actual = await districtHint(normalized: normalized, plz: plz) {
                throw AppError.wrongDistrict(strasse.trimmed, actualPlz: actual)
            }
            return GeocodeResult(
                lat: hit.lat, lon: hit.lon,
                displayName: hit.displayName, precision: hit.precision)
        }

        // A recent, definitive "no geocoder has this address" — skip straight
        // to the same error the full lookup would have produced several
        // seconds and four throttled round trips from now.
        if await GeocodeCache.shared.isKnownMiss(key) {
            throw AppError.notFound(originalQuery)
        }

        if let hit = await wienOGDGeocode(strasse: strasse, plz: plz) {
            await GeocodeCache.shared.store(
                key, lat: hit.lat, lon: hit.lon,
                displayName: hit.displayName, precision: hit.precision)
            return hit
        }

        // The register did not have this address in the district it was filed
        // under. Before spending throttled Nominatim calls — and before ending
        // up at a district-centre pin the driver cannot explain — ask the
        // register the same question without the district.
        if let actual = await districtHint(normalized: normalized, plz: plz) {
            log.info("address exists in a different district: \(plz) → \(actual)")
            throw AppError.wrongDistrict(strasse.trimmed, actualPlz: actual)
        }

        // Try the "{street} {housenumber}" form first — Viennese addresses are
        // routinely written with a Stiege/Tür/Stock suffix that Nominatim does
        // not index and will otherwise just fail to match on. Only fall back
        // to the fuller normalized string (an extra throttled call) if that
        // finds nothing.
        let simplified = AddressText.simplifyHousenumber(normalized)
        let wantedStreet = AddressText.matchKey(AddressText.streetNameOnly(normalized))

        var result = try await nominatimSearchOne(
            query: "\(simplified), \(plz) Wien, Österreich",
            wantedStreet: wantedStreet, plz: plz)

        if result == nil, simplified != normalized {
            result = try await nominatimSearchOne(
                query: "\(normalized), \(plz) Wien, Österreich",
                wantedStreet: wantedStreet, plz: plz)
        }

        // Last resort: the street itself was not found at all (a typo, or a
        // street too new for OSM) but the postal code is real — a coarse
        // district-centroid pin rather than rejecting the address outright.
        // Honest about being coarse (surfaced to the driver as "≈, double
        // check this one"), but it lets a route with one bad address save
        // instead of blocking the other 29.
        if result == nil {
            result = try await districtCentroid(plz: plz)
        }

        guard let result else {
            // Every strategy ran and every one answered "no such address" — a
            // definitive negative (an unreachable geocoder would have thrown
            // long before here), so it is safe to remember.
            await GeocodeCache.shared.recordMiss(key)
            throw AppError.notFound(originalQuery)
        }

        await GeocodeCache.shared.store(
            key, lat: result.lat, lon: result.lon,
            displayName: result.displayName, precision: result.precision)
        return result
    }

    // MARK: - Vienna OGD

    /// Tries, in order of how precisely each form can place the van:
    /// 1. `"{street} {number}/{sub-address}"` when the address carries a
    ///    Stiege, Parzelle or Top — the register knows that staircase's or
    ///    plot's own door, tens to hundreds of metres from what the bare
    ///    housenumber answers to. Accepted only if the register really
    ///    matched that sub-address.
    /// 2. The simplified `"{street} {number}"`. If the address *did* carry a
    ///    sub-address, an answer for somebody else's is downgraded to
    ///    `.street` rather than passed off as the right door.
    /// 3. The fuller normalized string, for an address that was never
    ///    "street + number" to begin with and which simplifying would only
    ///    have mangled.
    ///
    /// Unlike the Nominatim path, these are unthrottled calls to a service
    /// with no published rate limit, so trying the most precise form first
    /// costs a few hundred milliseconds on the addresses that have a
    /// sub-address and nothing at all on the ones that do not.
    private func wienOGDGeocode(strasse: String, plz: String) async -> GeocodeResult? {
        let normalized = AddressText.normalize(strasse)
        let simplified = AddressText.simplifyHousenumber(normalized)
        let sub = AddressText.housenumberWithSub(normalized)

        if let sub {
            if let hit = await ogdSearchOne(
                query: sub.query, plz: plz, subCheck: .require(sub.key)) {
                return hit
            }
        }

        let fallbackCheck: SubCheck = sub.map { .downgrade($0.key) } ?? .absent

        if let hit = await ogdSearchOne(
            query: simplified, plz: plz, subCheck: fallbackCheck) {
            return hit
        }
        if simplified != normalized,
           let hit = await ogdSearchOne(
            query: normalized, plz: plz, subCheck: fallbackCheck) {
            return hit
        }
        return nil
    }

    /// What the caller knows about the address's sub-address, and how strictly
    /// the register's answer has to honour it.
    private enum SubCheck {
        /// No sub-address; anything the register returns for the housenumber
        /// is as precise as this address gets.
        case absent
        /// Accept *only* an answer carrying this sub-address. Used for the
        /// first attempt, the one that can actually place the van at the right
        /// staircase or plot.
        case require(String)
        /// Accept whatever the register returns, but if it carries a
        /// *different* sub-address, the point is a neighbour rather than the
        /// address asked for — precise-looking, and wrong. Downgraded to
        /// `.street` so the app shows its "≈" warning instead of presenting a
        /// guess as a confirmed door.
        case downgrade(String)

        var required: String? {
            if case .require(let s) = self { return s }
            return nil
        }

        func isWrongNeighbour(_ adresse: String?) -> Bool {
            guard case .downgrade(let want) = self,
                  let adresse,
                  let got = AddressText.subAddressOf(adresse)
            else { return false }
            return got != want
        }
    }

    private func ogdSearchOne(
        query: String, plz: String, subCheck: SubCheck
    ) async -> GeocodeResult? {
        guard let features = await ogdFetch(query) else { return nil }
        let ourStreet = AddressText.streetNameOnly(query).lowercased()
        guard let best = Self.pickFeature(
            features, plz: plz, streetLower: ourStreet, requireSub: subCheck.required)
        else { return nil }

        let props = best.properties
        let ranking = props.ranking ?? .greatestFiniteMagnitude
        let precision: Precision

        if props.kategorie == "Straßenname" {
            precision = .street
        } else if subCheck.isWrongNeighbour(props.adresse) {
            // The register knows this housenumber, but only as somebody else's
            // staircase or garden plot. Same street, same number, different
            // door — reported as the approximation it is.
            log.debug("OGD matched a neighbouring sub-address, downgrading to street precision")
            precision = .street
        } else if ranking < 1.0 {
            // A genuine housenumber (and usually Stiege/Parzelle/Tür) match.
            precision = .exact
        } else {
            // A real street, but the exact housenumber was not registered —
            // matched to the nearest one instead.
            precision = .street
        }

        guard best.geometry.coordinates.count == 2 else { return nil }
        let lon = best.geometry.coordinates[0]
        let lat = best.geometry.coordinates[1]
        // `crs=EPSG:4326` is requested, but a service that ever ignored it
        // would hand back projected metres that look nothing like degrees —
        // fall through to Nominatim rather than storing a point in the middle
        // of the ocean as a confident "exact" match.
        guard Coordinates.isPlausible(lat: lat, lon: lon) else {
            log.warning("OGD returned out-of-range coordinates, ignoring")
            return nil
        }

        let displayName = props.adresse.map { "\($0), \(plz) Wien" } ?? "\(query), \(plz) Wien"
        return GeocodeResult(
            lat: lat, lon: lon, displayName: displayName, precision: precision)
    }

    /// Picks the one usable feature out of an OGD response.
    ///
    /// Candidates are *filtered first, ranked second*, and the order matters:
    /// the postcode must match exactly and the returned street name must be
    /// the street we actually asked for, because a query with no real match —
    /// a typo, or a genuinely unregistered street — still comes back
    /// populated, with the closest *different* street sometimes carrying a
    /// deceptively low `Ranking`. Only once those checks have thrown out
    /// everything that is not the requested address does `Ranking` decide, and
    /// only among what is left: its scale is not uniform across match types
    /// (an exact hit is ~0, "same street, wrong housenumber" jumps to the
    /// hundreds), so it can order candidates but must never be what selects
    /// one.
    ///
    /// Ranking before filtering throws away correct answers: OGD returns
    /// several features for one query, and if the single best-ranked one is in
    /// a neighbouring district, the whole lookup reports "not found" even
    /// though the right address was sitting in the same response.
    private static func pickFeature(
        _ features: [OGDFeature], plz: String, streetLower: String, requireSub: String?
    ) -> OGDFeature? {
        features
            .filter { $0.properties.postalCode == plz }
            .filter {
                ($0.properties.streetName ?? "").trimmed.lowercased() == streetLower
            }
            // A sub-address query only counts if the register came back with
            // *that* sub-address. Asked for one it has never heard of, the
            // service answers with a neighbour at a near-zero `Ranking` —
            // which would otherwise be accepted as an exact match and quietly
            // point the driver at the wrong staircase, or the wrong garden
            // plot 130 m down the lane. Compared through `subAddressOf` rather
            // than as raw text, because the register writes what the driver
            // typed as "9/Parz.68" as "Großfeldstraße 9 Parz. 68" — the same
            // address, spelled with a space and an abbreviation dot.
            .filter { f in
                guard let want = requireSub else { return true }
                guard let adresse = f.properties.adresse,
                      let got = AddressText.subAddressOf(adresse)
                else { return false }
                return got == want
            }
            .min {
                ($0.properties.ranking ?? .greatestFiniteMagnitude)
                    < ($1.properties.ranking ?? .greatestFiniteMagnitude)
            }
    }

    /// One raw OGD lookup: the request and the parse. Returns `nil` — never
    /// throws — for every flavour of "no usable answer", which is what lets
    /// the caller treat the register as a first attempt rather than a hard
    /// dependency. An outage the night before a route is due degrades to the
    /// Nominatim pipeline, not to a failure.
    private func ogdFetch(_ query: String) async -> [OGDFeature]? {
        var comps = URLComponents(url: Upstreams.current.wienOGD, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "Address", value: query),
            URLQueryItem(name: "crs", value: "EPSG:4326"),
        ]
        guard let url = comps?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                log.warning("Wien OGD error status, falling back to Nominatim")
                return nil
            }
            // A query with zero matches comes back as an HTTP 200 with a
            // completely empty body (not `{"features":[]}`) — has to be
            // checked before handing an empty string to the JSON parser.
            guard !data.isEmpty else { return nil }
            return try JSONDecoder().decode(OGDFeatureCollection.self, from: data).features
        } catch {
            log.warning("Wien OGD unreachable or unparseable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Which Vienna district the register actually files this street+number
    /// under, when the answer is unambiguous.
    ///
    /// Deliberately narrow: it asks the same question `wienOGDGeocode` just
    /// asked, minus the postcode filter, and speaks up only when *every*
    /// candidate for the requested street agrees on one postcode that is not
    /// the one the stop was entered with. A street that genuinely runs through
    /// several districts yields several postcodes and no hint at all —
    /// guessing between them would be worse than the honest approximate pin
    /// the caller otherwise falls back to.
    private func districtHint(normalized: String, plz: String) async -> String? {
        let simplified = AddressText.simplifyHousenumber(normalized)
        let ourStreet = AddressText.matchKey(AddressText.streetNameOnly(simplified))
        guard let features = await ogdFetch(simplified) else { return nil }

        var postcodes = Set<String>()
        for f in features {
            guard let name = f.properties.streetName,
                  AddressText.matchKey(name) == ourStreet
            else { continue }
            if let code = f.properties.postalCode { postcodes.insert(code) }
        }
        guard postcodes.count == 1, let only = postcodes.first, only != plz else {
            return nil
        }
        return only
    }

    // MARK: - Nominatim

    /// Serializes calls to at most one every `nominatimMinInterval`, holding
    /// callers rather than letting concurrent lookups burst past the policy.
    private func throttleNominatim() async {
        if let last = nominatimLast {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < Self.nominatimMinInterval {
                try? await Task.sleep(for: .seconds(Self.nominatimMinInterval - elapsed))
            }
        }
        nominatimLast = Date()
    }

    private func nominatimRawSearch(_ query: String) async throws -> NominatimHit? {
        await throttleNominatim()

        var comps = URLComponents(
            url: Upstreams.current.nominatim, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "countrycodes", value: "at"),
        ]
        guard let url = comps?.url else { throw AppError.geocoderUnavailable }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                log.error("Nominatim error status")
                throw AppError.geocoderUnavailable
            }
            return try JSONDecoder().decode([NominatimHit].self, from: data).first
        } catch let e as AppError {
            throw e
        } catch {
            // The underlying error text describes our networking, not anything
            // the driver can act on — logged, never shown.
            log.error("Nominatim unreachable: \(error.localizedDescription)")
            throw AppError.geocoderUnavailable
        }
    }

    /// Does a Nominatim hit actually describe the address we asked for?
    ///
    /// Nominatim's free-text search always returns *something* plausible.
    /// Without these checks the fallback could — and did — accept the right
    /// street name in the wrong district (Vienna has a "Hauptstraße" in
    /// several, and the postcode in the query is a hint, not a filter), or a
    /// different street entirely matched by string similarity ("Gentzstraße"
    /// for "Gentzgasse") — exactly the confident, precise, wrong answer the
    /// OGD check exists to reject.
    ///
    /// Absent fields are not failures: a hit with no `road` cannot be verified
    /// against a street, and is only ever accepted as `.district` anyway.
    private static func hitMatches(
        _ hit: NominatimHit, wantedStreet: String, plz: String
    ) -> Bool {
        guard let address = hit.address else { return true }
        if let postcode = address.postcode?.trimmed, postcode != plz {
            log.debug("Nominatim hit is in a different district, ignoring")
            return false
        }
        if let road = address.road, AddressText.matchKey(road) != wantedStreet {
            log.debug("Nominatim hit is a different street, ignoring")
            return false
        }
        return true
    }

    private func nominatimSearchOne(
        query: String, wantedStreet: String, plz: String
    ) async throws -> GeocodeResult? {
        guard let top = try await nominatimRawSearch(query) else { return nil }
        guard Self.hitMatches(top, wantedStreet: wantedStreet, plz: plz) else { return nil }
        guard let lat = Double(top.lat), let lon = Double(top.lon) else {
            throw AppError.message("Geocoding-Dienst: ungültige Koordinaten in der Antwort")
        }
        // Nominatim's search is fuzzy and country-wide (`countrycodes=at` is
        // as narrow as it gets): a Viennese street name that also exists in
        // Graz or Linz can come back as a confident top hit hundreds of
        // kilometres away. Treat anything outside the Vienna box as no match,
        // so the caller falls through to its next strategy instead of pinning
        // a stop in the wrong federal state.
        guard Coordinates.isPlausible(lat: lat, lon: lon) else {
            log.warning("Nominatim hit outside the Vienna area, ignoring")
            return nil
        }

        let precision: Precision
        if top.address?.houseNumber != nil {
            precision = .exact
        } else if top.address?.road != nil {
            precision = .street
        } else {
            precision = .district
        }
        return GeocodeResult(
            lat: lat, lon: lon, displayName: top.displayName, precision: precision)
    }

    /// The coarse fallback pin. Only fires for a *genuinely recognized*
    /// postal code: Nominatim is a fuzzy free-text search, so "{garbage} Wien,
    /// Österreich" does not reliably come back empty for a bogus or foreign
    /// PLZ — it can match on "Wien" alone and hand back central Vienna,
    /// silently. Requiring Nominatim's own structured `postcode` to equal what
    /// we asked for is what actually tells a real Vienna PLZ apart from that.
    private func districtCentroid(plz: String) async throws -> GeocodeResult? {
        guard let hit = try await nominatimRawSearch("\(plz) Wien, Österreich") else {
            return nil
        }
        guard hit.address?.postcode == plz,
              let lat = Double(hit.lat), let lon = Double(hit.lon),
              Coordinates.isPlausible(lat: lat, lon: lon)
        else { return nil }

        return GeocodeResult(
            lat: lat, lon: lon,
            displayName: "\(plz) Wien (nur Bezirk, Adresse unbekannt)",
            precision: .district)
    }

    // MARK: - Wire types

    private struct OGDFeatureCollection: Decodable {
        var features: [OGDFeature] = []
    }
    private struct OGDFeature: Decodable {
        let geometry: OGDGeometry
        let properties: OGDProperties
    }
    private struct OGDGeometry: Decodable {
        /// `[lon, lat]`.
        let coordinates: [Double]
    }
    private struct OGDProperties: Decodable {
        let streetName: String?
        let postalCode: String?
        let kategorie: String?
        let adresse: String?
        let ranking: Double?

        enum CodingKeys: String, CodingKey {
            case streetName = "StreetName"
            case postalCode = "PostalCode"
            case kategorie = "Kategorie"
            case adresse = "Adresse"
            case ranking = "Ranking"
        }
    }

    private struct NominatimHit: Decodable {
        let lat: String
        let lon: String
        let displayName: String
        let address: NominatimAddress?

        enum CodingKeys: String, CodingKey {
            case lat, lon, address
            case displayName = "display_name"
        }
    }
    private struct NominatimAddress: Decodable {
        let houseNumber: String?
        let road: String?
        let postcode: String?

        enum CodingKeys: String, CodingKey {
            case road, postcode
            case houseNumber = "house_number"
        }
    }
}
