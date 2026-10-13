import Testing
import Foundation
import PDFKit
import SwiftData
@testable import EarRouter

/// The tour as a printed list.
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

        let document = try #require(PDFDocument(data: TourPDF(route).data()))
        #expect(document.pageCount == 3)
        let first = try #require(document.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == CGSize(width: 842, height: 595))
        let text = first.string ?? ""
        #expect(text.contains("Seite 1 von 3"))
        // Whole, on one line: the column once broke it before its last digit.
        #expect(text.contains(Format.numericDate(route.createdAt)))
        #expect(text.contains("Hinweis"))
        #expect(document.page(at: 1)?.string?.contains("Hinweis") == false)
    }

    @Test func theFileIsNamedAfterTheTourAndItsDay() {
        let route = Route(name: "VM 5/FR")
        route.createdAt = Date(timeIntervalSince1970: 1_791_540_000)
        #expect(TourPDF(route).filename == "VM 5-FR \(Format.numericDate(route.createdAt)).pdf")
    }
}
