import Testing
@testable import EarRouter

struct CustomerContactsTests {
    /// The name is what an incoming call shows, so it says both who and what.
    @Test func theNameCarriesTheCustomerAndTheSuffix() {
        #expect(CustomerContacts.contactName(for: " Maria Huber ") == "Maria Huber – EAR-Kunde")
    }

    @Test func aStopWithoutANameIsStillACustomer() {
        #expect(CustomerContacts.contactName(for: nil) == "EAR-Kunde")
        #expect(CustomerContacts.contactName(for: "  ") == "EAR-Kunde")
    }

    /// A number already in the address book under the other notation must be
    /// found, or a customer the driver knows gets a second entry.
    @Test func aNumberIsLookedUpInEveryNotation() {
        #expect(CustomerContacts.notations(of: "06641234567") == ["06641234567", "+436641234567"])
        #expect(CustomerContacts.notations(of: "+436641234567") == ["+436641234567", "06641234567"])
        #expect(CustomerContacts.notations(of: "00436641234567")
            == ["00436641234567", "06641234567", "+436641234567"])
    }

    @Test func aForeignNumberIsLeftAsWritten() {
        #expect(CustomerContacts.notations(of: "+4915112345678") == ["+4915112345678"])
        #expect(CustomerContacts.notations(of: "004915112345678") == ["004915112345678"])
    }
}
