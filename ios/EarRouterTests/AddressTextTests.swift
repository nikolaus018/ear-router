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

/// One rule for every search field in the app.
///
/// Three lists are searched — the tour's stops, the portal's deliveries, the
/// saved floors — and a driver learns one search field, not three. These pin
/// the two things that rule promises: a query survives a phone keyboard without
/// umlauts, and its words may be typed in any order.
struct SearchTests {

    /// What the tour list searches over: the customer, the address, the Paket
    /// and the Notiz, folded into one haystack.
    private let stop = AddressText.matchKey(
        "Fam. Gruber Gentzgasse 129/1 1180 2x Menü Bitte laut klingeln")

    @Test func everyWordHasToAppearSomewhere() {
        #expect(AddressText.Search("gruber").matches(stop))
        #expect(AddressText.Search("gruber gentzgasse").matches(stop))
        #expect(!AddressText.Search("gruber alserstraße").matches(stop))
    }

    /// The order words are typed in is the order they are remembered in, not
    /// the order the row stores them.
    @Test func theWordsMayComeInAnyOrder() {
        #expect(AddressText.Search("gentzgasse gruber").matches(stop))
        #expect(AddressText.Search("1180 menü gruber").matches(stop))
    }

    /// A phone keyboard held in one hand, in the rain.
    @Test func aQuerySurvivesBeingTypedWithoutUmlauts() {
        let doebling = AddressText.matchKey("Fam. Novak Döblinger Hauptstraße 1 1190")
        #expect(AddressText.Search("doeblinger").matches(doebling))
        #expect(AddressText.Search("Döblinger").matches(doebling))
        #expect(AddressText.Search("grosse").matches(AddressText.matchKey("Große Neugasse 4")))
    }

    /// The driver can find a stop by something they only remember from its
    /// note, which is where the day's real detail lives.
    @Test func theNoteAndThePaketAreSearchableToo() {
        #expect(AddressText.Search("klingeln").matches(stop))
        #expect(AddressText.Search("menü").matches(stop))
    }

    @Test func aQueryWithNothingSearchableInItIsEmpty() {
        #expect(AddressText.Search("").isEmpty)
        #expect(AddressText.Search("   ").isEmpty)
        #expect(AddressText.Search("/ - ,").isEmpty)
        #expect(!AddressText.Search("gruber").isEmpty)
    }

    // MARK: - The saved-floor list, whose row keeps its text in two pieces

    /// `StockwerkKey.make` writes the customer, street and postcode either side
    /// of a separator — "fam gruber|gentzgasse 129 1|1180" — so a search
    /// matched as one substring could never span two of them. That is exactly
    /// what this list did, while the tour's own list found the same household.
    @Test func aFloorIsFoundByCustomerAndStreetTogether() throws {
        let key = try #require(
            StockwerkKey.make(kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1", plz: "1180"))
        let floor = AddressText.matchKey("3")
        #expect(AddressText.Search("gruber gentzgasse").matches(key, or: floor))
        #expect(AddressText.Search("gruber").matches(key, or: floor))
        #expect(AddressText.Search("1180").matches(key, or: floor))
        #expect(!AddressText.Search("gruber alserstraße").matches(key, or: floor))
    }

    /// And the floor itself is searchable, which is the other half a single
    /// haystack could not have covered.
    @Test func aFloorIsAlsoFoundByWhatWasTypedIntoIt() throws {
        let key = try #require(
            StockwerkKey.make(kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1", plz: "1180"))
        let floor = AddressText.matchKey("Dachgeschoss")
        #expect(AddressText.Search("dachgeschoss").matches(key, or: floor))
        #expect(AddressText.Search("gruber dachgeschoss").matches(key, or: floor))
    }
}
