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
}
