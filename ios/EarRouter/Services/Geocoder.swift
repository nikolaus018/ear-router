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
/// Only for a Vienna postcode, though. A tour that runs past the Stadtgrenze
/// — Gerasdorf, Schwechat, Klosterneuburg — is geocoded by Nominatim alone,
/// because the city register has never heard of those streets and asking it
/// costs three round trips to be told so.
///
/// An actor because of the Nominatim throttle: the usage policy is one request
/// per second from a *client*, and a bulk import firing thirty concurrent
/// lookups would blow straight through it.
actor Geocoder {
    static let shared = Geocoder()

    /// Nominatim's usage policy: at most ~1 request/second from one client,
    /// enforced here rather than trusting every call site to remember.
    private static let nominatimMinInterval: TimeInterval = 1.1
    /// The earliest a *future* call may go out — a reservation, not a record of
    /// the last one. See `throttleNominatim`.
    private var nominatimNextSlot = Date.distantPast

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
        // "1210 Wien, Österreich" inside the city, "2201 Österreich" outside
        // it. Not cosmetic: Nominatim's search is fuzzy and "Wien" is a strong
        // enough token to carry a query on its own, so a Gerasdorf address
        // asked for with "Wien" on the end came back as a confident pin in
        // Vienna. See `Postcodes.placeSuffix`.
        let place = Postcodes.placeSuffix(for: plz)
        let originalQuery = "\(strasse.trimmed), \(place)"
        // Cached on the *normalized* form, not the raw input: "Hauptstr. 5",
        // "Hauptstrasse 5" and "Hauptstraße  5" are one address written three
        // ways and all resolve identically, so keying on the raw text would
        // pay a throttled round trip again for each spelling.
        let normalized = AddressText.normalize(strasse)
        let key = "\(normalized.lowercased()), \(place.lowercased())"

        if let hit = await GeocodeCache.shared.lookup(key) {
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

        // Checked between phases, and checked at all because two of them —
        // `wienOGDGeocode` and `districtHint` — answer `nil` rather than
        // throwing when a call fails. A cancelled lookup would otherwise walk
        // straight past them into the throttled Nominatim calls it was
        // cancelled to avoid.
        // Both register phases are skipped outside the city. `data.wien.gv.at`
        // is the *city's* building register: it has never heard of Gerasdorf,
        // so asking is three round trips that can only answer "no" — and
        // `districtHint`, which asks the register the same question without
        // the postcode, would answer them with whichever Viennese street
        // happens to share the name.
        // Whether the register could not be asked at all. Then whatever
        // Nominatim answers is only standing in for it: used, but not
        // remembered — cached as exact, it was served for good, and the
        // register's own Stiege-precise answer was never asked for again once
        // it was back up. Nor is "nobody has it" a verdict worth keeping.
        var registerUnreachable = false
        if Postcodes.isVienna(plz) {
            try Task.checkCancellation()
            let register = await wienOGDGeocode(strasse: strasse, plz: plz)
            if let hit = register.hit {
                await GeocodeCache.shared.store(
                    key, lat: hit.lat, lon: hit.lon,
                    displayName: hit.displayName, precision: hit.precision)
                return hit
            }
            registerUnreachable = register.unreachable

            // The register did not have this address in the district it was
            // filed under. Before spending throttled Nominatim calls — and
            // before ending up at a district-centre pin the driver cannot
            // explain — ask the register the same question without the
            // district.
            try Task.checkCancellation()
            if !registerUnreachable,
               let actual = await districtHint(normalized: normalized, plz: plz) {
                log.info("address exists in a different district: \(plz) → \(actual)")
                throw AppError.wrongDistrict(strasse.trimmed, actualPlz: actual)
            }
        }

        // Try the "{street} {housenumber}" form first — Viennese addresses are
        // routinely written with a Stiege/Tür/Stock suffix that Nominatim does
        // not index and will otherwise just fail to match on. Only fall back
        // to the fuller normalized string (an extra throttled call) if that
        // finds nothing.
        let simplified = AddressText.simplifyHousenumber(normalized)
        let wantedStreet = AddressText.matchKey(AddressText.streetNameOnly(normalized))

        try Task.checkCancellation()
        var result = try await nominatimSearchOne(
            query: "\(simplified), \(place)",
            wantedStreet: wantedStreet, plz: plz)

        if result == nil, simplified != normalized {
            result = try await nominatimSearchOne(
                query: "\(normalized), \(place)",
                wantedStreet: wantedStreet, plz: plz)
        }

        // Last resort: the street itself was not found at all (a typo, or a
        // street too new for OSM) but the postal code is real — a coarse
        // district-centroid pin rather than rejecting the address outright.
        // Honest about being coarse (surfaced to the driver as "≈, double
        // check this one"), but it lets a route with one bad address save
        // instead of blocking the other 29.
        if result == nil {
            try Task.checkCancellation()
            result = try await districtCentroid(plz: plz)
        }

        guard let result else {
            // Every strategy ran and every one answered "no such address" — a
            // definitive negative (an unreachable geocoder would have thrown
            // long before here), so it is safe to remember.
            if !registerUnreachable { await GeocodeCache.shared.recordMiss(key) }
            throw AppError.notFound(originalQuery)
        }

        guard !registerUnreachable else { return result }
        await GeocodeCache.shared.store(
            key, lat: result.lat, lon: result.lon,
            displayName: result.displayName, precision: result.precision)
        return result
    }

    // MARK: - Entrance

    /// Where the register puts this address's house number on the street — the
    /// entrance a navigation app is sent to. `nil` outside Vienna, when either
    /// lookup fails, and when the register has no entrance for the number.
    ///
    /// Two unthrottled calls. The address register first, to learn the street
    /// and number the way the city spells them: the entrance layer only
    /// matches its own spelling, and it files "82-92" under "82". Then the
    /// entrance layer itself, `ogdwien:ZUGANGSADROGD`, which has one point per
    /// house number — so every Stiege of a Gemeindebau gets the one entrance,
    /// not a point round the back of the block.
    ///
    /// Only the answers are remembered, for this launch. A failed call is not
    /// an answer and is asked again next time.
    func entrance(strasse: String, plz: String) async -> (lat: Double, lon: Double)? {
        guard Postcodes.isVienna(plz) else { return nil }
        let normalized = AddressText.normalize(strasse)
        let simplified = AddressText.simplifyHousenumber(normalized)
        // "Töllergasse 26 A" is house 26A, whose entrance is its own — see
        // `askedNumbers`. Tried first, and part of the key.
        let lettered = simplified.split(separator: " ").last
            .flatMap { Self.entranceNumber(String($0)) }
            .flatMap { n in
                Self.askedNumbers(n, segments: AddressText.subAddressSegments(normalized))
                    .first { $0 != n }
            }
        let key = "\(AddressText.matchKey(simplified))\(lettered ?? "")|\(plz)"
        if let known = entrances[key] { return known.point }

        // An empty answer is as good as none: the register returns nothing at
        // all for a house it does not know, and the entrance layer may still.
        let features = await ogdFetch(simplified) ?? []
        let streetKey = AddressText.matchKey(AddressText.streetNameOnly(simplified))
        // Only for the number that was asked for. For a number it does not
        // know, the register answers with the nearest one it does — "Gentzgasse
        // 999" comes back as 170, ranked in the hundreds — and that entrance is
        // a precise point at the wrong house, worse than sending the address.
        //
        // Picked among the answers carrying that number, not taken as the best
        // answer overall: asked for "Serravagasse 2" the register ranks
        // "Serravagasse 2E" first, and "Rabengasse 3" first as "3A" — the house
        // next door, whose number then did not match, and the Rabenhof went to
        // navigation as bare address text.
        guard let asked = simplified.split(separator: " ").last
            .flatMap({ Self.entranceNumber(String($0)) })
        else {
            entrances[key] = Known(point: nil)
            return nil
        }
        let sameNumber = features.filter {
            $0.properties.streetNumber.flatMap(Self.entranceNumber) == asked
        }
        // The register does not know every house the entrance layer does
        // (Stachegasse 22, Linke Wasserzeile 14). Then the entrance layer is
        // asked directly, with the street as typed.
        let street: String
        if let feature = Self.pickFeature(
               sameNumber, plz: plz, streetKey: streetKey, requireSub: nil),
           (feature.properties.ranking ?? .greatestFiniteMagnitude) < 1.0,
           let name = feature.properties.streetName {
            street = name
        } else {
            street = AddressText.streetNameOnly(simplified)
        }

        guard let candidates = await entranceFetch(street: street, number: asked, plz: plz)
        else { return nil }
        let point = lettered.flatMap { Self.pickEntrance(candidates, number: $0, plz: plz) }
            ?? Self.pickEntrance(candidates, number: asked, plz: plz)
        entrances[key] = Known(point: point)
        return point
    }

    private struct Known {
        let point: (lat: Double, lon: Double)?
    }
    private var entrances: [String: Known] = [:]

    /// "82" out of "82-92", "82/1" and "82 Kindertagesheim"; "12a" out of
    /// "12a/3". The part of the number the entrance layer files it under.
    static func entranceNumber(_ streetNumber: String) -> String? {
        var digits = ""
        var rest = streetNumber.trimmed.makeIterator()
        var next = rest.next()
        while let c = next, c.isASCII, c.isNumber {
            digits.append(c)
            next = rest.next()
        }
        guard !digits.isEmpty else { return nil }
        // One letter straight after the digits belongs to the number — "12a" —
        // but only if nothing but a separator or the end follows it, so the
        // "K" of "82 Kindertagesheim" is not mistaken for one.
        if let c = next, c.isLetter {
            let after = rest.next()
            if after == nil || after == "/" || after == " " || after == "-" {
                return digits + String(c).lowercased()
            }
        }
        return digits
    }

    /// The entrance whose number is this one — never "129a" or "1290" for
    /// "129", which the prefix query also returns.
    ///
    /// The layer is not consistent about ranges: "Heiligenstädter Straße
    /// 82-92" is filed as "82", "Münchenstraße 31-35" as "31-35". So a number
    /// written exactly as asked wins, and otherwise a range starting with it
    /// counts — read through `entranceNumber`, so "31-35" is "31" and "1290"
    /// is still not "129".
    static func pickEntrance(
        _ features: [EntranceFeature], number: String, plz: String
    ) -> (lat: Double, lon: Double)? {
        let want = number.lowercased().filter { !$0.isWhitespace }
        let here = features.filter { $0.properties.plz == plz }
        func raw(_ f: EntranceFeature) -> String {
            (f.properties.number ?? "").lowercased().filter { !$0.isWhitespace }
        }
        guard let hit = here.first(where: { raw($0) == want })
                ?? here.first(where: { entranceNumber(raw($0)) == want }),
              hit.geometry.coordinates.count == 2
        else { return nil }
        let lon = hit.geometry.coordinates[0], lat = hit.geometry.coordinates[1]
        guard Coordinates.isInVienna(lat: lat, lon: lon) else { return nil }
        return (lat, lon)
    }

    /// `nil` when the call failed; an empty list when it answered "none".
    private func entranceFetch(
        street: String, number: String, plz: String
    ) async -> [EntranceFeature]? {
        // Digits only in the prefix, so "12a" still finds "12A"; the exact
        // number is picked out of what comes back. Quotes doubled, which is
        // how CQL escapes them inside a string.
        let digits = String(number.prefix { $0.isNumber })
        func quoted(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
        let filter = "NAME LIKE '\(quoted(street)) \(digits)%' AND PLZ='\(quoted(plz))'"

        var comps = URLComponents(url: Upstreams.wienEntrances, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "service", value: "WFS"),
            URLQueryItem(name: "request", value: "GetFeature"),
            URLQueryItem(name: "version", value: "1.1.0"),
            URLQueryItem(name: "typeName", value: "ogdwien:ZUGANGSADROGD"),
            URLQueryItem(name: "srsName", value: "EPSG:4326"),
            URLQueryItem(name: "outputFormat", value: "json"),
            // Generous: the prefix also matches every longer number, and on a
            // long street "1" alone brings back 1, 10–19 and 100–199. At 50
            // the one actually asked for could be cut off. The server rejects
            // an OR filter that would ask for just the number.
            URLQueryItem(name: "maxFeatures", value: "500"),
            URLQueryItem(name: "cql_filter", value: filter),
        ]
        guard let url = comps?.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                log.warning("Wien entrance lookup error status")
                return nil
            }
            return try JSONDecoder().decode(EntranceCollection.self, from: data).features
        } catch {
            log.warning("Wien entrance lookup failed: \(error.localizedDescription)")
            return nil
        }
    }

    private struct EntranceCollection: Decodable {
        var features: [EntranceFeature] = []
    }
    struct EntranceFeature: Decodable {
        let geometry: OGDGeometry
        let properties: EntranceProperties
    }
    struct EntranceProperties: Decodable {
        let number: String?
        let plz: String?

        enum CodingKeys: String, CodingKey {
            case number = "NAME_ONR"
            case plz = "PLZ"
        }
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
    ///
    /// `unreachable` when no answer was found and at least one of the calls
    /// failed outright — the register may well have the address.
    private func wienOGDGeocode(
        strasse: String, plz: String
    ) async -> (hit: GeocodeResult?, unreachable: Bool) {
        var failed = false
        let hit = await wienOGDSearch(strasse: strasse, plz: plz, failed: &failed)
        return (hit, hit == nil && failed)
    }

    private func wienOGDSearch(
        strasse: String, plz: String, failed: inout Bool
    ) async -> GeocodeResult? {
        let normalized = AddressText.normalize(strasse)
        let simplified = AddressText.simplifyHousenumber(normalized)
        let sub = AddressText.housenumberWithSub(normalized)
        let number = simplified.split(separator: " ").last
            .flatMap { Self.entranceNumber(String($0)) }
        let segments = AddressText.subAddressSegments(normalized)
        let numbers = Self.askedNumbers(number, segments: segments)

        if let sub {
            if let hit = await ogdSearchOne(
                query: sub.query, plz: plz, subCheck: .require(sub.key),
                segments: segments, numbers: numbers, failed: &failed) {
                return hit
            }
        }

        // "Töllergasse 26 A" and "26/B" are the houses 26A and 26B when the
        // register has them — not house 26, which is where they used to land,
        // as exact. Only an answer carrying that lettered number is taken.
        if let number, let lettered = numbers.first(where: { $0 != number }),
           let hit = await ogdSearchOne(
               query: "\(AddressText.streetNameOnly(simplified)) \(lettered.uppercased())",
               plz: plz, subCheck: .absent, numbers: [lettered], failed: &failed),
           hit.precision == .exact {
            return hit
        }

        let fallbackCheck: SubCheck = sub.map { .downgrade($0.key) } ?? .absent

        if let hit = await ogdSearchOne(
            query: simplified, plz: plz, subCheck: fallbackCheck, numbers: numbers,
            failed: &failed) {
            return hit
        }
        if simplified != normalized,
           let hit = await ogdSearchOne(
            query: normalized, plz: plz, subCheck: fallbackCheck, numbers: numbers,
            failed: &failed) {
            return hit
        }
        return nil
    }

    /// The house numbers an answer may carry and still be the one asked for:
    /// "12" — and "12a" too when the letter was typed apart from it,
    /// "Hauptstraße 12 A" or "12/A/3". Without that the register's own "12A"
    /// was demoted to "≈" as a neighbouring number.
    static func askedNumbers(_ number: String?, segments: [String]) -> Set<String> {
        guard let number else { return [] }
        guard number.last?.isNumber == true,
              let first = segments.first?.split(separator: " ").first,
              first.count == 1, let letter = first.first, letter.isLetter
        else { return [number] }
        return [number, number + letter.lowercased()]
    }

    /// What the caller knows about the address's sub-address, and how strictly
    /// the register's answer has to honour it.
    enum SubCheck {
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
        query: String, plz: String, subCheck: SubCheck, segments: [String] = [],
        numbers: Set<String>, failed: inout Bool
    ) async -> GeocodeResult? {
        guard let features = await ogdFetch(query) else {
            failed = true
            return nil
        }
        // `matchKey`, not a lowercased raw string — see `pickFeature`.
        let ourStreet = AddressText.matchKey(AddressText.streetNameOnly(query))
        guard let best = Self.pickFeature(
            features, plz: plz, streetKey: ourStreet, requireSub: subCheck.required,
            segments: segments, numbers: numbers)
        else { return nil }

        guard let hit = Self.result(from: best, query: query, plz: plz, subCheck: subCheck)
        else { return nil }
        guard hit.precision == .exact,
              Self.isUncertainDoor(
                best, among: features, streetKey: ourStreet, numbers: numbers,
                subAsked: { if case .downgrade = subCheck { return true }; return false }())
        else { return hit }
        log.debug("OGD answer is not provably the door asked for, downgrading to street precision")
        return GeocodeResult(
            lat: hit.lat, lon: hit.lon, displayName: hit.displayName, precision: .street)
    }

    /// Whether an answer the register ranked as a match is still not provably
    /// the door that was asked for — so it goes to the driver as "≈" to check,
    /// not as a confident pin.
    ///
    /// Two ways that happens. The register ranks a neighbouring *number* as a
    /// match: asked for "Doningasse 8" it answers "Doningasse 8B" at a ranking
    /// of 0.00000001. And the driver asked for a door the register could not
    /// single out — "Wolkersbergenstraße 1/1", where number 1 is an "Obj. 1"
    /// and a "Pav. 1" 130 m apart — and the answer is the bare number, a point
    /// that is neither. A number the register does not split into buildings
    /// stays exact: "Pappenheimgasse 66-68/2/4/24" is one house, and the "/2"
    /// on it is a Stiege inside it that no register knows.
    static func isUncertainDoor(
        _ chosen: OGDFeature, among features: [OGDFeature], streetKey: String,
        numbers: Set<String>, subAsked: Bool
    ) -> Bool {
        guard !numbers.isEmpty else { return false }
        func numberOf(_ f: OGDFeature) -> String? {
            f.properties.streetNumber.flatMap(entranceNumber)
        }
        if let theirs = numberOf(chosen), !numbers.contains(theirs) { return true }
        guard subAsked,
              chosen.properties.adresse.flatMap(AddressText.subAddressTail) == nil
        else { return false }
        // Only a building far enough away to be somewhere else. The Stiegen of
        // one Gemeindebau number — "Gentzgasse 129/1", "129/2" — stand a few
        // dozen metres from the number's own point, and "129/5/12" with its
        // Stock and Tür is still that house.
        return features.contains {
            numberOf($0).map(numbers.contains) == true
                && AddressText.matchKey($0.properties.streetName ?? "") == streetKey
                && ($0.properties.ranking ?? .greatestFiniteMagnitude) < 1.0
                && $0.properties.adresse.flatMap(AddressText.subAddressTail) != nil
                && (metres(chosen, $0) ?? 0) > 40
        }
    }

    private static func metres(_ a: OGDFeature, _ b: OGDFeature) -> Double? {
        let p = a.geometry.coordinates, q = b.geometry.coordinates
        guard p.count == 2, q.count == 2 else { return nil }
        let metresPerDegree = 111_320.0
        let dx = (p[0] - q[0]) * metresPerDegree * cos(p[1] * .pi / 180)
        let dy = (p[1] - q[1]) * metresPerDegree
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Turns the one feature the register chose into an answer — the decision
    /// about *how much to trust it*, and the coordinates that go with it.
    ///
    /// Separated from the request for the same reason `pickFeature` and
    /// `visitingOrder` are: nothing here needs a network, and all of it decides
    /// something a driver acts on. Whether a pin is `.exact` is what puts the
    /// "≈, double check this one" warning on a row, and getting the two numbers
    /// the wrong way round puts the stop in the ocean.
    static func result(
        from feature: OGDFeature, query: String, plz: String, subCheck: SubCheck
    ) -> GeocodeResult? {
        let props = feature.properties
        let precision = Self.precision(
            kategorie: props.kategorie, adresse: props.adresse,
            ranking: props.ranking, subCheck: subCheck)

        guard feature.geometry.coordinates.count == 2 else { return nil }
        let lon = feature.geometry.coordinates[0]
        let lat = feature.geometry.coordinates[1]
        // `crs=EPSG:4326` is requested, but a service that ever ignored it
        // would hand back projected metres that look nothing like degrees —
        // fall through to Nominatim rather than storing a point in the middle
        // of the ocean as a confident "exact" match. The tight box, not the
        // country-wide one: this register only answers for Vienna.
        guard Coordinates.isInVienna(lat: lat, lon: lon) else {
            log.warning("OGD returned out-of-range coordinates, ignoring")
            return nil
        }

        let displayName = props.adresse.map { "\($0), \(plz) Wien" } ?? "\(query), \(plz) Wien"
        return GeocodeResult(
            lat: lat, lon: lon, displayName: displayName, precision: precision)
    }

    /// How much the register's own answer can be trusted.
    static func precision(
        kategorie: String?, adresse: String?, ranking: Double?, subCheck: SubCheck
    ) -> Precision {
        // The register answered with a street rather than a building.
        if kategorie == "Straßenname" { return .street }
        // It knows this housenumber, but only as somebody else's staircase or
        // garden plot. Same street, same number, different door — reported as
        // the approximation it is rather than passed off as the right one.
        if subCheck.isWrongNeighbour(adresse) {
            log.debug("OGD matched a neighbouring sub-address, downgrading to street precision")
            return .street
        }
        // A genuine housenumber (and usually Stiege/Parzelle/Tür) match. Above
        // that the scale jumps into the hundreds for "same street, wrong
        // housenumber", which is a street-level answer wearing a number.
        return (ranking ?? .greatestFiniteMagnitude) < 1.0 ? .exact : .street
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
    ///
    /// One letter of slack on the street name, and only as a second choice:
    /// "Pfenningeldgasse 9" is how the office's list spells Pfenninggeldgasse,
    /// and the register answers it with the right building at `Ranking`
    /// 0.0015 — which the exact comparison threw away, leaving the driver an
    /// "≈ Straße" pin and no entrance to navigate to. Accepted only when no
    /// candidate matches exactly, only in the right postcode, only on a name
    /// long enough that one letter is a typo rather than another street, and
    /// only when the register itself placed the house number (`Ranking` < 1).
    ///
    /// The register leaves `PostalCode` empty on some answers — "Breitenfurter
    /// Straße 390 Haus 2", "Hietzinger Hauptstraße 60/ 2" — while still giving
    /// their `Bezirk`. Those count as in the district when the `Bezirk` is the
    /// one the stop's postcode belongs to; filtered on the postcode alone,
    /// the right building was thrown away and a neighbour taken instead.
    static func pickFeature(
        _ features: [OGDFeature], plz: String, streetKey: String, requireSub: String?,
        segments: [String] = [], numbers: Set<String> = []
    ) -> OGDFeature? {
        let bezirk = Districts.byPlz[plz]?.bezirk
        let inDistrict = features.filter {
            if let code = $0.properties.postalCode { return code == plz }
            guard let bezirk, let theirs = $0.properties.bezirk.flatMap({ Int($0) })
            else { return false }
            return theirs == bezirk
        }
        // Compared through `matchKey`, which is what the other two "is this
        // the street we asked for?" checks in this file already use — and
        // what this one has to use as well, because the register is
        // *tolerant on input and canonical on output*. Ask it for
        // "Dr. Karl Lueger-Platz 1" — how anyone actually types it — and it
        // answers with the right building at `Ranking` 0.0 under the name
        // "Dr.-Karl-Lueger-Platz". A lowercased raw comparison, which is
        // what this did, then threw that exact answer away over the two
        // hyphens, fell through to Nominatim, and left the driver with an
        // "≈ Straße" pin for an address the city had placed precisely.
        // `matchKey` collapses the punctuation and keeps every letter in
        // order, so it still tells "Anton-Baumann-Gasse" apart from the
        // "Anton-Baumann-Park" the register offers for it.
        func name(_ f: OGDFeature) -> String {
            AddressText.matchKey(f.properties.streetName ?? "")
        }
        if let exact = pick(
            inDistrict.filter { name($0) == streetKey }, requireSub: requireSub,
            segments: segments, numbers: numbers) {
            return exact
        }
        return pick(
            inDistrict.filter {
                ($0.properties.ranking ?? .greatestFiniteMagnitude) < 1.0
                    && AddressText.isOneTypoApart(name($0), streetKey)
            },
            requireSub: requireSub, segments: segments, numbers: numbers)
    }

    private static func pick(
        _ features: [OGDFeature], requireSub: String?, segments: [String], numbers: Set<String>
    ) -> OGDFeature? {
        if let hit = pickExactSub(features, requireSub: requireSub, segments: segments) {
            return hit
        }
        guard requireSub != nil else { return nil }
        // The same door written without its label: "Mühlweg 4/2/5" for
        // "Gruppe 2 Parz. 5", "Salzergasse 36/1" for "Obj. 1", "57/A/1/1" for
        // "Haus A/1". Compared on the bare numbers and letters, first of the
        // first part after the housenumber, then of the first two — and only
        // accepted when that leaves exactly one door, because a site with an
        // "Obj. 1" and a "Pav. 1" cannot be told apart from "/1". On the
        // number asked for only: the register ranks "8B Obj. 1" as a match
        // for "8/1".
        let placed = features.filter {
            ($0.properties.ranking ?? .greatestFiniteMagnitude) < 1.0
                && (numbers.isEmpty
                    || $0.properties.streetNumber.flatMap(entranceNumber).map(numbers.contains) == true)
        }
        for n in [1, 2] where segments.count >= n {
            let wanted = AddressText.subAddressTokens(segments.prefix(n).joined(separator: "/"))
            guard !wanted.isEmpty else { continue }
            let hits = placed.filter {
                $0.properties.adresse
                    .flatMap(AddressText.subAddressTail)
                    .map(AddressText.subAddressTokens) == wanted
            }
            if let first = hits.first, hits.allSatisfy({ isSameDoor($0, first) }) {
                return hits.min {
                    ($0.properties.ranking ?? .greatestFiniteMagnitude)
                        < ($1.properties.ranking ?? .greatestFiniteMagnitude)
                }
            }
        }
        return nil
    }

    /// The register lists some doors twice under two spellings — "An der
    /// Niederhaid 8/GRP. 2/PARZ. 19" and "… 8 Gruppe 2 Parz. 19", 3 m apart.
    /// One door, not two to choose between.
    private static func isSameDoor(_ a: OGDFeature, _ b: OGDFeature) -> Bool {
        (metres(a, b) ?? .greatestFiniteMagnitude) < 25
    }

    private static func pickExactSub(
        _ features: [OGDFeature], requireSub: String?, segments: [String]
    ) -> OGDFeature? {
        // "Breitenfurter Straße 510" has both a "Haus 2" and a Stiege "/2",
        // which key alike. A driver who wrote "Haus" meant the house.
        let saysHaus = segments.first?.range(of: "haus", options: .caseInsensitive) != nil
        func labelDisagrees(_ f: OGDFeature) -> Bool {
            let tail = f.properties.adresse.flatMap(AddressText.subAddressTail) ?? ""
            return (tail.range(of: "haus", options: .caseInsensitive) != nil) != saysHaus
        }
        return features
            // A sub-address query only counts if the register came back with
            // *that* sub-address. Asked for one it has never heard of, the
            // service answers with a neighbour at a near-zero `Ranking` —
            // which would otherwise be accepted as an exact match and quietly
            // point the driver at the wrong staircase, or the wrong garden
            // plot 130 m down the lane. Compared through `subAddressOf` rather
            // than as raw text, because the register writes what the driver
            // typed as "9/Parz.68" as "Großfeldstraße 9 Parz. 68" — the same
            // address, spelled with a space and an abbreviation dot.
            //
            // And only on the house number asked for. "Pfenninggeldgasse
            // 9/2/15": number 9 has no Stiege 2, the house across the street,
            // 6-12, does — and the register offers "6-12/2", ranked in the
            // thousands for the wrong number. Taken for its matching Stiege,
            // it put the pin on the wrong house instead of falling through to
            // plain "Pfenninggeldgasse 9", which the register knows exactly.
            .filter { f in
                guard let want = requireSub else { return true }
                guard let adresse = f.properties.adresse,
                      let got = AddressText.subAddressOf(adresse),
                      (f.properties.ranking ?? .greatestFiniteMagnitude) < 1.0
                else { return false }
                return got == want
            }
            .min {
                let a = (requireSub != nil && labelDisagrees($0) ? 1 : 0,
                         $0.properties.ranking ?? .greatestFiniteMagnitude)
                let b = (requireSub != nil && labelDisagrees($1) ? 1 : 0,
                         $1.properties.ranking ?? .greatestFiniteMagnitude)
                return a < b
            }
    }

    /// One raw OGD lookup: the request and the parse. `nil` when the register
    /// could not be asked or its reply not read, and an empty list when it
    /// answered that it has nothing. Never throwing is what lets the caller
    /// treat the register as a first attempt rather than a hard dependency. An outage the night before a route is due degrades to the
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
            // checked before handing an empty string to the JSON parser. It
            // is an answer, "none", and not a failure.
            guard !data.isEmpty else { return [] }
            return try JSONDecoder().decode(OGDFeatureCollection.self, from: data).features
        } catch let e as URLError where e.code == .cancelled {
            // Answered `nil` like any other failure — but logged as what it is,
            // and safe only because `geocode` re-checks cancellation between
            // every phase. Without that check `nil` would read as "the register
            // does not have this address" and send a cancelled lookup on into
            // the throttled Nominatim calls it was cancelled to avoid.
            log.debug("Wien OGD lookup cancelled")
            return nil
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

        return Self.unanimousPostcode(features, streetKey: ourStreet, otherThan: plz)
    }

    /// The one postcode every candidate for this street agrees on, when it is
    /// not the one the stop was filed under.
    ///
    /// Deliberately narrow, and separated out because the narrowness is the
    /// whole point: a street that genuinely runs through several districts
    /// yields several postcodes and no hint at all. Guessing between them would
    /// be worse than the honest approximate pin the caller otherwise falls back
    /// to — and this is what puts a one-tap "move it to 1180" in front of the
    /// driver, so it has to be right.
    static func unanimousPostcode(
        _ features: [OGDFeature], streetKey: String, otherThan plz: String
    ) -> String? {
        var postcodes = Set<String>()
        for f in features {
            guard let name = f.properties.streetName,
                  AddressText.matchKey(name) == streetKey
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
    ///
    /// Each caller *claims* its slot before sleeping, and the claim is taken
    /// with no `await` between the read and the write, so the actor cannot
    /// interleave another caller into the middle of it. Recording the time of
    /// the last call instead — which is what this did — left the actor free
    /// during the sleep, so every caller that arrived while one was waiting
    /// measured against the same stale timestamp, computed the same delay, and
    /// woke up to fire simultaneously. A bulk import is exactly the case that
    /// produces that, and being individually blocked by Nominatim is exactly
    /// what the policy threatens.
    private func throttleNominatim() async {
        let now = Date()
        let claim = Self.claimSlot(
            now: now, nextFree: nominatimNextSlot, interval: Self.nominatimMinInterval)
        nominatimNextSlot = claim.nextFree
        let wait = claim.fireAt.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    /// The arithmetic of claiming a slot, separated out so the spacing it
    /// promises can be checked without waiting a second per assertion.
    ///
    /// Every claim takes the first free instant and pushes the mark one
    /// interval past it, so N callers arriving at once get N slots an interval
    /// apart rather than N slots at the same moment.
    static func claimSlot(
        now: Date, nextFree: Date, interval: TimeInterval
    ) -> (fireAt: Date, nextFree: Date) {
        let fireAt = max(now, nextFree)
        return (fireAt, fireAt.addingTimeInterval(interval))
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
        } catch let e as URLError where e.code == .cancelled {
            // `URLSession` reports a request cancelled along with its task as a
            // `URLError`. Rethrown as what it actually is, so a driver who
            // pressed Abbrechen is not told the geocoder is down.
            throw CancellationError()
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
    ///
    /// Takes the two fields it judges rather than the hit itself, so the wire
    /// type stays private and the rule can be tested without inventing one —
    /// the same reason `pickFeature` above is not private either. A hit that
    /// carries neither field is a hit there is nothing to check, and those are
    /// only ever accepted as `.district` anyway.
    static func hitMatches(
        postcode: String?, road: String?, wantedStreet: String, plz: String
    ) -> Bool {
        if let postcode = postcode?.trimmed, postcode != plz {
            log.debug("Nominatim hit is in a different district, ignoring")
            return false
        }
        if let road, AddressText.matchKey(road) != wantedStreet {
            log.debug("Nominatim hit is a different street, ignoring")
            return false
        }
        return true
    }

    private func nominatimSearchOne(
        query: String, wantedStreet: String, plz: String
    ) async throws -> GeocodeResult? {
        guard let top = try await nominatimRawSearch(query) else { return nil }
        guard Self.hitMatches(
            postcode: top.address?.postcode, road: top.address?.road,
            wantedStreet: wantedStreet, plz: plz)
        else { return nil }
        guard let lat = Double(top.lat), let lon = Double(top.lon) else {
            throw AppError.message("Geocoding-Dienst: ungültige Koordinaten in der Antwort")
        }
        // Nominatim's search is fuzzy and country-wide (`countrycodes=at` is
        // as narrow as it gets): a Viennese street name that also exists in
        // Graz or Linz can come back as a confident top hit hundreds of
        // kilometres away. Treat anything outside the box as no match, so the
        // caller falls through to its next strategy instead of pinning a stop
        // in the wrong federal state.
        //
        // Which box depends on the postcode. A stop filed under 1210 is in
        // Vienna or it is a mistake, and the tight box is what catches that;
        // a stop filed under 2201 is legitimately somewhere this app cannot
        // narrow down further than Austria, and the only sanity left to check
        // is that the answer is on the right continent. The postcode is
        // already verified against the hit's own `postcode` in `hitMatches`,
        // which is the real filter outside the city.
        guard Coordinates.isPlausible(lat: lat, lon: lon, forPlz: plz) else {
            log.warning("Nominatim hit outside the expected area, ignoring")
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
        let place = Postcodes.placeSuffix(for: plz)
        guard let hit = try await nominatimRawSearch(place) else { return nil }
        // Trimmed, exactly as `hitMatches` compares the same field. Nominatim
        // returns the postcode as the underlying OSM tag holds it, and a tag
        // with a stray space around it made the one check that tells a real
        // postcode from a hit on "Wien" alone fail — so the coarse pin this is
        // the last resort for was refused, and a route with one unfindable
        // address went back to blocking on it.
        guard hit.address?.postcode?.trimmed == plz,
              let lat = Double(hit.lat), let lon = Double(hit.lon),
              Coordinates.isPlausible(lat: lat, lon: lon, forPlz: plz)
        else { return nil }

        return GeocodeResult(
            lat: lat, lon: lon,
            displayName: Postcodes.isVienna(plz)
                ? "\(plz) Wien (nur Bezirk, Adresse unbekannt)"
                : "\(plz) (nur Ort, Adresse unbekannt)",
            precision: .district)
    }

    // MARK: - Wire types

    private struct OGDFeatureCollection: Decodable {
        var features: [OGDFeature] = []
    }
    struct OGDFeature: Decodable {
        let geometry: OGDGeometry
        let properties: OGDProperties
    }
    struct OGDGeometry: Decodable {
        /// `[lon, lat]`.
        let coordinates: [Double]
    }
    struct OGDProperties: Decodable {
        let streetName: String?
        let postalCode: String?
        let kategorie: String?
        let adresse: String?
        let ranking: Double?
        /// "82", "129/1", "82 Kindertagesheim" — the number as the register
        /// writes it, which is what the entrance lookup is asked with.
        var streetNumber: String? = nil
        /// "23" — present even on the answers that carry no `PostalCode`.
        var bezirk: String? = nil

        enum CodingKeys: String, CodingKey {
            case bezirk = "Bezirk"
            case streetName = "StreetName"
            case postalCode = "PostalCode"
            case kategorie = "Kategorie"
            case adresse = "Adresse"
            case ranking = "Ranking"
            case streetNumber = "StreetNumber"
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
