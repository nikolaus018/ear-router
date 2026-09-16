import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// The stop list derives everything it shows — the numbers on the badges, the
/// progress in the header, the tour totals in the footer — in one walk of the
/// route, rather than by asking `Route` a question per row. These are the same
/// answers the per-row computed properties used to give, pinned down so the
/// cheaper version cannot quietly disagree with them.
@MainActor
struct RouteSnapshotTests {

    private func route(_ stops: [Stop]) throws -> Route {
        let container = try ModelContainer(
            for: Route.self, Stop.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = Route(name: "Test")
        context.insert(route)
        for (i, s) in stops.enumerated() {
            s.orderIndex = i
            s.route = route
            context.insert(s)
        }
        try context.save()
        return route
    }

    /// Every stop gets its own address and its own coordinate unless a test
    /// says otherwise: stops that share an exact point are deliberately read as
    /// one front door, and that is a different test than these.
    private func customer(
        _ kunde: String, at index: Int,
        strasse: String? = nil, plz: String = "1180",
        delivered: Bool = false, km: Double? = nil, minutes: Double? = nil
    ) -> Stop {
        let s = Stop(
            kind: .customer, kunde: kunde,
            strasse: strasse ?? "Gentzgasse \(index)", plz: plz,
            lat: 48.20 + Double(index) / 1000, lon: 16.32)
        s.delivered = delivered
        s.nextLegKm = km
        s.nextLegMin = minutes
        return s
    }

    private func fixed(
        _ kind: StopKind, excluded: Bool = false, km: Double? = nil, done: Bool = false
    ) -> Stop {
        let s = Stop(kind: kind, kunde: "Fix", strasse: Coordinates.startAddress,
                     plz: Coordinates.startPlz,
                     lat: Coordinates.start.lat, lon: Coordinates.start.lon,
                     excluded: excluded)
        s.nextLegKm = km
        s.nextLegMin = km
        if done { s.record(.delivered) }
        return s
    }

    /// The badge number is the stop's position among the *customers*, counted
    /// in display order — the fixed points sitting between them do not consume
    /// a number, and do not carry one.
    @Test func numbersOnlyTheCustomers() throws {
        let a = customer("A", at: 1), b = customer("B", at: 2)
        let start = fixed(.start), via = fixed(.via)
        let r = try route([start, via, a, b])
        let snap = RouteSnapshot(r)

        #expect(snap.number(a) == 1)
        #expect(snap.number(b) == 2)
        #expect(snap.number(start) == nil)
        #expect(snap.customerCount == 2)
    }

    @Test func countsDeliveriesWithoutCountingTheFixedPoints() throws {
        let r = try route([
            fixed(.start),
            customer("A", at: 1, delivered: true),
            customer("B", at: 2),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.customerCount == 2)
        #expect(snap.deliveredCount == 1)
        #expect(snap.isComplete == false)
    }

    /// A route with nothing but its three fixed points is not a finished tour —
    /// it is a tour nobody has put any stops on yet.
    @Test func aRouteWithNoCustomersIsNeverComplete() throws {
        let r = try route([fixed(.start), fixed(.via), fixed(.end)])
        let snap = RouteSnapshot(r)
        #expect(snap.customerCount == 0)
        #expect(snap.isComplete == false)
        #expect(snap.nextOpen == nil)
        #expect(r.isComplete == false)
    }

    @Test func theNextOpenStopIsTheFirstUndeliveredCustomer() throws {
        let a = customer("A", at: 1, delivered: true)
        let b = customer("B", at: 2)
        let c = customer("C", at: 3)
        let r = try route([fixed(.start), a, b, c])
        let snap = RouteSnapshot(r)
        #expect(snap.nextOpen?.id == b.id)
        #expect(snap.nextOpen?.id == r.nextOpenStop?.id)
    }

    /// A stop switched off for this tour is a leg the van never drives, so its
    /// distance is not part of the day.
    @Test func totalsLeaveOutExcludedStops() throws {
        let r = try route([
            fixed(.start, km: 20),
            fixed(.via, excluded: true, km: 15),
            customer("A", at: 1, km: 2, minutes: 4),
            customer("B", at: 2),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.totalKm == 22)
        #expect(snap.totalMinutes == 24)
        // The model's own answer has to agree — the list footer reads one and
        // the route summary row reads the other.
        #expect(r.totals.km == snap.totalKm)
        #expect(r.totals.minutes == snap.totalMinutes)
    }

    // MARK: - What is still to drive

    /// Before the first delivery there is nothing behind the driver, so the
    /// footer's two numbers are the same one — which is exactly why it only
    /// prints the total until a stop has actually been ticked off.
    @Test func withNothingDeliveredTheWholeTourIsStillAhead() throws {
        let r = try route([
            fixed(.start, km: 20),
            fixed(.via, km: 5),
            customer("A", at: 1, km: 2, minutes: 4),
            customer("B", at: 2, km: 3, minutes: 6),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.remainingKm == snap.totalKm)
        #expect(snap.remainingMinutes == snap.totalMinutes)
        // Two doors, and Lager and Ziel.
        #expect(snap.openCount == 4)
    }

    /// A leg belongs to the stop it leaves from, so ticking off the first
    /// customer means the depot leg, the warehouse leg and that customer's own
    /// leg into the next one are behind the van — the last of those is not,
    /// because the driver is standing at the stop it starts from.
    @Test func deliveringAStopLeavesOnlyTheLegsFromItOnwards() throws {
        let r = try route([
            fixed(.start, km: 20),
            fixed(.via, km: 5, done: true),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            customer("B", at: 2, km: 3, minutes: 6),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.totalKm == 30)
        // Everything before A's own leg is driven; A → B and B → Ziel are not.
        #expect(snap.remainingKm == 5)
        #expect(snap.remainingMinutes == 10)
        // B, and Ziel.
        #expect(snap.openCount == 2)
    }

    /// Ticked off out of order — a customer met on the street and handed their
    /// meal early — what is left still covers every door still owed, including
    /// the ones the driver has driven past.
    ///
    /// This used to follow the *last* stop ticked wherever it sat, so ticking B
    /// reported the 3 km from B to the end while A was still open and still had
    /// to be driven to. Paired with the card's own "Noch 2 Stopps" that is a
    /// sentence no tour can satisfy.
    ///
    /// The answer here is the whole tour, which over-counts by the depot → A
    /// leg the van has in fact already driven. That is on purpose: with the
    /// plan no longer being followed in order, "how far from here, back to A,
    /// and on to C" is a re-routing question, not a sum of stored legs — and
    /// the honest thing to do with a number that cannot be known exactly is to
    /// err long. A driver told a tour is shorter than it is finds out at the
    /// wrong end of the day.
    @Test func doesNotWriteOffTheStopsBehindAnEarlyDelivery() throws {
        let r = try route([
            fixed(.start, km: 10),
            customer("A", at: 1, km: 2, minutes: 4),
            customer("B", at: 2, delivered: true, km: 3, minutes: 6),
            // The last stop of the tour drives no further leg.
            customer("C", at: 3),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.nextOpen?.kunde == "A")
        #expect(snap.openCount == 2)
        #expect(snap.totalKm == 15)
        // Never the 3 km the old rule reported, which wrote A off entirely.
        #expect(snap.remainingKm == 15)
        #expect(snap.remainingMinutes == 20)
        #expect(snap.remainingKm > 3)
    }

    /// And once the skipped stop is caught up, the mark moves again — the
    /// freeze is tied to the first stop still *open*, not to the fact that
    /// something was once ticked out of order.
    @Test func theMarkMovesAgainOnceTheSkippedStopIsCaughtUp() throws {
        let r = try route([
            fixed(.start, km: 10),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            customer("B", at: 2, delivered: true, km: 3, minutes: 6),
            customer("C", at: 3),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.nextOpen?.kunde == "C")
        // Standing at B, with only B → C left, and that leg is zero.
        #expect(snap.remainingKm == 3)
        #expect(snap.remainingMinutes == 6)
    }

    /// The same route ticked off in order: the mark moves with every delivery,
    /// exactly as it always did. The out-of-order rule above only ever freezes
    /// it at the first stop still open, which on an in-order tour is the stop
    /// after the last one delivered.
    @Test func stillFollowsEveryDeliveryWhileTheTourIsTickedInOrder() throws {
        let r = try route([
            fixed(.start, km: 10),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            customer("B", at: 2, delivered: true, km: 3, minutes: 6),
            customer("C", at: 3, km: 4, minutes: 8),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.nextOpen?.kunde == "C")
        // Standing at B: B → C and C → Ziel.
        #expect(snap.remainingKm == 7)
        #expect(snap.remainingMinutes == 14)
    }

    /// The last meal is handed over and the van still has to get home. That
    /// drive is real, and it is the one stop left: Ziel.
    @Test func afterTheLastMealZielIsStillAhead() throws {
        let r = try route([
            fixed(.start, km: 20),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            customer("B", at: 2, delivered: true, km: 18, minutes: 25),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(!snap.isComplete)
        #expect(snap.openCount == 1)
        #expect(snap.nextOpen?.kind == .end)
        #expect(snap.remainingKm == 18)
        #expect(snap.remainingMinutes == 25)
    }

    /// Ticked off at Ziel, the tour is done and nothing is left to drive.
    @Test func tickingZielFinishesTheTour() throws {
        let r = try route([
            fixed(.start, km: 20),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            customer("B", at: 2, delivered: true, km: 18, minutes: 25),
            fixed(.end, done: true),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.isComplete)
        #expect(snap.openCount == 0)
        #expect(snap.nextOpen == nil)
        #expect(snap.remainingKm == 0)
    }

    /// Lager comes before the first door, and until it is ticked off it is the
    /// stop the driver is on.
    @Test func lagerIsTheFirstStop() throws {
        let a = customer("A", at: 1)
        let via = fixed(.via)
        let r = try route([fixed(.start), via, a, fixed(.end)])
        #expect(RouteSnapshot(r).nextOpen?.id == via.id)
        #expect(r.nextOpenStop?.id == via.id)

        via.record(.delivered)
        #expect(RouteSnapshot(r).nextOpen?.id == a.id)
    }

    /// Switched off for this tour, Lager and Ziel are not stops at all.
    @Test func anExcludedLagerOrZielIsNotAStop() throws {
        let a = customer("A", at: 1)
        let r = try route([
            fixed(.start), fixed(.via, excluded: true), a, fixed(.end, excluded: true),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.nextOpen?.id == a.id)
        #expect(snap.openCount == 1)
        a.record(.delivered)
        #expect(RouteSnapshot(r).isComplete)
    }

    /// A tour not optimized yet lists Ziel above the customers added after it.
    /// It still waits until they are done.
    @Test func zielWaitsForTheCustomersWhereverItIsListed() throws {
        let end = fixed(.end)
        let a = customer("A", at: 1)
        let r = try route([fixed(.start), fixed(.via, done: true), end, a])
        #expect(RouteSnapshot(r).nextOpen?.id == a.id)
        #expect(r.nextOpenStop?.id == a.id)

        a.record(.delivered)
        #expect(RouteSnapshot(r).nextOpen?.id == end.id)
        #expect(r.nextOpenStop?.id == end.id)
    }

    /// A switched-off fixed point is not driven, so it cannot be part of what
    /// is left either — the same rule the totals already follow.
    @Test func whatIsLeftLeavesOutExcludedStopsToo() throws {
        let r = try route([
            fixed(.start, km: 20),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            fixed(.via, excluded: true, km: 15),
            customer("B", at: 2, km: 3, minutes: 6),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.totalKm == 25)
        #expect(snap.remainingKm == 5)
    }

    @Test func agreesWithTheModelOnEveryCount() throws {
        let r = try route([
            fixed(.start), fixed(.via),
            customer("A", at: 1, delivered: true), customer("B", at: 2, delivered: true),
            customer("C", at: 3),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.customerCount == r.customerCount)
        #expect(snap.customerCount == r.customerStops.count)
        #expect(snap.deliveredCount == r.deliveredCount)
        #expect(snap.isComplete == r.isComplete)
    }

    /// Two households in one Gemeindebau. The list reads this off the snapshot
    /// now rather than re-running the grouping per row.
    @Test func carriesTheSameDoorCountForEveryStop() throws {
        // Two of them at one door, written identically; the third somewhere
        // else entirely, at its own coordinate.
        let a = customer("Fam. Gruber", at: 1, strasse: "Gentzgasse 129/1")
        let b = customer("Fam. Novak", at: 2, strasse: "Gentzgasse 129/1")
        let c = customer("Fam. Berger", at: 3, strasse: "Währinger Straße 4")
        let r = try route([a, b, c])
        let snap = RouteSnapshot(r)
        #expect(snap.doorCount(a) == 2)
        #expect(snap.doorCount(b) == 2)
        #expect(snap.doorCount(c) == 1)
    }
}

/// `counts` exists so the stop list never builds a route's worth of
/// one-element arrays just to take `.count` off them. It has to answer exactly
/// what `groups` would have.
@MainActor
struct SameDoorCountTests {

    private func stop(
        _ kunde: String, _ strasse: String, _ plz: String, lat: Double
    ) -> Stop {
        Stop(kind: .customer, kunde: kunde, strasse: strasse, plz: plz,
             lat: lat, lon: 16.35)
    }

    @Test func countsAgreeWithTheGroupsTheyReplace() {
        // Three at one address written two ways, one somewhere else — so the
        // answer is a mix of group sizes rather than one flat number.
        let stops = [
            stop("Fam. A", "Gentzgasse 129/1", "1180", lat: 48.2301),
            stop("Fam. B", "Gentzgasse 129/1", "1180", lat: 48.2301),
            stop("Fam. C", "Gentzgasse 129 Stg 1", "1180", lat: 48.2301),
            stop("Fam. D", "Hauptstraße 1", "1140", lat: 48.2000),
        ]
        let counts = SameDoor.counts(for: stops)
        #expect(counts == SameDoor.groups(for: stops).mapValues(\.count))
        #expect(counts[stops[0].id] == 3)
        #expect(counts[stops[3].id] == 1)
    }

    @Test func areEmptyForARouteWithNoCustomers() {
        let start = Stop(kind: .start, lat: 48.2, lon: 16.3)
        #expect(SameDoor.counts(for: [start]).isEmpty)
    }
}

/// The two places a string this app builds leaves it for somebody else to
/// parse: the server address a driver types, and the address handed to a
/// navigation app.
struct HandoffAndUpstreamTests {

    @Test func aTypedServerAddressNeedsASchemeThisAppCanFetch() {
        #expect(Upstreams.isUsableOverride("https://osrm.example.com"))
        #expect(Upstreams.isUsableOverride("https://osrm.example.com:5000"))
        // The two ways a phone keyboard gets this wrong, a scheme URLSession
        // will not fetch, and plain http — which App Transport Security refuses
        // before the request leaves the phone. All four used to be accepted and
        // then silently ignored in favour of the default.
        #expect(!Upstreams.isUsableOverride("osrm.example.com"))
        #expect(!Upstreams.isUsableOverride("https:/osrm.example.com"))
        #expect(!Upstreams.isUsableOverride("ftp://osrm.example.com"))
        #expect(!Upstreams.isUsableOverride("http://192.168.1.10:5000"))
    }

    @Test func trailingSlashesAreNotPartOfTheBaseURL() {
        #expect(
            Upstreams.overrideURL("https://osrm.example.com///")?.absoluteString
                == "https://osrm.example.com")
    }

    /// `+` is legal in a query string, which is exactly the problem: every maps
    /// service decodes it as a space, so an unescaped one puts a hole in the
    /// address the driver is being sent to.
    @Test func escapesAPlusInAnAddress() throws {
        let url = try #require(NavigationHandoff.Provider.apple.address("A+B-Gasse 1, 1100 Wien"))
        #expect(url.absoluteString.contains("%2B"))
        #expect(!url.absoluteString.contains("+"))
    }

    /// Even an exactly-known stop goes over as its address — street and
    /// housenumber, without the Stiege no navigation app can search for.
    @Test func sendsAnExactlyKnownStopAsItsAddress() {
        let stop = Stop(
            kind: .customer, kunde: "Fam. A", strasse: "Gentzgasse 129/1", plz: "1180",
            lat: 48.2301, lon: 16.3201)
        let url = NavigationHandoff.url(for: stop)?.absoluteString ?? ""
        #expect(url.contains("Gentzgasse%20129,%201180%20Wien"))
        #expect(!url.contains("129/1"))
        #expect(!url.contains("48.230100"))
    }

    /// The register's entrance for the house number goes over as a point.
    @Test func sendsTheEntranceWhenItIsKnown() {
        let stop = Stop(
            kind: .customer, kunde: "Fam. A", strasse: "Gentzgasse 129/1", plz: "1180",
            lat: 48.2301, lon: 16.3201)
        stop.setEntrance((48.23054851, 16.33060367))
        #expect(NavigationHandoff.destination(for: stop) == .point(lat: 48.23054851, lon: 16.33060367))
    }

    /// A pin placed by hand beats the entrance: the driver stood at the door.
    @Test func aHandPlacedPinBeatsTheEntrance() {
        let stop = Stop(
            kind: .customer, kunde: "Fam. A", strasse: "Gentzgasse 129", plz: "1180",
            lat: 48.2305, lon: 16.3310, pinned: true)
        stop.setEntrance((48.23054851, 16.33060367))
        #expect(NavigationHandoff.destination(for: stop) == .point(lat: 48.2305, lon: 16.3310))
    }

    /// An entrance that is not a usable point is ignored, not driven to.
    @Test func anUnusableEntranceFallsBackToTheAddress() {
        let stop = Stop(
            kind: .customer, kunde: "Fam. A", strasse: "Gentzgasse 129", plz: "1180",
            lat: 48.2301, lon: 16.3201)
        stop.setEntrance((0, 0))
        #expect(NavigationHandoff.destination(for: stop) == .address("Gentzgasse 129, 1180 Wien, Österreich"))
    }

    /// Picking the number the entrance layer files an address under.
    @Test func readsTheEntranceNumberOffTheRegistersNumber() {
        #expect(Geocoder.entranceNumber("82") == "82")
        #expect(Geocoder.entranceNumber("82-92") == "82")
        #expect(Geocoder.entranceNumber("82/1") == "82")
        #expect(Geocoder.entranceNumber("82 Kindertagesheim") == "82")
        #expect(Geocoder.entranceNumber("12A") == "12a")
        #expect(Geocoder.entranceNumber("12a/3") == "12a")
        #expect(Geocoder.entranceNumber("Parz. 5") == nil)
    }

    /// The prefix query returns "129a" and "1290" for "129"; only 129 counts.
    @Test func picksOnlyTheExactEntrance() {
        func entrance(_ number: String, _ plz: String = "1180", lat: Double) -> Geocoder.EntranceFeature {
            Geocoder.EntranceFeature(
                geometry: Geocoder.OGDGeometry(coordinates: [16.33, lat]),
                properties: Geocoder.EntranceProperties(number: number, plz: plz))
        }
        let features = [
            entrance("1290", lat: 48.231), entrance("129a", lat: 48.232),
            entrance("129", "1170", lat: 48.233), entrance("129", lat: 48.234),
        ]
        #expect(Geocoder.pickEntrance(features, number: "129", plz: "1180")?.lat == 48.234)
        #expect(Geocoder.pickEntrance(features, number: "129a", plz: "1180")?.lat == 48.232)
        #expect(Geocoder.pickEntrance(features, number: "12", plz: "1180") == nil)
    }

    /// The fallback for a stop with no address text: a point, to six places.
    @Test func thePointFallbackKeepsSixPlaces() {
        let url = NavigationHandoff.Provider.apple.point(lat: 48.2301, lon: 16.3201)
        #expect(url?.absoluteString.contains("48.230100,16.320100") == true)
    }
}

/// Searching the stop list.
///
/// The filter is `RouteDetailView`'s, but the thing it turns on is
/// `AddressText.matchKey` — so what is pinned here is that a driver typing on a
/// phone keyboard, one-handed, finds the stop that is sitting right in front of
/// them. Every other search in the app already folded; this field did not, and
/// a search that finds nothing does not read as "type it differently", it reads
/// as a tour that has lost a customer.
struct StopSearchFoldingTests {

    /// The filter, as the list applies it: every token has to appear somewhere
    /// in the row.
    private func matches(_ needle: String, _ fields: [String]) -> Bool {
        let tokens = AddressText.matchKey(needle)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return true }
        let haystack = AddressText.matchKey(fields.joined(separator: " "))
        return tokens.allSatisfy { haystack.contains($0) }
    }

    @Test func findsAnUmlautAddressTypedWithoutOne() {
        #expect(matches("waehringer", ["Fam. Gruber", "Währinger Straße 4", "1180"]))
        #expect(matches("doebling", ["Fr. Berger", "Döblinger Hauptstraße 1", "1190"]))
    }

    @Test func findsASharpSTypedAsDoubleS() {
        #expect(matches("grosse neugasse", ["Hr. Novak", "Große Neugasse 12", "1040"]))
    }

    /// And the other way round — typed *with* the umlaut against a list that
    /// was exported without one.
    @Test func foldsBothSidesNotJustTheQuery() {
        #expect(matches("Währinger", ["Fam. Gruber", "Waehringer Strasse 4", "1180"]))
    }

    /// The abbreviation a dispatch list is full of.
    @Test func findsAStreetWrittenTheOtherTwoWays() {
        #expect(matches("hauptstrasse", ["Fr. Berger", "Hauptstr. 3", "1180"]))
        #expect(matches("hauptstraße", ["Fr. Berger", "Hauptstr. 3", "1180"]))
    }

    /// Punctuation between the driver and the row is not a reason to hide it.
    @Test func punctuationDoesNotBlockAMatch() {
        #expect(matches("fam gruber", ["Fam. Gruber", "Gentzgasse 129/1", "1180"]))
        #expect(matches("129 1", ["Fam. Gruber", "Gentzgasse 129/1", "1180"]))
    }

    /// Paket and Notiz stay searchable — that is where the day's real detail
    /// lives, and folding must not quietly drop them.
    @Test func stillSearchesThePaketAndTheNote() {
        #expect(matches("menue", ["Fam. Gruber", "Gentzgasse 129", "1180", "2x Menü"]))
        #expect(matches("hund", ["Fam. Gruber", "Gentzgasse 129", "1180", "", "Hund im Hof"]))
    }

    /// It is still a search: a customer who is not there is not found.
    @Test func doesNotMatchSomethingThatIsNotOnTheRow() {
        #expect(!matches("novak", ["Fam. Gruber", "Gentzgasse 129", "1180"]))
        #expect(!matches("gentzgasse 130", ["Fam. Gruber", "Gentzgasse 129", "1180"]))
    }

    /// Every token has to land, so a second word narrows rather than widens.
    @Test func everyTokenHasToMatch() {
        #expect(matches("gruber gentzgasse", ["Fam. Gruber", "Gentzgasse 129", "1180"]))
        #expect(!matches("gruber alser", ["Fam. Gruber", "Gentzgasse 129", "1180"]))
    }
}

/// Taking a delivery back.
///
/// Jetzt's undo banner is the only way back from a thumb that caught
/// "Geliefert" while reaching for "Navigation": the stop leaves the screen the
/// moment it is pressed, and the banner is what puts it back. It lives for six
/// seconds, which is long enough for a driver at a door and far too short to
/// drive from a test — so the rule behind the button is tested here instead.
@MainActor
struct UndoDeliveryTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func seed(_ context: ModelContext) throws -> (Route, Stop, Stop) {
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        let first = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129", plz: "1180",
            lat: 48.2301, lon: 16.3201, orderIndex: 3)
        let second = Stop(
            kind: .customer, kunde: "Hr. Novak", strasse: "Alser Straße 21", plz: "1080",
            lat: 48.2154, lon: 16.3470, orderIndex: 4)
        for s in [first, second] {
            s.route = route
            context.insert(s)
        }
        // Loaded already, and Ziel still ahead: these are about the doors.
        route.stops.first { $0.kind == .via }?.record(.delivered)
        try context.save()
        return (route, first, second)
    }

    @Test func putsTheStopBackOnTheList() throws {
        let context = try makeContext()
        let (route, gruber, _) = try seed(context)
        try RouteStore.setDelivered(gruber, true, in: context)
        #expect(RouteSnapshot(route).deliveredCount == 1)

        #expect(try RouteStore.undoDelivery(gruber.id, on: route, in: context))

        #expect(!gruber.delivered)
        let snapshot = RouteSnapshot(route)
        #expect(snapshot.deliveredCount == 0)
        // And it is the next door again, which is the whole point: the driver
        // is standing in front of it.
        #expect(snapshot.nextOpen?.id == gruber.id)
    }

    /// By id, not by the object the tick was made against. The banner outlives
    /// the card it came from, so what it carries has to still mean the same
    /// stop several seconds and a re-render later.
    @Test func takesBackTheStopItNamesAndNoOther() throws {
        let context = try makeContext()
        let (route, gruber, novak) = try seed(context)
        try RouteStore.setDelivered(gruber, true, in: context)
        try RouteStore.setDelivered(novak, true, in: context)

        #expect(try RouteStore.undoDelivery(novak.id, on: route, in: context))

        #expect(gruber.delivered)
        #expect(!novak.delivered)
    }

    /// A stop deleted from another screen inside the banner's few seconds.
    /// Nothing to take back — and nothing to report, because the delivery went
    /// with the stop.
    @Test func anIdTheRouteNoLongerHasIsANoOp() throws {
        let context = try makeContext()
        let (route, gruber, _) = try seed(context)
        try RouteStore.setDelivered(gruber, true, in: context)
        let goneID = gruber.id
        context.delete(gruber)
        try context.save()

        #expect(try RouteStore.undoDelivery(goneID, on: route, in: context) == false)
        #expect(try RouteStore.undoDelivery(UUID(), on: route, in: context) == false)
    }

    /// Undoing the tick that finished the tour reopens it, rather than leaving
    /// a route that says "Alle geliefert" over a door still owed a meal.
    @Test func reopensATourTheTickHadCompleted() throws {
        let context = try makeContext()
        let (route, gruber, novak) = try seed(context)
        try RouteStore.setDelivered(gruber, true, in: context)
        try RouteStore.setDelivered(novak, true, in: context)
        try RouteStore.setDelivered(
            try #require(route.stops.first { $0.kind == .end }), true, in: context)
        #expect(RouteSnapshot(route).isComplete)

        #expect(try RouteStore.undoDelivery(novak.id, on: route, in: context))

        let snapshot = RouteSnapshot(route)
        #expect(!snapshot.isComplete)
        #expect(snapshot.openCount == 1)
        // The tour was never auto-completed by the tick — see `setDelivered` —
        // so there is no status to wind back either.
        #expect(route.status == .active)
    }

    /// It survives the round trip: taken back, ticked again, taken back again.
    /// The banner offers this after *every* tick, so it is not a one-shot.
    @Test func canBeTakenBackMoreThanOnce() throws {
        let context = try makeContext()
        let (route, gruber, _) = try seed(context)
        for _ in 0..<3 {
            try RouteStore.setDelivered(gruber, true, in: context)
            #expect(gruber.delivered)
            #expect(try RouteStore.undoDelivery(gruber.id, on: route, in: context))
            #expect(!gruber.delivered)
        }
    }
}

/// The two lines the tour screens put under a tour's name.
struct TourSummaryTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    private func tour(delivered: Int, of total: Int, km: Double = 4.0) throws -> Route {
        let context = try makeContext()
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        for fixed in route.stops where fixed.kind.isFixed { fixed.excluded = true }
        for i in 0..<total {
            let stop = Stop(
                kind: .customer, kunde: "Kunde \(i)", strasse: "Gasse \(i)", plz: "1180",
                lat: 48.23, lon: 16.32, orderIndex: 10 + i)
            stop.delivered = i < delivered
            stop.nextLegKm = km
            stop.nextLegMin = 8
            stop.route = route
            context.insert(stop)
        }
        try context.save()
        return route
    }

    /// "Noch 22 Stopps · 18,2 km" rather than "12 von 34 geliefert" — both are
    /// the same fact, and only one of them is the question anybody has at half
    /// past eleven.
    @MainActor
    @Test func arunningTourSaysWhatIsStillAhead() throws {
        let route = try tour(delivered: 1, of: 3)
        let summary = RouteSnapshot(route).summary(of: route)
        #expect(summary.hasPrefix("Noch 2 Stopps"))
        #expect(summary.contains("km"))
    }

    /// A finished tour is history, and history has no "still to drive". It was
    /// answering "Noch 4 Stopps · 11,7 km" under a tour filed in Erledigt — a
    /// forecast about a day that is over.
    @MainActor
    @Test func afinishedTourIsDescribedAsTheDayItWas() throws {
        let route = try tour(delivered: 1, of: 3)
        route.status = .completed
        route.completedAt = Date(timeIntervalSince1970: 1_757_000_000)

        let summary = RouteSnapshot(route).summary(of: route)
        #expect(!summary.contains("Noch"))
        #expect(summary.contains("3 Stopps"))
        // The day it was driven, not a forecast about it.
        #expect(summary.contains(Format.date(Date(timeIntervalSince1970: 1_757_000_000))))
    }

    @MainActor
    @Test func atourWithNothingOnItSaysSo() throws {
        let route = try tour(delivered: 0, of: 0)
        #expect(RouteSnapshot(route).summary(of: route) == "Noch keine Stopps")
    }

    @MainActor
    @Test func everyMealHandedOverLeavesOnlyTheDriveBack() throws {
        let route = try tour(delivered: 2, of: 2)
        let summary = RouteSnapshot(route).summary(of: route)
        #expect(summary.hasPrefix("Alle erledigt"))
        #expect(summary.contains("Rückfahrt"))
    }
}

/// What the three fixed points are called in the list.
struct FixedStopTitleTests {

    @Test func eachFixedPointHasItsOwnName() {
        let names = [StopKind.start, .via, .end].map {
            Stop(kind: $0, lat: 48.2, lon: 16.3).fixedTitle
        }
        #expect(names == ["Start", "Lager", "Ziel"])
        // Three points, three names — a duplicate would put two identically
        // labelled rows at the top of every tour.
        #expect(Set(names).count == 3)
    }

    @Test func aCustomerIsCalledByTheirOwnName() {
        let stop = Stop(kind: .customer, kunde: "Fam. Gruber", lat: 48.2, lon: 16.3)
        #expect(stop.fixedTitle == "Fam. Gruber")
        #expect(Stop(kind: .customer, lat: 48.2, lon: 16.3).fixedTitle == "Stopp")
    }
}

/// Deleting tours, and the packing ticks that do not live in the store.
@MainActor
struct RouteDeletionTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// Swipe-to-delete hands over row offsets into a live `@Query`, and the
    /// save after the first deletion refreshes that array underneath the loop.
    /// Resolving every id up front is what keeps a two-row deletion from taking
    /// out a third tour — or, deleted by the wrong filter, all of them.
    @Test func deletingByIDTakesExactlyThoseTours() throws {
        let context = try makeContext()
        let a = try RouteStore.createRoute(name: "Montag", in: context)
        let b = try RouteStore.createRoute(name: "Dienstag", in: context)
        let c = try RouteStore.createRoute(name: "Mittwoch", in: context)

        try RouteStore.delete(ids: [a.id, c.id], in: context)

        let left = try context.fetch(FetchDescriptor<Route>())
        #expect(left.count == 1)
        #expect(left.first?.id == b.id)
        #expect(left.first?.name == "Dienstag")
    }

    @Test func deletingNothingDeletesNothing() throws {
        let context = try makeContext()
        try RouteStore.createRoute(name: "Montag", in: context)
        try RouteStore.delete(ids: [], in: context)
        try RouteStore.delete(ids: [UUID()], in: context)
        #expect(try context.fetch(FetchDescriptor<Route>()).count == 1)
    }

    /// The stops go with the tour — the relationship's delete rule is cascade,
    /// and a stop left behind unattached is a row nothing will ever show again.
    @Test func theStopsOfADeletedTourGoWithIt() throws {
        let context = try makeContext()
        let route = try RouteStore.createRoute(name: "Montag", in: context)
        let stop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129", plz: "1180",
            lat: 48.23, lon: 16.32)
        stop.route = route
        context.insert(stop)
        try context.save()

        try RouteStore.delete(ids: [route.id], in: context)
        #expect(try context.fetch(FetchDescriptor<Stop>()).isEmpty)
    }
}

/// Which lines of a tour's packing list are ticked off.
///
/// This is the one piece of tour state that lives outside SwiftData, so nothing
/// cascades it away and nothing scopes it for free. Both of those have to be
/// done by hand here — and a checklist shared between tours is a driver opening
/// Tuesday's list to find it already ticked, and driving off without loading
/// the van.
@MainActor
struct LadelisteStateTests {

    private func clean(_ ids: [UUID], _ body: () throws -> Void) rethrows {
        defer { for id in ids { LadelisteState.forget(id) } }
        try body()
    }

    @Test func eachTourHasItsOwnTicks() throws {
        let monday = UUID(), tuesday = UUID()
        try clean([monday, tuesday]) {
            LadelisteState.store(["menü", "suppe"], for: monday)

            #expect(LadelisteState.checked(for: monday) == ["menü", "suppe"])
            // Tuesday's van still has to be loaded.
            #expect(LadelisteState.checked(for: tuesday).isEmpty)

            LadelisteState.store(["diät"], for: tuesday)
            #expect(LadelisteState.checked(for: monday) == ["menü", "suppe"])
            #expect(LadelisteState.checked(for: tuesday) == ["diät"])
        }
    }

    @Test func aTourNobodyHasTickedAnythingOnIsEmpty() {
        #expect(LadelisteState.checked(for: UUID()).isEmpty)
    }

    /// Storing replaces rather than merges — "Zurücksetzen" is one of the two
    /// things that writes here, and it writes an empty set.
    @Test func storingReplacesWhatWasThere() throws {
        let id = UUID()
        try clean([id]) {
            LadelisteState.store(["menü", "suppe"], for: id)
            LadelisteState.store(["menü"], for: id)
            #expect(LadelisteState.checked(for: id) == ["menü"])
            LadelisteState.store([], for: id)
            #expect(LadelisteState.checked(for: id).isEmpty)
        }
    }

    /// The checklist lives in `UserDefaults`, outside the store, so the cascade
    /// delete does not reach it. Without this every deleted tour leaves its
    /// ticks behind in the app's preferences for good.
    @Test func forgettingOneTourLeavesTheOthersAlone() throws {
        let monday = UUID(), tuesday = UUID()
        try clean([monday, tuesday]) {
            LadelisteState.store(["menü"], for: monday)
            LadelisteState.store(["suppe"], for: tuesday)

            LadelisteState.forget(monday)
            #expect(LadelisteState.checked(for: monday).isEmpty)
            #expect(LadelisteState.checked(for: tuesday) == ["suppe"])
        }
    }

    /// The mode is an override, not a setting: absent until the driver picks
    /// one, so a tour nobody has switched by hand keeps following its name —
    /// including after a rename.
    @Test func aTourNobodyHasSwitchedHasNoStoredMode() {
        #expect(LadelisteState.mode(for: UUID()) == nil)
    }

    @Test func thePickedModeSticksToItsOwnTour() {
        let tk = UUID(), vm = UUID()
        clean([tk, vm]) {
            LadelisteState.store(LadelisteMode.tk, for: tk)

            #expect(LadelisteState.mode(for: tk) == .tk)
            #expect(LadelisteState.mode(for: vm) == nil)

            LadelisteState.store(LadelisteMode.vm, for: vm)
            #expect(LadelisteState.mode(for: tk) == .tk)
            #expect(LadelisteState.mode(for: vm) == .vm)
        }
    }

    /// The mode lives in `UserDefaults` next to the ticks and has to be cleaned
    /// up with them, or a new tour that happens to reuse a deleted tour's id
    /// opens in somebody else's mode.
    @Test func forgettingATourForgetsItsModeToo() {
        let id = UUID()
        clean([id]) {
            LadelisteState.store(LadelisteMode.tk, for: id)
            LadelisteState.forget(id)
            #expect(LadelisteState.mode(for: id) == nil)
        }
    }

    /// And deleting the tour is what triggers that, which is the half that has
    /// to be remembered by hand at every call site.
    @Test func deletingATourForgetsItsTicks() throws {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = try RouteStore.createRoute(name: "Montag", in: context)
        let id = route.id
        try clean([id]) {
            LadelisteState.store(["menü"], for: id)
            try RouteStore.delete(ids: [id], in: context)
            #expect(LadelisteState.checked(for: id).isEmpty)
        }
    }
}

/// "Zuerst anfahren" was removed. A stop still carrying the old flag from
/// before is planned like every other customer, not pinned to the front.
@MainActor
struct RemovedPriorityTests {
    @Test func theOldPriorityFlagIsPlannedLikeAnyCustomer() throws {
        let container = try ModelContainer(
            for: Route.self, Stop.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let urgent = Stop(kind: .customer, kunde: "A", strasse: "Gentzgasse 1", plz: "1180",
                          lat: 48.2301, lon: 16.3201)
        urgent.prioritaet = true
        urgent.route = route
        context.insert(urgent)
        try context.save()

        let (nodes, _) = RouteOptimizer.snapshot(route)
        #expect(nodes.customers.map(\.id) == [urgent.id])
        #expect(!nodes.head.contains { $0.id == urgent.id })
    }
}
