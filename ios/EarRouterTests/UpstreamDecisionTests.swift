import Testing
import Foundation
import SwiftData
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

    /// Google sends an encoded polyline rather than GeoJSON. Decoding it in
    /// longitude-first order would draw the right shape in the wrong country.
    @Test func googleRouteGeometryAlsoComesBackLatitudeFirst() {
        let line = GoogleRoutesClient.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(line == [[38.5, -120.2], [40.7, -120.95], [43.252, -126.453]])
    }

    @Test func googlesOneStopSentinelMeansKeepTheOnlyStop() throws {
        #expect(try GoogleRoutesClient.intermediateOrder([-1], count: 1) == [0])
        #expect(try GoogleRoutesClient.intermediateOrder([1, 0], count: 2) == [1, 0])
        #expect(throws: AppError.self) {
            try GoogleRoutesClient.intermediateOrder([-1], count: 2)
        }
    }

    @Test func googleRoutesKeySurvivesAReloadFromTheKeychain() {
        let before = GoogleRoutesKeyStore.load()
        defer { _ = GoogleRoutesKeyStore.save(before ?? "") }

        #expect(GoogleRoutesKeyStore.save("test-key"))
        #expect(GoogleRoutesKeyStore.load() == "test-key")
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

/// What the optimizer plans from, and what it considers a change.
///
/// Both of these sit either side of seconds of network calls: the snapshot is
/// taken before, the comparison is made after, and a route that changed in
/// between must stay flagged. The reads themselves are pure.
@MainActor
struct OptimizerSnapshotTests {

    private func route(_ build: (Route, ModelContext) throws -> Void = { _, _ in }) throws -> Route {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        try build(route, context)
        try context.save()
        return route
    }

    private func customer(_ name: String, lat: Double = 48.23) -> Stop {
        Stop(kind: .customer, kunde: name, strasse: "Gasse 1", plz: "1180",
             lat: lat, lon: 16.32)
    }

    /// `excluded` is only ever written to a fixed stop, and a customer row
    /// carrying it anyway must not silently disappear from the tour — which is
    /// why the snapshot switches on the *kind* rather than on the flag.
    @Test func aCustomerCarryingTheExcludedFlagIsStillPlanned() throws {
        let route = try route { route, context in
            let stop = customer("Fam. Gruber")
            stop.excluded = true          // nothing in the app writes this
            stop.route = route
            context.insert(stop)
        }
        let (nodes, _) = RouteOptimizer.snapshot(route)
        #expect(nodes.customers.count == 1)
    }

    /// A switched-off fixed point is a different matter: it stays on the route
    /// and is left out of the solve.
    @Test func aSwitchedOffFixedPointIsNotDrivenButIsStillThere() throws {
        let route = try route { route, _ in
            route.stops.first { $0.kind == .via }?.excluded = true
        }
        let (nodes, _) = RouteOptimizer.snapshot(route)
        #expect(nodes.via?.excluded == true)
        #expect(nodes.via?.active == nil)
        #expect(nodes.head.count == 1)     // start only
    }

    /// The fingerprint is which stops exist, where they are, and which are
    /// skipped — deliberately not the whole row. A customer's name or note
    /// changing between the read and the write does not make the computed order
    /// or geometry wrong, and treating it as if it did would leave routes
    /// perpetually flagged over an edited Notiz.
    @Test func editingANoteIsNotAChangeWorthReoptimising() throws {
        let route = try route { route, context in
            let stop = customer("Fam. Gruber")
            stop.route = route
            context.insert(stop)
        }
        let before = RouteOptimizer.snapshot(route).1

        let stop = try #require(route.customerStops.first)
        stop.kunde = "Familie Gruber"
        stop.notiz = "Bitte laut klingeln"
        stop.paket = "2x Menü"
        stop.telefon = "+4369910842229"
        stop.delivered = true

        #expect(RouteOptimizer.snapshot(route).1 == before)
    }

    /// Moving one is.
    @Test func movingAStopIsAChangeWorthReoptimising() throws {
        let route = try route { route, context in
            let stop = customer("Fam. Gruber")
            stop.route = route
            context.insert(stop)
        }
        let before = RouteOptimizer.snapshot(route).1
        try #require(route.customerStops.first).lat = 48.24
        #expect(RouteOptimizer.snapshot(route).1 != before)
    }

    /// So is adding one, removing one, or switching a fixed point out — the
    /// three things that happen while an optimization is in flight.
    @Test func addingRemovingAndSkippingAreAllChanges() throws {
        let route = try route { route, context in
            let stop = customer("Fam. Gruber")
            stop.route = route
            context.insert(stop)
        }
        let container = route.modelContext
        let before = RouteOptimizer.snapshot(route).1

        let added = customer("Hr. Novak", lat: 48.25)
        added.route = route
        container?.insert(added)
        let afterAdding = RouteOptimizer.snapshot(route).1
        #expect(afterAdding != before)

        route.stops.first { $0.kind == .end }?.excluded = true
        #expect(RouteOptimizer.snapshot(route).1 != afterAdding)
    }
}

/// The shape of the answer, before any of it is believed.
struct TripShapeTests {

    /// A non-roundtrip trip over n waypoints has exactly n-1 legs. Anything
    /// else and each stop is paired with the wrong leg's distance — a route
    /// that looks entirely normal while telling the driver the wrong
    /// "x km to the next stop" on every row.
    @Test func alegPerGapBetweenWaypointsAndNoOther() throws {
        try OSRMClient.checkLegCount(4, waypoints: 5)
        try OSRMClient.checkLegCount(1, waypoints: 2)

        #expect(throws: AppError.self) { try OSRMClient.checkLegCount(5, waypoints: 5) }
        #expect(throws: AppError.self) { try OSRMClient.checkLegCount(3, waypoints: 5) }
        #expect(throws: AppError.self) { try OSRMClient.checkLegCount(0, waypoints: 5) }
    }

    /// And what it says is not a protocol word.
    @Test func theMismatchIsReportedInWordsTheDriverReads() {
        #expect(throws: AppError.self) { try OSRMClient.checkLegCount(2, waypoints: 5) }
        do {
            try OSRMClient.checkLegCount(2, waypoints: 5)
        } catch let error as AppError {
            #expect(error.message.contains("Etappen"))
        } catch {
            Issue.record("expected an AppError")
        }
    }
}
