import Testing
@testable import EarRouter

/// The address logic decides which door a van is sent to. Every case here is a
/// real Viennese address shape that the Rust version was corrected for at some
/// point — these exist so those corrections cannot silently regress.
struct AddressTextTests {

    // MARK: - normalize

    @Test func collapsesTheThreeSpellingsOfStrasse() {
        #expect(AddressText.normalize("Hauptstr. 5") == "Hauptstraße 5")
        #expect(AddressText.normalize("Hauptstrasse 5") == "Hauptstraße 5")
        #expect(AddressText.normalize("Hauptstraße  5") == "Hauptstraße 5")
    }

    @Test func doesNotRewriteStrInsideAWord() {
        // "Strindberggasse" must survive: the abbreviation rule only fires on
        // "str." followed by space, end, or a digit.
        #expect(AddressText.normalize("Strindberggasse 1") == "Strindberggasse 1")
    }

    @Test func trimsAndCollapsesWhitespace() {
        #expect(AddressText.normalize("  Gentzgasse   129  ") == "Gentzgasse 129")
    }

    // MARK: - simplifyHousenumber

    @Test func stripsStiegeAndTuerForGeocoders() {
        #expect(AddressText.simplifyHousenumber("Gentzgasse 129/1/2/23") == "Gentzgasse 129")
    }

    @Test func keepsAHousenumberRangeWhole() {
        // Vienna's register indexes "Gutzkowplatz 2-5" as its own address,
        // distinct from "2" and from "5" — collapsing it could match the wrong
        // building rather than simply failing to match.
        #expect(AddressText.simplifyHousenumber("Gutzkowplatz 2-5") == "Gutzkowplatz 2-5")
    }

    @Test func leavesAPlaceNameWithNoHousenumberAlone() {
        #expect(AddressText.simplifyHousenumber("Am Hof") == "Am Hof")
    }

    // MARK: - housenumberWithSub

    @Test func readsASlashSeparatedStiege() throws {
        let sub = try #require(AddressText.housenumberWithSub("Gentzgasse 129/1"))
        #expect(sub.query == "Gentzgasse 129/1")
        #expect(sub.key == "1")
    }

    @Test func readsASpaceSeparatedParzelleAndAsksWithASlash() throws {
        // The driver writes it with a space; the register only answers to the
        // slash form.
        let sub = try #require(AddressText.housenumberWithSub("Großfeldstraße 9 Parz. 68"))
        #expect(sub.query == "Großfeldstraße 9/Parz. 68")
        #expect(sub.key == "parz68")
    }

    @Test func bothSpellingsOfAParzelleProduceTheSameKey() throws {
        let slash = try #require(AddressText.housenumberWithSub("Großfeldstraße 9/Parz.68"))
        let spaced = try #require(AddressText.housenumberWithSub("Großfeldstraße 9 Parz. 68"))
        #expect(slash.key == spaced.key)
    }

    @Test func keepsOnlyTheFirstSegmentAfterTheHousenumber() throws {
        // "129/1/2/23" is Stiege 1, then Stock and Tür that no register indexes.
        let sub = try #require(AddressText.housenumberWithSub("Gentzgasse 129/1/2/23"))
        #expect(sub.key == "1")
    }

    @Test func aBareHousenumberHasNoSubAddress() {
        #expect(AddressText.housenumberWithSub("Hauptstraße 12") == nil)
        #expect(AddressText.housenumberWithSub("Gentzgasse 129/") == nil)
    }

    // MARK: - subAddressOf

    @Test func readsBackWhatTheRegisterMatched() {
        #expect(AddressText.subAddressOf("Großfeldstraße 9 Parz. 68") == "parz68")
        #expect(AddressText.subAddressOf("Gentzgasse 129/1") == "1")
    }

    @Test func aRegisterAnswerWithNoSubAddressReadsAsNone() {
        #expect(AddressText.subAddressOf("Hauptstraße 12") == nil)
    }

    // MARK: - matchKey

    @Test func oneDoorWrittenThreeWaysIsOneKey() {
        // This is what decides whether a re-pasted list edits a stop or deletes
        // and re-inserts it — and re-inserting loses the delivered tick.
        let a = AddressText.matchKey("Großfeldstraße 9/Parz.68")
        let b = AddressText.matchKey("Großfeldstraße 9 Parz. 68")
        let c = AddressText.matchKey("Großfeldstrasse 9 / Parz. 68")
        #expect(a == b)
        #expect(b == c)
    }

    @Test func separatorsAreCollapsedNotDeleted() {
        // Deleting them would make these two different doors collide.
        #expect(AddressText.matchKey("Gentzgasse 129/1") != AddressText.matchKey("Gentzgasse 12/91"))
    }

    // MARK: - streetNameOnly

    @Test func dropsTheHousenumberForCrossChecking() {
        #expect(AddressText.streetNameOnly("Gentzgasse 129/1") == "Gentzgasse")
        #expect(AddressText.streetNameOnly("Am Hof") == "Am Hof")
    }
}
