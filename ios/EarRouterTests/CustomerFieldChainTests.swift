import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// Everything a customer stop carries, end to end through the import chain.
///
/// A day's list reaches a tour through four hops — the portal's own shape, the
/// `CustomerJSON` the app speaks, the `Entry` the review screen owns, and the
/// `Stop` that finally lands — and every one of them copies the fields across
/// by hand. A hop that forgets one loses it for every customer on every tour,
/// silently, because there is nothing about a missing Paket or a missing
/// telephone number that looks like a failure.
///
/// That has already happened once here, in the backup, and it shipped. These
/// are the same guard for the other direction: each hop tested with a distinct
/// value per field, plus a check that the set of fields itself has not grown
/// past what the hops copy.
@MainActor
struct CustomerFieldChainTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// One entry with every field set to something recognisably its own, so a
    /// field copied from its neighbour fails as loudly as one dropped.
    private var full: CustomerJSON {
        CustomerJSON(
            kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1", plz: "1180",
            paket: "2x Menü", notiz: "Bitte laut klingeln",
            telefon: "+4369910842229", paketCount: 3)
    }

    private func check(_ entry: CustomerJSON, _ note: Comment? = nil) {
        #expect(entry.kunde == "Fam. Gruber", note)
        #expect(entry.strasse == "Gentzgasse 129/1", note)
        #expect(entry.plz == "1180", note)
        #expect(entry.paket == "2x Menü", note)
        #expect(entry.notiz == "Bitte laut klingeln", note)
        #expect(entry.telefon == "+4369910842229", note)
        #expect(entry.paketCount == 3, note)
    }

    // MARK: - Hop by hop

    /// The review screen owns the list from the moment it is parsed, and it is
    /// the only way into `importJSON` — a JSON paste and a portal import both
    /// arrive here. A field `Entry` does not carry is a field no import can
    /// ever write.
    @Test func everyFieldSurvivesTheReviewScreen() {
        check(ImportReviewView.Entry(full).json, "lost crossing the review screen")
    }

    /// The JSON editor shows the tour as text and takes it back. A field the
    /// export leaves out is a field the driver's own re-paste then deletes
    /// from every stop it touches.
    @Test func everyFieldSurvivesExportAndPasteBack() throws {
        let context = try makeContext()
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        let stop = Stop(
            kind: .customer, kunde: full.kunde, strasse: full.strasse, plz: full.plz,
            paket: full.paket, paketCount: full.paketCount, notiz: full.notiz,
            telefon: full.telefon,
            lat: 48.2301, lon: 16.3201)
        stop.route = route
        context.insert(stop)
        try context.save()

        let text = RouteStore.exportJSON(route)
        let parsed = try RouteStore.parseImport(text)
        #expect(parsed.count == 1)
        check(try #require(parsed.first), "lost between exportJSON and parseImport")
    }

    /// And the last hop: the paste landing on a stop that is already there.
    ///
    /// The addresses match, so nothing is geocoded and no route is optimised —
    /// which is what makes the write path testable without a network at all.
    @Test func everyFieldIsWrittenWhenAPasteUpdatesAStop() async throws {
        let context = try makeContext()
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        let stop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", lat: 48.2301, lon: 16.3201)
        stop.route = route
        context.insert(stop)
        try context.save()

        let result = try await RouteStore.importJSON([full], into: route, in: context)

        #expect(result.updated == 1)
        #expect(result.inserted == 0)
        #expect(result.deleted == 0)
        #expect(stop.kunde == "Fam. Gruber")
        #expect(stop.strasse == "Gentzgasse 129/1")
        #expect(stop.plz == "1180")
        #expect(stop.paket == "2x Menü")
        #expect(stop.paketCount == 3)
        #expect(stop.notiz == "Bitte laut klingeln")
        #expect(stop.telefon == "+4369910842229")
        // Nothing moved, so the route is not flagged for reoptimising over a
        // changed Notiz — see `importJSON`.
        #expect(!route.needsOptimize)
    }

    /// Re-pasting the same list changes nothing and says so. The counterpart
    /// to the test above: "Aktualisiert: 30" for an import that touched
    /// nothing is what made every row in the store dirty for a morning.
    @Test func anUnchangedPasteUpdatesNothing() async throws {
        let context = try makeContext()
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        let stop = Stop(
            kind: .customer, kunde: full.kunde, strasse: full.strasse, plz: full.plz,
            paket: full.paket, paketCount: full.paketCount, notiz: full.notiz,
            telefon: full.telefon,
            lat: 48.2301, lon: 16.3201)
        stop.route = route
        context.insert(stop)
        try context.save()

        let result = try await RouteStore.importJSON([full], into: route, in: context)
        #expect(result.updated == 0)
        #expect(result.inserted == 0)
        #expect(result.deleted == 0)
    }

    // MARK: - The guard for the next field

    /// What a customer stop carries, named once.
    ///
    /// The hops above pin the fields that exist today. This fails the moment
    /// the set changes, so a seventh field cannot be added to one end of the
    /// chain and quietly not to the other — which is exactly how the backup
    /// lost `telefon`.
    @Test func theFieldsOfACustomerEntryAreAccountedFor() {
        let json = Set(Mirror(reflecting: full).children.compactMap(\.label))
        #expect(json == ["kunde", "strasse", "plz", "paket", "paketCount", "notiz", "telefon"])

        let entry = Set(
            Mirror(reflecting: ImportReviewView.Entry(full)).children.compactMap(\.label))
        #expect(entry == [
            "kunde", "strasse", "plz", "paket", "notiz", "telefon", "paketCount",
            // The row's own identity, so five identical meals for one
            // institution stay five editable rows — see `Entry`.
            "id",
        ])
    }

    /// An entry that carries none of the optional fields still crosses every
    /// hop as itself, rather than picking up empty strings on the way.
    @Test func theOptionalFieldsStayAbsentRatherThanBecomingEmpty() throws {
        let bare = CustomerJSON(
            kunde: "Hr. Novak", strasse: "Alser Straße 21", plz: "1080",
            paket: nil, notiz: nil, telefon: nil)

        let throughReview = ImportReviewView.Entry(bare).json
        #expect(throughReview.paket == nil)
        #expect(throughReview.notiz == nil)
        #expect(throughReview.telefon == nil)

        // And blank-but-present values are the same thing as absent, so a
        // driver who clears a field is not storing a space.
        let blank = CustomerJSON(
            kunde: "Hr. Novak", strasse: "Alser Straße 21", plz: "1080",
            paket: "  ", notiz: "", telefon: " ")
        let cleaned = ImportReviewView.Entry(blank).json
        #expect(cleaned.paket == nil)
        #expect(cleaned.notiz == nil)
        #expect(cleaned.telefon == nil)
    }
}
