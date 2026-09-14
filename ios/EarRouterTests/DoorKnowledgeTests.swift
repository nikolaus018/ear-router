import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// What is known about a customer's door, and the rule that keeps one of those
/// facts from throwing away another.
///
/// The floor was the first of these anybody wrote down; the Türcode, the bell
/// that has to be held and the driver's own words about the place are the same
/// kind of thing — they never change, no list the office sends carries them,
/// and they outlive every tour that visits the customer.
@MainActor
struct DoorKnowledgeTests {

    private func store() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func customer(_ name: String = "Fam. Gruber") -> Stop {
        Stop(
            kind: .customer, kunde: name, strasse: "Gentzgasse 129/1", plz: "1180",
            lat: 48.2301, lon: 16.3201)
    }

    /// Everything written together, read back together, under one customer.
    @Test func everythingLearnedAtADoorIsStoredAgainstTheCustomer() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(
            DoorKnowledge(
                stockwerk: "3", tuerNotiz: "Klingelt nicht, klopfen",
                tuercode: "1234", langeLaeuten: true),
            for: stop, in: context)

        let note = try #require(try StockwerkStore.note(for: stop, in: context))
        #expect(note.stockwerk == "3")
        #expect(note.tuerNotiz == "Klingelt nicht, klopfen")
        #expect(note.tuercode == "1234")
        #expect(note.langeLaeuten)
        #expect(note.kunde == "Fam. Gruber")
    }

    /// The rule the whole value type exists for: a caller that has only been
    /// told a floor must not be able to throw away a Türcode it never saw.
    ///
    /// This is how a code learned in March got wiped by a floor corrected in
    /// May, back when every save wrote every column from whatever the one
    /// screen in front of the driver happened to be holding.
    @Test func correctingTheFloorKeepsEverythingElseAboutTheDoor() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(
            DoorKnowledge(stockwerk: "3", tuercode: "1234", langeLaeuten: true),
            for: stop, in: context)
        // The narrow save — what a tick at the door goes through.
        try StockwerkStore.save(stockwerk: "4", dontAsk: false, for: stop, in: context)

        let note = try #require(try StockwerkStore.note(for: stop, in: context))
        #expect(note.stockwerk == "4")
        #expect(note.tuercode == "1234")
        #expect(note.langeLaeuten)
    }

    /// A customer nothing is known about is a row's absence, not a row full of
    /// blanks.
    @Test func anAnswerThatSaysNothingDeletesTheRow() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(DoorKnowledge(stockwerk: "3"), for: stop, in: context)
        #expect(try StockwerkStore.note(for: stop, in: context) != nil)

        try StockwerkStore.save(DoorKnowledge(), for: stop, in: context)
        #expect(try StockwerkStore.note(for: stop, in: context) == nil)
    }

    /// But clearing only the floor, on a customer whose Türcode is the one
    /// thing anybody ever learned about them, keeps the row.
    @Test func clearingTheFloorDoesNotDeleteADoorStillWorthKnowingAbout() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(
            DoorKnowledge(stockwerk: "3", tuercode: "1234"), for: stop, in: context)
        try StockwerkStore.save(stockwerk: "", dontAsk: false, for: stop, in: context)

        let note = try #require(try StockwerkStore.note(for: stop, in: context))
        #expect(note.stockwerk == nil)
        #expect(note.tuercode == "1234")
    }

    /// Whitespace is not an answer. " " and "" and nothing at all are one
    /// state, or the same door reads as known on one screen and unknown on the
    /// next.
    @Test func blankFieldsAreStoredAsNothingAtAll() {
        let knowledge = DoorKnowledge(stockwerk: "  ", tuerNotiz: "", tuercode: "   ")
        #expect(knowledge.stockwerk == nil)
        #expect(knowledge.tuerNotiz == nil)
        #expect(knowledge.tuercode == nil)
        #expect(knowledge.isBlank)
    }

    /// The floor has its own line on every row in the app, so it is never part
    /// of the strip that reports everything else.
    @Test func theFloorIsNotOneOfTheDoorFacts() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(
            DoorKnowledge(stockwerk: "3", tuercode: "1234", langeLaeuten: true),
            for: stop, in: context)

        let note = try #require(try StockwerkStore.note(for: stop, in: context))
        let facts = note.doorFacts.map(\.text)

        #expect(facts.contains("Lange läuten"))
        #expect(facts.contains("Türcode 1234"))
        #expect(!facts.contains { $0.contains("3. Stock") })
    }

    /// The prompt after a delivery still turns on the floor alone. A customer
    /// whose Türcode is known but whose stairwell is not is one the app should
    /// still ask about.
    @Test func theFloorIsWhatDecidesWhetherToAsk() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        #expect(StockwerkStore.shouldAsk(stop, in: context))

        try StockwerkStore.save(DoorKnowledge(tuercode: "1234"), for: stop, in: context)
        #expect(StockwerkStore.shouldAsk(stop, in: context))

        try StockwerkStore.save(
            DoorKnowledge(stockwerk: "3", tuercode: "1234"), for: stop, in: context)
        #expect(!StockwerkStore.shouldAsk(stop, in: context))
    }

    /// One row per customer, however many times they are written to — the rule
    /// `StockwerkStore` has always existed to keep.
    @Test func repeatedWritesStillLeaveOneRowPerCustomer() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        for floor in ["1", "2", "3"] {
            try StockwerkStore.save(
                DoorKnowledge(stockwerk: floor, tuercode: "1234"), for: stop, in: context)
        }

        #expect(try StockwerkStore.all(in: context).count == 1)
    }

    /// The office's cipher, decoded where the answer is kept rather than on a
    /// screen that throws it away.
    @Test func theOfficeCipherDecodesIntoSomethingWorthStoring() {
        #expect(Tuercode.decode("CEZD") == "0123")
        // Already digits: decoding changes nothing, which is what the sheet
        // checks before offering the button at all.
        #expect(Tuercode.decode("1234") == "1234")
    }

    // MARK: - Handing the round to somebody else

    /// A stand-in driver takes the round for a week. All of this lives on one
    /// phone, and it travels as a `BackupArchive` with no tours in it so that
    /// the receiving phone reads it through the merge it already has.
    @Test func doorKnowledgeSurvivesTheTripToAnotherPhone() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(
            DoorKnowledge(
                stockwerk: "3", tuerNotiz: "Hund", tuercode: "1234", langeLaeuten: true),
            for: stop, in: context)

        var archive = BackupArchive()
        archive.stockwerke = try StockwerkStore.all(in: context)
            .map(BackupArchive.StockwerkBackup.init)
        let decoded = try BackupArchive.decode(archive.encoded())

        // Onto a phone that has never heard of this customer.
        let fresh = try store()
        let result = try BackupRestore.apply(decoded, mode: .merge, in: fresh)
        #expect(result.stockwerkeWritten == 1)
        #expect(result.routesAdded == 0)

        let landed = try #require(try StockwerkStore.all(in: fresh).first)
        #expect(landed.stockwerk == "3")
        #expect(landed.tuerNotiz == "Hund")
        #expect(landed.tuercode == "1234")
        #expect(landed.langeLaeuten)
    }
}
