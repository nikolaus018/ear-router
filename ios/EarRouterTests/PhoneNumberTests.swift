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

    @Test func aNoteWithNoDigitsHasNoNumbers() {
        #expect(PhoneNumbers.find(in: "Hund im Hof, bitte laut klingeln").isEmpty)
        #expect(PhoneNumbers.find(in: nil).isEmpty)
    }
}
