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

    private func fixed(_ kind: StopKind, excluded: Bool = false, km: Double? = nil) -> Stop {
        let s = Stop(kind: kind, kunde: "Fix", strasse: Coordinates.startAddress,
                     plz: Coordinates.startPlz,
                     lat: Coordinates.start.lat, lon: Coordinates.start.lon,
                     excluded: excluded)
        s.nextLegKm = km
        s.nextLegMin = km
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
        #expect(snap.openCount == 2)
    }

    /// A leg belongs to the stop it leaves from, so ticking off the first
    /// customer means the depot leg, the warehouse leg and that customer's own
    /// leg into the next one are behind the van — the last of those is not,
    /// because the driver is standing at the stop it starts from.
    @Test func deliveringAStopLeavesOnlyTheLegsFromItOnwards() throws {
        let r = try route([
            fixed(.start, km: 20),
            fixed(.via, km: 5),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            customer("B", at: 2, km: 3, minutes: 6),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.totalKm == 30)
        // Everything before A's own leg is driven; A → B and B → Ziel are not.
        #expect(snap.remainingKm == 5)
        #expect(snap.remainingMinutes == 10)
        #expect(snap.openCount == 1)
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
    /// drive is real, it is the only thing left, and reporting zero would have
    /// the app quietly claim the day is over while the driver is 20 km out.
    @Test func aFinishedTourStillCarriesTheDriveBack() throws {
        let r = try route([
            fixed(.start, km: 20),
            customer("A", at: 1, delivered: true, km: 2, minutes: 4),
            customer("B", at: 2, delivered: true, km: 18, minutes: 25),
            fixed(.end),
        ])
        let snap = RouteSnapshot(r)
        #expect(snap.isComplete)
        #expect(snap.openCount == 0)
        #expect(snap.remainingKm == 18)
        #expect(snap.remainingMinutes == 25)
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
