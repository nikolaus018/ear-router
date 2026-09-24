import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// The day, in the form somebody else has to hear it.
///
/// The report is read off stops already in the store and invents nothing. What
/// these pin down is the part that is a judgement rather than a sum: which
/// customers end up on the list somebody has to act on, and what the message
/// that leaves the phone actually says.
@MainActor
struct TourReportTests {

    private func store() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private let noon = Date(timeIntervalSince1970: 1_757_000_000)

    @discardableResult
    private func add(
        _ name: String, to route: Route, in context: ModelContext,
        outcome: DeliveryOutcome? = nil, at offsetMinutes: Double = 0,
        telefon: String? = nil, km: Double? = nil
    ) -> Stop {
        let stop = Stop(
            kind: .customer, kunde: name, strasse: "Gentzgasse \(name)", plz: "1180",
            telefon: telefon, lat: 48.23, lon: 16.32,
            orderIndex: route.stops.count + 10)
        stop.nextLegKm = km
        stop.route = route
        context.insert(stop)
        if let outcome {
            stop.record(outcome, at: noon.addingTimeInterval(offsetMinutes * 60))
        }
        return stop
    }

    private func emptyRoute(in context: ModelContext) -> Route {
        let route = Route(name: "Tour 14.09.2026")
        context.insert(route)
        return route
    }

    /// The one list anybody reads. A meal left with a neighbour arrived and an
    /// abbestellt customer was never owed one; the door nobody opened is the
    /// only outcome that ends the day owing somebody an explanation.
    @Test func onlyAnUnansweredDoorReachesTheFollowUpList() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        add("Geliefert", to: route, in: context, outcome: .delivered)
        add("Nachbar", to: route, in: context, outcome: .neighbour)
        add("Abbestellt", to: route, in: context, outcome: .cancelled)
        add("Niemand da", to: route, in: context, outcome: .notHome)
        try context.save()

        let report = TourReport(route)

        #expect(report.notHome.map(\.name) == ["Niemand da"])
        #expect(report.deliveredCount == 1)
        #expect(report.neighbourCount == 1)
        #expect(report.cancelledCount == 1)
        #expect(report.handedOverCount == 2)
        #expect(report.customerCount == 4)
        #expect(report.needsAttention)
    }

    /// A tour closed early leaves customers who were never driven to at all.
    /// That is a different failure from a locked door and is reported as one.
    @Test func customersNeverDrivenToAreListedSeparately() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        add("Fertig", to: route, in: context, outcome: .delivered)
        add("Nie hingefahren", to: route, in: context)
        try context.save()

        let report = TourReport(route)

        #expect(report.notHome.isEmpty)
        #expect(report.stillOpen.map(\.name) == ["Nie hingefahren"])
        #expect(report.needsAttention)
    }

    /// A clean day has nothing for anybody to do.
    @Test func aTourWhereEverybodyGotTheirMealNeedsNoAttention() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        add("A", to: route, in: context, outcome: .delivered)
        add("B", to: route, in: context, outcome: .delivered)
        try context.save()

        let report = TourReport(route)
        #expect(!report.needsAttention)
        #expect(report.notHome.isEmpty)
        #expect(report.stillOpen.isEmpty)
    }

    /// The shift ran between the first and last door answered for — taken off
    /// the *times*, sorted, not off the ends of the driving order. Ticks are
    /// not always made in order.
    @Test func theShiftRunsBetweenTheEarliestAndLatestTime() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        add("Zuerst", to: route, in: context, outcome: .delivered, at: 0)
        // Settled last but sitting third in the list.
        add("Zuletzt", to: route, in: context, outcome: .delivered, at: 120)
        add("Dazwischen", to: route, in: context, outcome: .delivered, at: 60)
        try context.save()

        let report = TourReport(route)

        #expect(report.firstStop == noon)
        #expect(report.lastStop == noon.addingTimeInterval(120 * 60))
        #expect(report.timeSpan?.contains("2 h 0 min") == true)
    }

    /// Abbestellt is ticked in the yard, when the office rings — before the
    /// first door. It used to start the shift there.
    @Test func anAbbestelltTickDoesNotStartTheShift() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        add("Abbestellt", to: route, in: context, outcome: .cancelled, at: -90)
        add("Erste Tür", to: route, in: context, outcome: .delivered, at: 0)
        add("Letzte Tür", to: route, in: context, outcome: .delivered, at: 60)
        try context.save()

        let report = TourReport(route)
        #expect(report.firstStop == noon)
        #expect(report.cancelledCount == 1)
    }

    /// Every tour already on the phone was driven before stops carried a time.
    /// The report still works; it simply says nothing about the clock.
    @Test func aTourWithNoRecordedTimesReportsNoSpan() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        let stop = add("A", to: route, in: context)
        stop.delivered = true
        try context.save()

        let report = TourReport(route)
        #expect(report.firstStop == nil)
        #expect(report.timeSpan == nil)
        #expect(!report.text.isEmpty)
    }

    /// The message that leaves the phone. The names come before the kilometres
    /// because nobody has ever rung about the kilometres.
    @Test func theSharedTextNamesTheCustomersSomebodyHasToRing() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        add("Fam. Gruber", to: route, in: context, outcome: .delivered, at: 0, km: 3.2)
        add(
            "Fr. Novak", to: route, in: context, outcome: .notHome, at: 30,
            telefon: "0664 1234567")
        try context.save()

        let text = TourReport(route).text

        #expect(text.contains("Tour 14.09.2026"))
        #expect(text.contains("Geliefert: 1 von 2 Stopps"))
        #expect(text.contains("Nicht angetroffen (1):"))
        #expect(text.contains("Fr. Novak"))
        // The number is in it: the whole content of the call that follows.
        #expect(text.contains("0664 1234567"))
        // And the address, so nobody has to go and look it up.
        #expect(text.contains("1180"))

        let names = text.range(of: "Fr. Novak")
        let km = text.range(of: "Strecke laut Planung")
        #expect(names != nil)
        #expect(km != nil)
        if let names, let km { #expect(names.lowerBound < km.lowerBound) }
    }

    /// Lines nobody needs are simply absent. A report listing "Bei Nachbarn
    /// abgegeben: 0" on every ordinary day is a report that stops being read.
    @Test func outcomesThatDidNotHappenAreLeftOutOfTheText() throws {
        let context = try store()
        let route = emptyRoute(in: context)
        add("A", to: route, in: context, outcome: .delivered)
        try context.save()

        let text = TourReport(route).text
        #expect(!text.contains("Bei Nachbarn"))
        #expect(!text.contains("Abbestellt"))
        #expect(!text.contains("Nicht angetroffen"))
    }
}
