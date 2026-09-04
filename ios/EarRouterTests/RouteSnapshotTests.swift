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

    @Test func sendsAnExactlyKnownStopAsAPoint() {
        let stop = Stop(
            kind: .customer, kunde: "Fam. A", strasse: "Gentzgasse 129/1", plz: "1180",
            lat: 48.2301, lon: 16.3201)
        let url = NavigationHandoff.Provider.apple.point(lat: stop.lat, lon: stop.lon)
        #expect(url?.absoluteString.contains("48.230100,16.320100") == true)
    }
}
