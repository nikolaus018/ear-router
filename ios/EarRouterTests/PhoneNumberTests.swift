import Testing
@testable import EarRouter

/// The call button on Jetzt appears only for a number that really is one. A
/// button that dials a door code is worse than no button at all.
struct PhoneNumberTests {

    @Test func findsAMobileNumberInANote() throws {
        let found = try #require(PhoneNumbers.find(in: "Bitte 1 Stunde vorher anrufen: 0664 1234567").first)
        #expect(found.dial == "06641234567")
        #expect(found.url?.absoluteString == "tel:06641234567")
    }

    @Test func keepsTheInternationalPrefix() throws {
        let found = try #require(PhoneNumbers.find(in: "Tochter: +43 664 123 45 67").first)
        #expect(found.dial == "+436641234567")
    }

    @Test func readsAViennaLandlineWrittenWithASlash() throws {
        let found = try #require(PhoneNumbers.find(in: "Tel. 01/234 56 78").first)
        #expect(found.dial == "012345678")
    }

    @Test func offersEachNumberOnce() {
        let found = PhoneNumbers.find(in: "0664 1234567 oder 0664 1234567, sonst 0676 7654321")
        #expect(found.map(\.dial) == ["06641234567", "06767654321"])
    }

    /// The short numbers every note is full of: none of them is a telephone.
    @Test func ignoresDoorCodesFloorsAndPostcodes() {
        #expect(PhoneNumbers.find(in: "Türcode 4711, Stiege 3, Tür 14, 2. Stock").isEmpty)
        #expect(PhoneNumbers.find(in: "Abgeben bei 1210 Wien, Tür 7").isEmpty)
    }

    /// What else a note is full of that is long enough to be mistaken for a
    /// telephone number: a date, a time, a customer number, an IBAN. The
    /// detector leaves every one of them alone, and this pins that it does.
    @Test func ignoresDatesTimesAndAccountNumbers() {
        #expect(PhoneNumbers.find(in: "Ab 04.09.2026 im Urlaub").isEmpty)
        #expect(PhoneNumbers.find(in: "Nicht vor 11:30 läuten").isEmpty)
        #expect(PhoneNumbers.find(in: "KDNr 26064642").isEmpty)
        #expect(PhoneNumbers.find(in: "IBAN AT61 1904 3002 3457 3201").isEmpty)
    }

    /// "+43 (0) 664 …" is how a number is written for people both in and out
    /// of the country; the bracketed trunk zero must not be dialled.
    @Test func dropsTheBracketedTrunkZero() throws {
        let found = try #require(PhoneNumbers.find(in: "Sohn: +43 (0) 664 7654321").first)
        #expect(found.dial == "+436647654321")
    }

    @Test func aNoteWithNoDigitsHasNoNumbers() {
        #expect(PhoneNumbers.find(in: "Hund im Hof, bitte laut klingeln").isEmpty)
        #expect(PhoneNumbers.find(in: nil).isEmpty)
    }

    // MARK: - A trusted number, as stored on `Stop.telefon`

    /// No detector, no digit-count floor: `telefon` is a customer's own
    /// number straight from the Zusteller-Portal, not a heuristic guess out
    /// of free text.
    @Test func normalizesAPlainNumberForDialling() {
        #expect(PhoneNumbers.normalizedDial("0664 123 45 67") == "06641234567")
        #expect(PhoneNumbers.dialURL(for: "0664 123 45 67")?.absoluteString == "tel:06641234567")
    }

    @Test func keepsTheLeadingPlusOnATrustedNumber() {
        #expect(PhoneNumbers.normalizedDial("+43 699 10842229") == "+4369910842229")
    }

    @Test func blankOrDigitlessGivesNoDialURL() {
        #expect(PhoneNumbers.normalizedDial("   ") == nil)
        #expect(PhoneNumbers.dialURL(for: "") == nil)
    }
}

/// One number, one button — whichever of the three Austrian notations each
/// side of the comparison happens to be written in.
///
/// The Zusteller-Portal hands over `customer.phone` as "+4369910842229"; the
/// driver's own note for the same household says "0699 10842229". Compared as
/// text those are two numbers, so Jetzt offered "Anrufen" and
/// "0699 10842229 anrufen" side by side, dialling the same person.
struct SameNumberTests {

    @Test func theThreeNotationsOfOneNumberAreOneNumber() {
        let key = PhoneNumbers.sameNumberKey
        #expect(key("+4369910842229") == key("069910842229"))
        #expect(key("004369910842229") == key("069910842229"))
        #expect(key("+43664123456") == key("0664123456"))
        // A Vienna landline, written both ways.
        #expect(key("+43123456789") == key("0123456789"))
    }

    @Test func differentNumbersStayDifferent() {
        let key = PhoneNumbers.sameNumberKey
        #expect(key("+436641234567") != key("06767654321"))
        #expect(key("06641234567") != key("06641234568"))
    }

    /// An area code that itself begins with the country code's digits — 043xx
    /// is real (Kärnten) — must not have them mistaken for a prefix.
    @Test func anAreaCodeThatLooksLikeAPrefixIsLeftAlone() {
        let key = PhoneNumbers.sameNumberKey
        #expect(key("+43431234567") == key("0431234567"))
        #expect(key("0431234567") != key("01234567"))
    }

    /// Nothing collapses onto the empty string, which would make every
    /// fragment equal to every other.
    @Test func aFragmentIsNotStrippedToNothing() {
        #expect(!PhoneNumbers.sameNumberKey("+43").isEmpty)
        #expect(!PhoneNumbers.sameNumberKey("0").isEmpty)
    }

    // MARK: - What the two screens actually offer

    @Test func theCustomersOwnNumberGetsNoSecondButtonFromTheNote() {
        let found = PhoneNumbers.inNote(
            "Bitte 1 Stunde vorher anrufen: 0699 10842229",
            besides: "+4369910842229")
        #expect(found.isEmpty)
    }

    @Test func anotherNumberInTheNoteStillGetsItsButton() throws {
        let found = PhoneNumbers.inNote(
            "Tochter: 0664 7654321, sonst 0699 10842229",
            besides: "+4369910842229")
        #expect(found.count == 1)
        #expect(try #require(found.first).dial == "06647654321")
    }

    @Test func withNoStoredNumberEveryNumberInTheNoteIsOffered() {
        let found = PhoneNumbers.inNote("Tochter: 0664 7654321", besides: nil)
        #expect(found.map(\.dial) == ["06647654321"])
        #expect(PhoneNumbers.inNote("Tochter: 0664 7654321", besides: "  ").count == 1)
    }

    /// And a note that writes one number twice, each time differently, is
    /// still one button.
    @Test func oneNumberWrittenTwoWaysInOneNoteIsOneButton() {
        let found = PhoneNumbers.inNote(
            "Mobil 0664 1234567, international +43 664 1234567", besides: nil)
        #expect(found.count == 1)
    }
}
