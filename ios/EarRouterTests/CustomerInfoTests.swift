import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// What this app keeps about a customer across every tour: which floor they
/// live on, and whatever the driver wrote down.
///
/// The floor was the first of these anybody kept and gave the table its name.
/// The note is the same kind of thing — it never changes, no list the office
/// sends carries it, and it outlives every tour that visits the customer. It is
/// deliberately one free-text field rather than a form of labelled boxes: the
/// list of things worth noting at a door has no end, and one line to type into
/// is faster to fill in standing at one.
@MainActor
struct CustomerInfoTests {

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

    @Test func theFloorAndTheNoteAreStoredAgainstTheCustomer() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(
            CustomerInfo(stockwerk: "3", notiz: "Klingelt nicht, klopfen. Türcode 0123."),
            for: stop, in: context)

        let note = try #require(try StockwerkStore.note(for: stop, in: context))
        #expect(note.stockwerk == "3")
        #expect(note.notiz == "Klingelt nicht, klopfen. Türcode 0123.")
        #expect(note.kunde == "Fam. Gruber")
    }

    /// The rule the value type exists for: a caller that has only been told a
    /// floor must not be able to throw away a note it never saw.
    ///
    /// This is how a note written in March got wiped by a floor corrected in
    /// May, back when every save wrote every column from whatever the one
    /// screen in front of the driver happened to be holding.
    @Test func correctingTheFloorKeepsTheNote() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(
            CustomerInfo(stockwerk: "3", notiz: "Hund"), for: stop, in: context)
        // The narrow save — what a tick at the door goes through.
        try StockwerkStore.save(stockwerk: "4", dontAsk: false, for: stop, in: context)

        let note = try #require(try StockwerkStore.note(for: stop, in: context))
        #expect(note.stockwerk == "4")
        #expect(note.notiz == "Hund")
    }

    /// A customer nothing is known about is a row's absence, not a row full of
    /// blanks.
    @Test func anAnswerThatSaysNothingDeletesTheRow() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(CustomerInfo(stockwerk: "3"), for: stop, in: context)
        #expect(try StockwerkStore.note(for: stop, in: context) != nil)

        try StockwerkStore.save(CustomerInfo(), for: stop, in: context)
        #expect(try StockwerkStore.note(for: stop, in: context) == nil)
    }

    /// But clearing only the floor, on a customer whose note is the one thing
    /// anybody ever learned about them, keeps the row.
    @Test func clearingTheFloorDoesNotDeleteACustomerStillWorthKnowingAbout() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(
            CustomerInfo(stockwerk: "3", notiz: "Nachbarin Tür 12 nimmt an"),
            for: stop, in: context)
        try StockwerkStore.save(stockwerk: "", dontAsk: false, for: stop, in: context)

        let note = try #require(try StockwerkStore.note(for: stop, in: context))
        #expect(note.stockwerk == nil)
        #expect(note.notiz == "Nachbarin Tür 12 nimmt an")
    }

    /// Whitespace is not an answer. " " and "" and nothing at all are one
    /// state, or the same customer reads as known on one screen and unknown on
    /// the next.
    @Test func blankFieldsAreStoredAsNothingAtAll() {
        let info = CustomerInfo(stockwerk: "  ", notiz: "")
        #expect(info.stockwerk == nil)
        #expect(info.notiz == nil)
        #expect(info.isBlank)
    }

    /// The prompt after a delivery still turns on the floor alone. A customer
    /// with a note but no stairwell is one the app should still ask about.
    @Test func theFloorIsWhatDecidesWhetherToAsk() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        #expect(StockwerkStore.shouldAsk(stop, in: context))

        try StockwerkStore.save(CustomerInfo(notiz: "Hund"), for: stop, in: context)
        #expect(StockwerkStore.shouldAsk(stop, in: context))

        try StockwerkStore.save(
            CustomerInfo(stockwerk: "3", notiz: "Hund"), for: stop, in: context)
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
                CustomerInfo(stockwerk: floor, notiz: "Hund"), for: stop, in: context)
        }

        #expect(try StockwerkStore.all(in: context).count == 1)
    }

    // MARK: - How a floor reads

    /// A bare number is said out; the two lettered picks are what is written on
    /// the doorbell panel and are left exactly as they are. "EG. Stock" is not
    /// a thing anybody says.
    @Test(arguments: [
        ("3", "3. Stock"), ("6", "6. Stock"),
        ("EG", "EG"), ("DG", "DG"),
        ("2/Tür 14", "2/Tür 14"), ("Mezzanin", "Mezzanin"),
    ])
    func aFloorReadsTheWayItIsWritten(input: String, shown: String) {
        #expect(Format.floor(input) == shown)
    }

    /// VoiceOver gets the spelled-out form, where the short one would be read
    /// letter by letter.
    @Test func voiceOverSpellsTheLetteredFloorsOut() {
        #expect(StockwerkForm.spokenFloor("EG") == "Erdgeschoss")
        #expect(StockwerkForm.spokenFloor("DG") == "Dachgeschoss")
        #expect(StockwerkForm.spokenFloor("3") == "3. Stock")
    }

    // MARK: - Handing the round to somebody else

    /// A stand-in driver takes the round for a week. All of this lives on one
    /// phone, and it travels as a `BackupArchive` with no tours in it so that
    /// the receiving phone reads it through the merge it already has.
    @Test func customerInfoSurvivesTheTripToAnotherPhone() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(
            CustomerInfo(stockwerk: "3", notiz: "Hund. Türcode 0123."),
            for: stop, in: context)

        var archive = BackupArchive()
        archive.stockwerke = try StockwerkStore.all(in: context)
            .map(BackupArchive.StockwerkBackup.init)
        let decoded = try BackupArchive.decode(archive.encoded())

        let fresh = try store()
        let result = try BackupRestore.apply(decoded, mode: .merge, in: fresh)
        #expect(result.stockwerkeWritten == 1)
        #expect(result.routesAdded == 0)

        let landed = try #require(try StockwerkStore.all(in: fresh).first)
        #expect(landed.stockwerk == "3")
        #expect(landed.notiz == "Hund. Türcode 0123.")
    }

    /// A file from the build where this row was briefly three fields opens with
    /// all three folded into the one note, rather than losing two thirds of
    /// what somebody wrote down.
    @Test func aFileFromTheSplitFieldBuildFoldsBackIntoOneNote() throws {
        let json = """
        {
          "format": "ear-router-backup",
          "version": 1,
          "createdAt": "2026-09-14T10:00:00Z",
          "routes": [],
          "stockwerke": [{
            "key": "fam gruber|gentzgasse 129 1|1180",
            "kunde": "Fam. Gruber",
            "strasse": "Gentzgasse 129/1",
            "plz": "1180",
            "stockwerk": "3",
            "tuerNotiz": "Klingelt nicht, klopfen",
            "tuercode": "0123",
            "langeLaeuten": true,
            "dontAsk": false,
            "updatedAt": "2026-09-14T10:00:00Z"
          }]
        }
        """
        let archive = try BackupArchive.decode(Data(json.utf8))
        let row = try #require(archive.stockwerke.first)

        #expect(row.stockwerk == "3")
        let note = try #require(row.notiz)
        #expect(note.contains("Klingelt nicht, klopfen"))
        #expect(note.contains("Türcode 0123"))
        #expect(note.contains("Lange läuten"))
    }

    /// And what this build writes carries the one note and none of the three.
    @Test func whatIsWrittenNowCarriesOnlyTheNote() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(
            CustomerInfo(stockwerk: "3", notiz: "Hund"), for: stop, in: context)

        var archive = BackupArchive()
        archive.stockwerke = try StockwerkStore.all(in: context)
            .map(BackupArchive.StockwerkBackup.init)
        let text = String(decoding: try archive.encoded(), as: UTF8.self)

        #expect(text.contains("\"notiz\""))
        #expect(!text.contains("tuerNotiz"))
        #expect(!text.contains("tuercode"))
        #expect(!text.contains("langeLaeuten"))
    }
}
