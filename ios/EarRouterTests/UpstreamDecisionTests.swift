import Testing
import Foundation
@testable import EarRouter

/// The decisions the two upstream clients make about an answer once it has
/// arrived.
///
/// None of these needs a network — they are pure functions of what came back —
/// but all of them were sealed inside the method that does the request, which
/// is why a deliberate regression in every one of them left the suite green.
/// Each one here is a mistake with a shape: a route to the wrong country, a
/// line drawn in the wrong hemisphere, an approximate pin presented as a
/// confirmed door, a protocol word shown to a driver.
struct UpstreamDecisionTests {

    // MARK: - The coordinate order, in both directions

    /// OSRM takes `lon,lat`, which is the opposite order from how the rest of
    /// this app writes a coordinate. Swapped, every tour is planned somewhere
    /// off the coast of Somalia — and it would look like a routing outage
    /// rather than a units bug.
    @Test func theRouterIsGivenLongitudeFirst() {
        let vienna = (lat: 48.2082, lon: 16.3738)
        #expect(OSRMClient.coordString([vienna]) == "16.373800,48.208200")
    }

    @Test func severalPointsKeepTheirOrderAndTheirSeparator() {
        let s = OSRMClient.coordString([(lat: 48.2, lon: 16.3), (lat: 48.1, lon: 16.4)])
        #expect(s == "16.300000,48.200000;16.400000,48.100000")
    }

    /// Written with a fixed POSIX locale, because a phone set to German would
    /// otherwise put a comma where OSRM expects a decimal point — and the URL
    /// would parse as twice as many coordinates as were sent.
    @Test func theDecimalSeparatorIsNotTheDriversOwn() {
        let one = OSRMClient.coordString([(lat: 48.2082, lon: 16.3738)])
        // One comma only — the one separating longitude from latitude. A
        // decimal comma would make OSRM read this as four coordinates.
        #expect(one.filter { $0 == "," }.count == 1)
        #expect(one.filter { $0 == "." }.count == 2)

        let two = OSRMClient.coordString([(lat: 48.2, lon: 16.3), (lat: 48.1, lon: 16.4)])
        #expect(two.filter { $0 == "," }.count == 2)
        #expect(two.filter { $0 == ";" }.count == 1)
    }

    /// And back the other way: GeoJSON is `[lon, lat]` and everything
    /// downstream of the client wants `[lat, lon]`.
    @Test func theDrivenLineComesBackLatitudeFirst() {
        #expect(OSRMClient.flip([[16.3738, 48.2082]]) == [[48.2082, 16.3738]])
        #expect(OSRMClient.flip([[16.3, 48.2], [16.4, 48.1]]) == [[48.2, 16.3], [48.1, 16.4]])
    }

    /// A pair that is not a pair is dropped rather than trusted.
    @Test func amalformedPointIsSkippedNotGuessedAt() {
        #expect(OSRMClient.flip([[16.3738], [16.3, 48.2], [1, 2, 3]]) == [[48.2, 16.3]])
        #expect(OSRMClient.flip([]).isEmpty)
    }

    // MARK: - What the driver is told when the router refuses

    /// The codes are protocol words, and they were going straight into the
    /// alert: a tap on "Neu optimieren" could answer with "OSRM trip:
    /// NoSegment". The three that mean "these points cannot be driven between"
    /// get the sentence that points at the pins, because a hand-placed pin in a
    /// courtyard is the likeliest cause by far.
    @Test func aRouteThatCannotBeDrivenPointsAtThePins() {
        for code in ["NoRoute", "NoTrips", "NoSegment"] {
            let message = OSRMClient.failure(code: code).message
            #expect(message.contains("Pin"), "\(code) should point at the pins")
            #expect(!message.contains(code), "\(code) leaked into the alert")
        }
    }

    @Test func aTourTooBigToSolveSaysSo() {
        let message = OSRMClient.failure(code: "TooBig").message
        #expect(message.contains("aufteilen"))
        #expect(!message.contains("TooBig"))
    }

    /// Anything else is the router being unavailable, and still not a word of
    /// protocol.
    @Test func anyOtherCodeIsNeverShownToTheDriver() {
        let unavailable: String = AppError.routerUnavailable.message
        for code in ["InvalidValue", "InvalidQuery", "NotImplemented", "Zzz"] {
            let message: String = OSRMClient.failure(code: code).message
            #expect(message == unavailable)
            #expect(message.contains(code) == false)
        }
    }

    // MARK: - How far the register's answer can be trusted

    /// Built through the real decoder, so the wire names these tests depend on
    /// are the ones the register actually sends.
    private func feature(
        street: String = "Gentzgasse", plz: String = "1180",
        kategorie: String = "Adresse", adresse: String? = "Gentzgasse 129",
        ranking: Double? = 0.0, lat: Double = 48.2301, lon: Double = 16.3201
    ) -> Geocoder.OGDFeature {
        var properties: [String: Any] = [
            "StreetName": street, "PostalCode": plz, "Kategorie": kategorie,
        ]
        if let adresse { properties["Adresse"] = adresse }
        if let ranking { properties["Ranking"] = ranking }
        let object: [String: Any] = [
            "geometry": ["coordinates": [lon, lat]],
            "properties": properties,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(Geocoder.OGDFeature.self, from: data)
    }

    @Test func aBuildingTheRegisterKnowsIsAnExactPin() {
        #expect(Geocoder.precision(
            kategorie: "Adresse", adresse: "Gentzgasse 129", ranking: 0.0,
            subCheck: .absent) == .exact)
    }

    /// A real street, but the housenumber was never registered — the register
    /// matched to the nearest one instead, and the scale jumps into the
    /// hundreds when it does.
    @Test func aHousenumberTheRegisterHadToGuessIsOnlyStreetLevel() {
        #expect(Geocoder.precision(
            kategorie: "Adresse", adresse: "Gentzgasse 131", ranking: 250.0,
            subCheck: .absent) == .street)
        #expect(Geocoder.precision(
            kategorie: "Adresse", adresse: "Gentzgasse 131", ranking: nil,
            subCheck: .absent) == .street)
    }

    @Test func anAnswerThatIsAStreetNameIsNeverExact() {
        #expect(Geocoder.precision(
            kategorie: "Straßenname", adresse: "Gentzgasse", ranking: 0.0,
            subCheck: .absent) == .street)
    }

    /// The one that matters most on a Gemeindebau: the register answered for
    /// somebody else's staircase, at a near-zero ranking, and it is ~30 m and
    /// one wrong front door away.
    @Test func aNeighbouringStaircaseIsNotPassedOffAsTheRightDoor() {
        #expect(Geocoder.precision(
            kategorie: "Adresse", adresse: "Gentzgasse 129/2", ranking: 0.0,
            subCheck: .downgrade("1")) == .street)
        // The staircase that was actually asked for still counts as exact.
        #expect(Geocoder.precision(
            kategorie: "Adresse", adresse: "Gentzgasse 129/1", ranking: 0.0,
            subCheck: .downgrade("1")) == .exact)
    }

    /// The register writes "9/Parz.68" as "Großfeldstraße 9 Parz. 68" — the
    /// same plot, spelled with a space and an abbreviation dot.
    @Test func theRegistersOwnSpellingOfAParzelleIsStillThatParzelle() {
        #expect(Geocoder.precision(
            kategorie: "Adresse", adresse: "Großfeldstraße 9 Parz. 68", ranking: 0.0,
            subCheck: .downgrade("parz68")) == .exact)
    }

    // MARK: - The coordinates that come with it

    @Test func theRegistersPointIsReadLongitudeFirst() throws {
        let result = try #require(Geocoder.result(
            from: feature(lat: 48.2301, lon: 16.3201),
            query: "Gentzgasse 129", plz: "1180", subCheck: .absent))
        #expect(result.lat == 48.2301)
        #expect(result.lon == 16.3201)
        #expect(result.displayName == "Gentzgasse 129, 1180 Wien")
    }

    /// `crs=EPSG:4326` is asked for, but a service that ever ignored it would
    /// hand back projected metres that look nothing like degrees. Better to
    /// fall through to Nominatim than to store a point in the ocean as a
    /// confident exact match.
    @Test func aPointThatIsNotDegreesIsRefusedRatherThanStored() {
        #expect(Geocoder.result(
            from: feature(lat: 338_000, lon: 5_340_000),
            query: "Gentzgasse 129", plz: "1180", subCheck: .absent) == nil)
        // And anything simply outside Vienna, which this register only answers for.
        #expect(Geocoder.result(
            from: feature(lat: 47.0707, lon: 15.4395),
            query: "Gentzgasse 129", plz: "1180", subCheck: .absent) == nil)
    }

    // MARK: - The wrong-district offer

    /// Only when *every* candidate for the street agrees on one postcode, and
    /// it is not the one the stop carries. A street that genuinely runs through
    /// several districts yields several postcodes and no hint at all.
    @Test func aStreetThatSitsWhollyInAnotherDistrictIsOffered() {
        let features = [
            feature(street: "Gentzgasse", plz: "1180"),
            feature(street: "Gentzgasse", plz: "1180"),
        ]
        #expect(Geocoder.unanimousPostcode(
            features, streetKey: AddressText.matchKey("Gentzgasse"),
            otherThan: "1190") == "1180")
    }

    @Test func aStreetRunningThroughSeveralDistrictsOffersNothing() {
        let features = [
            feature(street: "Hauptstraße", plz: "1030"),
            feature(street: "Hauptstraße", plz: "1140"),
        ]
        #expect(Geocoder.unanimousPostcode(
            features, streetKey: AddressText.matchKey("Hauptstraße"),
            otherThan: "1230") == nil)
    }

    /// And nothing at all when the answer is the postcode already on the stop —
    /// there is no correction to offer.
    @Test func theDistrictItIsAlreadyFiledUnderIsNotACorrection() {
        let features = [feature(street: "Gentzgasse", plz: "1180")]
        #expect(Geocoder.unanimousPostcode(
            features, streetKey: AddressText.matchKey("Gentzgasse"),
            otherThan: "1180") == nil)
    }

    /// Candidates for a *different* street are not evidence about this one.
    @Test func anotherStreetInTheAnswerIsNotCounted() {
        let features = [
            feature(street: "Gentzgasse", plz: "1180"),
            feature(street: "Gentzstraße", plz: "1090"),
        ]
        #expect(Geocoder.unanimousPostcode(
            features, streetKey: AddressText.matchKey("Gentzgasse"),
            otherThan: "1190") == "1180")
    }
}

/// Joining the legs of a tour into one line.
@MainActor
struct RouteGeometryJoinTests {

    /// Each leg repeats the point the previous one ended on. Left in, the map
    /// draws a line with a doubled vertex at every junction — which looks
    /// almost right, and is the kind of almost that survives review.
    @Test func thesharedPointWhereTwoLegsMeetIsNotDrawnTwice() {
        var acc: [[Double]] = []
        RouteOptimizer.append(&acc, [[48.1, 16.1], [48.2, 16.2]])
        RouteOptimizer.append(&acc, [[48.2, 16.2], [48.3, 16.3]])
        #expect(acc == [[48.1, 16.1], [48.2, 16.2], [48.3, 16.3]])
    }

    @Test func thefirstLegIsKeptWhole() {
        var acc: [[Double]] = []
        RouteOptimizer.append(&acc, [[48.1, 16.1], [48.2, 16.2]])
        #expect(acc == [[48.1, 16.1], [48.2, 16.2]])
    }

    @Test func anEmptyLegJoinsNothingAndLosesNothing() {
        var acc: [[Double]] = [[48.1, 16.1], [48.2, 16.2]]
        RouteOptimizer.append(&acc, [])
        #expect(acc == [[48.1, 16.1], [48.2, 16.2]])

        var empty: [[Double]] = []
        RouteOptimizer.append(&empty, [[48.1, 16.1]])
        #expect(empty == [[48.1, 16.1]])
    }
}
