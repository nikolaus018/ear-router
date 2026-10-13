import Testing
import Foundation
import PDFKit
import SwiftData
@testable import EarRouter

/// The tour as a printed list, and the split it can suggest.
@MainActor
struct TourPDFTests {

    private func store() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    @discardableResult
    private func add(
        _ name: String, strasse: String, to route: Route, in context: ModelContext,
        lat: Double, legMin: Double? = nil
    ) -> Stop {
        let stop = Stop(
            kind: .customer, kunde: name, strasse: strasse, plz: "1210",
            paket: "1x Vitalmenü EP TGM5", notiz: "persönlich", lat: lat, lon: 16.4,
            orderIndex: route.stops.count + 10)
        stop.nextLegMin = legMin
        stop.route = route
        context.insert(stop)
        return stop
    }

    private func door(_ minutes: Double = 7, drive: Double = 0, stops: Int = 1) -> TourSplit.Door {
        TourSplit.Door(stops: stops, minutes: minutes, driveMinutes: drive)
    }

    // MARK: The split

    @Test func equalDoorsAreSplitEvenly() {
        let parts = TourSplit.suggest(Array(repeating: door(drive: 2), count: 9), people: 3)
        #expect(parts == [0..<3, 3..<6, 6..<9])
    }

    @Test func longDrivesCountAgainstAShare() {
        // Four doors on one staircase, then four with ten minutes between each.
        let doors = Array(repeating: door(), count: 4) + Array(repeating: door(drive: 10), count: 4)
        let parts = TourSplit.suggest(doors, people: 2)
        #expect(parts == [0..<5, 5..<8])
    }

    @Test func theDriveACutRunsThroughIsNobodys() {
        // Two clusters an hour apart: the cut belongs in the gap.
        let doors = [door(), door(drive: 1), door(drive: 60), door(drive: 1)]
        #expect(TourSplit.suggest(doors, people: 2) == [0..<2, 2..<4])
    }

    @Test func neverMoreSharesThanDoors() {
        #expect(TourSplit.suggest([door(), door()], people: 5) == [0..<1, 1..<2])
        #expect(TourSplit.suggest([], people: 3).isEmpty)
        #expect(TourSplit.suggest([door(), door()], people: 1) == [0..<2])
    }

    @Test func householdsAtOneDoorStayWithOnePerson() throws {
        let context = try store()
        let route = Route(name: "VM 5 FR Vormittag")
        context.insert(route)
        add("A", strasse: "Nordmanngasse 15/6", to: route, in: context, lat: 48.25, legMin: 3)
        add("B", strasse: "Puffergasse 1/4/8", to: route, in: context, lat: 48.26, legMin: 0)
        add("C", strasse: "Puffergasse 1/4/8", to: route, in: context, lat: 48.26, legMin: 3)
        add("D", strasse: "Gerichtsgasse 12/2/5", to: route, in: context, lat: 48.27)

        let pdf = TourPDF(route, people: 4, history: .none)
        // Three doors, so three shares, and B and C in the same one.
        #expect(pdf.shares.map(\.range) == [0..<1, 1..<3, 3..<4])
        #expect(pdf.shares[1].minutes == 7 + 7 * RouteSnapshot.Pace.sharedDoor)
    }

    // MARK: The list

    @Test func abbestellteStoppsAreLeftOut() throws {
        let context = try store()
        let route = Route(name: "VM 5 FR Vormittag")
        context.insert(route)
        add("A", strasse: "Nordmanngasse 15/6", to: route, in: context, lat: 48.25)
        add("B", strasse: "Puffergasse 1/4/8", to: route, in: context, lat: 48.26)
            .record(.cancelled)
        add("C", strasse: "Gerichtsgasse 12/2/5", to: route, in: context, lat: 48.27)

        let pdf = TourPDF(route)
        #expect(pdf.rows.map(\.kunde) == ["A", "C"])
        #expect(pdf.rows.map(\.number) == [1, 2])
        #expect(pdf.shares.isEmpty)
    }

    @Test func theFloorComesFromTheGlobaleInfosWithoutTheirNote() throws {
        let context = try store()
        let route = Route(name: "VM 5 FR Vormittag")
        context.insert(route)
        let a = add("A", strasse: "Nordmanngasse 15/6", to: route, in: context, lat: 48.25)
        add("B", strasse: "Puffergasse 1/4/8", to: route, in: context, lat: 48.26)
        context.insert(StockwerkNote(
            key: try #require(StockwerkKey.make(for: a)), kunde: "A",
            strasse: "Nordmanngasse 15/6", plz: "1210", stockwerk: "3", notiz: "Hund"))

        let pdf = TourPDF(route)
        #expect(pdf.rows.map(\.stockwerk) == ["3. Stock", ""])
        #expect(pdf.rows[0].hinweis == "persönlich")
    }

    @Test func aLongTourRunsOverSeveralPages() throws {
        let context = try store()
        let route = Route(name: "VM 5 FR Vormittag")
        context.insert(route)
        for i in 0..<30 {
            add("Kunde \(i)", strasse: "Gasse \(i + 1)", to: route, in: context,
                lat: 48.2 + Double(i) / 1000, legMin: 2)
        }

        let document = try #require(PDFDocument(data: TourPDF(route, people: 3, history: .none).data()))
        #expect(document.pageCount == 3)
        let first = try #require(document.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == CGSize(width: 842, height: 595))
        let text = first.string ?? ""
        #expect(text.contains("Seite 1 von 3"))
        // Whole, on one line: the column once broke it before its last digit.
        #expect(text.contains(Format.numericDate(route.createdAt)))
        #expect(text.contains("Hinweis"))
        #expect(text.contains("Person 1 von 3"))
        #expect(document.page(at: 1)?.string?.contains("Hinweis") == false)
    }

    @Test func theFileIsNamedAfterTheTourAndItsDay() {
        let route = Route(name: "VM 5/FR")
        route.createdAt = Date(timeIntervalSince1970: 1_791_540_000)
        #expect(TourPDF(route).filename == "VM 5-FR \(Format.numericDate(route.createdAt)).pdf")
    }
}
