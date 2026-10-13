import Testing
import Foundation
import PDFKit
@testable import EarRouter

/// A portal tour as a printed list.
struct TourPDFTests {

    private let day = Date(timeIntervalSince1970: 1_791_540_000)

    private func entry(_ name: String, strasse: String, paketCount: Int? = nil) -> CustomerJSON {
        CustomerJSON(
            kunde: name, strasse: strasse, plz: "1210", paket: "1x Vitalmenü EP TGM5",
            notiz: "persönlich", paketCount: paketCount)
    }

    @Test func rowsFollowTheOrderTheyAreHandedIn() {
        let pdf = TourPDF(tourName: "VM 5 FR Vormittag", day: day, entries: [
            entry("B", strasse: "Puffergasse 1/4/8"), entry("A", strasse: "Nordmanngasse 15/6"),
        ])
        #expect(pdf.rows.map(\.kunde) == ["B", "A"])
        #expect(pdf.rows.map(\.number) == [1, 2])
        #expect(pdf.rows[0].paket == "1x Vitalmenü EP TGM5")
    }

    @MainActor
    @Test func unplacedDeliveriesGoToTheEndWithoutARoutingCall() async throws {
        // One point is not a trip: no network, and the unplaced ones follow.
        let order = try await PortalDrivingOrder.order([nil, (lat: 48.25, lon: 16.4), nil])
        #expect(order == [1, 0, 2])
    }

    @Test func aTKTourShowsParcelsNotDishes() {
        let pdf = TourPDF(tourName: "Tk1", day: day, entries: [
            entry("A", strasse: "Nordmanngasse 15/6", paketCount: 3),
            entry("B", strasse: "Puffergasse 1/4/8", paketCount: 1),
            entry("C", strasse: "Gerichtsgasse 12/2/5"),
        ])
        #expect(pdf.rows.map(\.paket) == ["3 Pakete", "1 Paket", ""])
    }

    @MainActor
    @Test func theFloorComesFromTheGlobaleInfosWithoutTheirNote() throws {
        let a = entry("A", strasse: "Nordmanngasse 15/6")
        let note = StockwerkNote(
            key: try #require(StockwerkKey.make(kunde: a.kunde, strasse: a.strasse, plz: a.plz)),
            kunde: "A", strasse: a.strasse, plz: "1210", stockwerk: "3", notiz: "Hund")

        let pdf = TourPDF(
            tourName: "VM 5 FR Vormittag", day: day,
            entries: [a, entry("B", strasse: "Puffergasse 1/4/8")], notes: [note])
        #expect(pdf.rows.map(\.stockwerk) == ["3. Stock", ""])
        #expect(pdf.rows[0].hinweis == "persönlich")
    }

    @Test func aLongTourRunsOverSeveralPages() throws {
        let entries = (0..<30).map { entry("Kunde \($0)", strasse: "Gasse \($0 + 1)") }
        let pdf = TourPDF(tourName: "VM 5 FR Vormittag", day: day, entries: entries)

        let document = try #require(PDFDocument(data: pdf.data()))
        #expect(document.pageCount == 3)
        let first = try #require(document.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == CGSize(width: 842, height: 595))
        let text = first.string ?? ""
        #expect(text.contains("Seite 1 von 3"))
        // Whole, on one line: the column once broke it before its last digit.
        #expect(text.contains(Format.numericDate(day)))
        #expect(text.contains("Hinweis"))
        #expect(document.page(at: 1)?.string?.contains("Hinweis") == false)
    }

    @Test func theFileIsNamedAfterTheTourAndItsDay() {
        let pdf = TourPDF(tourName: "VM 5/FR", day: day, entries: [])
        #expect(pdf.filename == "VM 5-FR \(Format.numericDate(day)).pdf")
    }
}
