import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// The checklist that runs while the van is still in the yard.
///
/// The judgement in it is which findings are worth stopping for. A checklist
/// that cries wolf gets swiped past, and one that stays silent about
/// yesterday's ticks lets a driver set off on a list where half the doors are
/// already struck through.
@MainActor
struct PreflightTests {

    private func store() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    /// A tour that is ready: optimized, geometry drawn, every address exact.
    private func readyRoute(in context: ModelContext, customers: Int = 3) throws -> Route {
        let route = Route(name: "Tour")
        route.needsOptimize = false
        route.geometryFlat = [48.2, 16.3, 48.21, 16.31]
        context.insert(route)
        for i in 0..<customers {
            let s = Stop(
                kind: .customer, kunde: "K\(i)", strasse: "Gentzgasse \(i)", plz: "1180",
                lat: 48.23, lon: 16.32, orderIndex: i)
            s.nextLegKm = 1
            s.nextLegMin = 5
            s.route = route
            context.insert(s)
        }
        try context.save()
        return route
    }

    /// A fixed afternoon in Vienna, so "today" is the same day whenever and
    /// wherever the suite runs.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private var yesterday: Date { now.addingTimeInterval(-86_400) }
    private var thisMorning: Date { now.addingTimeInterval(-4 * 3_600) }
    private var vienna: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return calendar
    }

    private func check(_ route: Route, floorsKnown: Set<UUID> = []) -> Preflight {
        Preflight(
            route: route, snapshot: RouteSnapshot(route), floorsKnown: floorsKnown,
            now: now, calendar: vienna)
    }

    private func finding(_ preflight: Preflight, _ id: String) -> Preflight.Finding? {
        preflight.findings.first { $0.id == id }
    }

    /// Nothing wrong: the route reports ready, and still says so out loud
    /// rather than showing an empty screen.
    @Test func aTourWithNothingWrongReportsReady() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        let stops = route.customerStops.map(\.id)

        let preflight = check(route, floorsKnown: Set(stops))

        #expect(preflight.isReady)
        #expect(preflight.problems.isEmpty)
        #expect(finding(preflight, "optimize")?.severity == .ok)
        #expect(finding(preflight, "pins")?.severity == .ok)
    }

    /// A route whose stop order was never solved is the one thing here that
    /// makes everything else on the screen wrong too.
    @Test func aRouteThatWasNeverOptimizedIsAProblem() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        route.needsOptimize = true

        let preflight = check(route)
        #expect(!preflight.isReady)
        #expect(finding(preflight, "optimize")?.severity == .problem)
        #expect(finding(preflight, "optimize")?.action == .optimize)
    }

    /// An approximate pin is a building the van cannot actually be driven to.
    @Test func anApproximateAddressIsAProblemWithARemedy() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        let stop = try #require(route.customerStops.first)
        stop.precision = .street

        let preflight = check(route)
        let pins = try #require(finding(preflight, "pins"))
        #expect(pins.severity == .problem)
        #expect(pins.action == .recheckAddresses)
        #expect(pins.detail?.contains("K0") == true)
    }

    /// A pin the driver placed by hand outranks the geocoder — they stood in
    /// front of the building. It is not a finding.
    @Test func aHandPlacedPinIsNotAnApproximateAddress() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        let stop = try #require(route.customerStops.first)
        stop.precision = .street
        stop.pinned = true

        #expect(finding(check(route), "pins")?.severity == .ok)
    }

    /// The one that looks like nothing and costs the most: a whole tour still
    /// carrying yesterday's answers. A driver skips those doors and finds out
    /// at four o'clock.
    @Test func aTourStillFullyTickedOffFromYesterdayIsAProblem() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        for stop in route.customerStops { stop.record(.delivered, at: yesterday) }

        let preflight = check(route)
        let settled = try #require(finding(preflight, "settled"))
        #expect(settled.severity == .problem)
        #expect(settled.action == .resetDelivered)
        #expect(!preflight.isReady)
    }

    /// Part-way through is the ordinary state of a tour at eleven in the
    /// morning. Today's ticks are the tour being driven, not a finding — and
    /// certainly not one carrying a button that clears them.
    @Test func todaysTicksAreProgressAndNotAFinding() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        try #require(route.customerStops.first).record(.delivered, at: thisMorning)

        let preflight = check(route)
        #expect(finding(preflight, "settled") == nil)
        #expect(preflight.isReady)
    }

    /// One door still ticked from an earlier day is a door the driver will skip
    /// today, whatever else on the tour has been ticked since.
    @Test func oneTickFromAnEarlierDayAmongTodaysIsStillAProblem() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        let stops = route.customerStops
        stops[0].record(.delivered, at: yesterday)
        stops[1].record(.delivered, at: thisMorning)

        let settled = try #require(finding(check(route), "settled"))
        #expect(settled.severity == .problem)
        #expect(settled.title.hasPrefix("1 Stopp"))
    }

    /// An abbestellt entered the evening before is about today's delivery, not
    /// a leftover from the last one — resetting it would put a meal back on the
    /// round for somebody who cancelled it.
    @Test func anAbbestelltFromLastNightIsNotALeftoverTick() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        try #require(route.customerStops.first).record(.cancelled, at: yesterday)

        #expect(finding(check(route), "settled") == nil)
    }

    /// A tick with no time on it predates timestamps, so it is from an earlier
    /// day by definition.
    @Test func aTickWithNoTimeIsFromAnEarlierDay() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        let stop = try #require(route.customerStops.first)
        stop.delivered = true
        stop.settledAt = nil

        #expect(finding(check(route), "settled")?.severity == .problem)
    }

    /// A door nobody opened counts as answered for here too — it is still a
    /// row a driver would skip tomorrow.
    @Test func aDoorNobodyOpenedCountsAsAlreadyAnsweredFor() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        for stop in route.customerStops { stop.record(.notHome, at: yesterday) }

        #expect(finding(check(route), "settled")?.severity == .problem)
    }

    /// An empty tour is the only finding worth making — everything else would
    /// be a report about nothing.
    @Test func anEmptyTourSaysOnlyThat() throws {
        let context = try store()
        let route = Route(name: "Leer")
        context.insert(route)
        try context.save()

        let preflight = check(route)
        #expect(preflight.findings.count == 1)
        #expect(preflight.findings.first?.id == "empty")
        #expect(!preflight.isReady)
    }

    /// Unknown floors are the normal state of a new customer and the app asks
    /// at the door anyway. Worth knowing it is twelve and not one; not worth
    /// waiting for.
    @Test func unknownFloorsAreANoteRatherThanAProblem() throws {
        let context = try store()
        let route = try readyRoute(in: context)

        let preflight = check(route, floorsKnown: [])
        #expect(finding(preflight, "stockwerke")?.severity == .note)
        #expect(finding(preflight, "stockwerke")?.title.contains("3") == true)
        #expect(preflight.isReady)
    }

    /// And nothing at all once every stairwell is known.
    @Test func nothingIsSaidWhenEveryFloorIsAlreadyKnown() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        let preflight = check(route, floorsKnown: Set(route.customerStops.map(\.id)))
        #expect(finding(preflight, "stockwerke") == nil)
    }

    /// "Zuerst anfahren" is gone: a stop still carrying the old flag is not
    /// read back as coming first.
    @Test func theOldPriorityFlagIsIgnored() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        try #require(route.customerStops.first).prioritaet = true
        #expect(finding(check(route), "vorrang") == nil)
    }

    /// Worst first, so the screen opens on the thing that matters.
    @Test func problemsSortToTheTop() throws {
        let context = try store()
        let route = try readyRoute(in: context)
        route.needsOptimize = true
        try #require(route.customerStops.first).precision = .district

        let severities = check(route).findings.map(\.severity)
        #expect(severities == severities.sorted(by: >))
    }
}
