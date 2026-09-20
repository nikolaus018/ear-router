import Testing
import Foundation
@testable import EarRouter

/// Reading a tour out of Eray's planner.
///
/// The sample below is a real document, trimmed to the entries that say
/// something: a plain stop, one whose `address` is composed of separate
/// house-number parts, one with a note, one with neither Paket nor note.
/// Every key in it is spelled exactly as the planner writes it, so a rename
/// on either side has to break a test rather than quietly import empty rows.
struct ErayImportTests {

    private let sample = """
        {
          "tourName": "VM 1 MO Vormittag · 21.09.2026 · Teil 2/2",
          "part": 2,
          "parts": 2,
          "start": "GPS Position",
          "end": "Petritschgasse 24, 1210 Wien",
          "deliveries": [
            {
              "order": 1,
              "sourceStop": "1",
              "customerName": "Johanna Kager",
              "address": "Marktgemeindegasse 44-50/3/8",
              "street": "Marktgemeindegasse",
              "houseNumber": "44-50/3/8",
              "stairway": "",
              "floor": "",
              "apartment": "",
              "postalCode": "1230",
              "city": "Wien",
              "phone": "",
              "product": "1 × Vitalmenü EP TGMS5",
              "quantity": "1",
              "priority": 0,
              "notes": "",
              "referenceNumber": "77932",
              "customerNumber": "42353",
              "deliveryDate": "2026-09-21",
              "latitude": 48.15546971789354,
              "longitude": 16.28404056979064
            },
            {
              "order": 2,
              "customerName": "Elfriede Zednik",
              "address": "Maurer Lange Gasse 100/8",
              "street": "Maurer Lange Gasse",
              "houseNumber": "100/8",
              "postalCode": "1230",
              "city": "Wien",
              "phone": "+4369910842229",
              "product": "1 × Vitalmenü EP TGM5",
              "notes": "persönlich nur im notfall vdt",
              "latitude": 48.1482524,
              "longitude": 16.2622617
            },
            {
              "order": 3,
              "customerName": "Gerhard Tiller",
              "address": "Breitenfurter Straße 519-521/1/1",
              "street": "Breitenfurter Straße",
              "houseNumber": "519-521",
              "stairway": "1",
              "floor": "",
              "apartment": "1",
              "postalCode": "1230",
              "city": "Wien",
              "phone": "",
              "product": "1 × Vitalmenü EP DLMS5 (LVK)",
              "notes": "vdT"
            }
          ]
        }
        """

    // MARK: - The document as it really arrives

    @Test func readsTheRealDocument() throws {
        let document = try ErayImport.parse(sample)
        #expect(document.tourName == "VM 1 MO Vormittag · 21.09.2026 · Teil 2/2")
        #expect(document.deliveries.count == 3)

        let entries = ErayImport.entries(from: document)
        #expect(entries.map(\.kunde) == ["Johanna Kager", "Elfriede Zednik", "Gerhard Tiller"])
        #expect(entries.map(\.strasse) == [
            "Marktgemeindegasse 44-50/3/8", "Maurer Lange Gasse 100/8",
            "Breitenfurter Straße 519-521/1/1",
        ])
        #expect(entries.allSatisfy { $0.plz == "1230" })
    }

    @Test func carriesPaketNoteAndPhone() throws {
        let entries = ErayImport.entries(from: try ErayImport.parse(sample))
        #expect(entries[0].paket == "1 × Vitalmenü EP TGMS5")
        // Empty strings are not notes and not phone numbers — the rest of the
        // app expects those fields absent, not blank.
        #expect(entries[0].notiz == nil)
        #expect(entries[0].telefon == nil)
        #expect(entries[1].notiz == "persönlich nur im notfall vdt")
        #expect(entries[1].telefon == "+4369910842229")
    }

    /// The Paket is passed through verbatim, which is only right if the
    /// Ladeliste can count it — the planner writes "1 × X" where the portal
    /// writes "2x X".
    @Test func theLadelisteCanCountTheProduct() throws {
        let entries = ErayImport.entries(from: try ErayImport.parse(sample))
        #expect(PaketParser.totalQty(entries[0].paket) == 1)
        #expect(PaketParser.parse("2 × Vitalmenü").first?.qty == 2)
    }

    /// Every stop this app takes has to survive its own import checks —
    /// anything else and a real document arrives as a screen of warnings.
    @Test func theRealDocumentImportsWithoutWarnings() throws {
        let entries = ErayImport.entries(from: try ErayImport.parse(sample))
        for entry in entries {
            #expect(Postcodes.isValid(entry.plz))
            #expect(
                throws: Never.self,
                performing: {
                    try RouteStore.validateCustomerFields(
                        kunde: entry.kunde, strasse: entry.strasse, paket: entry.paket,
                        notiz: entry.notiz, telefon: entry.telefon)
                })
        }
    }

    // MARK: - Order

    @Test func keepsThePlannersOrder() {
        let out = ErayImport.ordered([
            .init(order: 3, customerName: "C"),
            .init(order: 1, customerName: "A"),
            .init(order: 2, customerName: "B"),
        ])
        #expect(out.map(\.customerName) == ["A", "B", "C"])
    }

    /// No `order` anywhere means the array is already the sequence.
    @Test func withoutOrderTheArrayIsTheOrder() {
        let out = ErayImport.ordered([
            .init(customerName: "A"), .init(customerName: "B"), .init(customerName: "C"),
        ])
        #expect(out.map(\.customerName) == ["A", "B", "C"])
    }

    /// Two stops claiming the same number, and one claiming none, must still
    /// land somewhere predictable rather than wherever the sort dropped them.
    @Test func sortsStablyOnRepeatedAndMissingNumbers() {
        let out = ErayImport.ordered([
            .init(order: 2, customerName: "B"),
            .init(customerName: "ohne"),
            .init(order: 1, customerName: "A"),
            .init(order: 2, customerName: "B2"),
        ])
        #expect(out.map(\.customerName) == ["A", "B", "B2", "ohne"])
    }

    // MARK: - Addresses

    /// The fallback for a document without a composed `address`: the same
    /// Hausnummer/Stiege/Stock/Tür line the rest of the app reads.
    @Test func composesTheAddressWhenThereIsNone() {
        #expect(
            ErayImport.streetLine(
                .init(street: "Gentzgasse", houseNumber: "129", stairway: "1", apartment: "23"))
                == "Gentzgasse 129/1/23")
        #expect(
            ErayImport.streetLine(.init(street: "Alser Straße", houseNumber: "21"))
                == "Alser Straße 21")
    }

    /// A composed `address` wins: it is what the planner actually wrote, and
    /// entry 3 of the sample shows the parts do not always add back up to it.
    @Test func prefersTheComposedAddress() {
        #expect(
            ErayImport.streetLine(
                .init(address: "Breitenfurter Straße 519-521/1/1", street: "Breitenfurter Straße",
                      houseNumber: "519-521", stairway: "1", apartment: "1"))
                == "Breitenfurter Straße 519-521/1/1")
    }

    /// `AddressText` has to find the housenumber in what we built, or the
    /// geocoder asks for the whole Stiege-and-Tür string and finds nothing.
    @Test func theComposedAddressIsGeocodable() {
        let line = ErayImport.streetLine(
            .init(street: "Gentzgasse", houseNumber: "129", stairway: "1", apartment: "23"))
        #expect(AddressText.housenumberWithSub(line)?.query == "Gentzgasse 129/1")
    }

    // MARK: - Documents that are not quite right

    @Test func readsAPostcodeWrittenAsANumber() throws {
        let document = try ErayImport.parse("""
            {"tourName": "T", "deliveries": [
              {"customerName": "Fam. Gruber", "address": "Gentzgasse 129", "postalCode": 1180}
            ]}
            """)
        #expect(ErayImport.entries(from: document).first?.plz == "1180")
    }

    /// One entry missing everything must not cost the other its import — it
    /// arrives as a row with a warning in Prüfen, which is where it can be
    /// fixed or swiped away.
    @Test func keepsTheGoodEntriesBesideABrokenOne() throws {
        let document = try ErayImport.parse("""
            {"deliveries": [
              {"order": 1},
              {"order": 2, "customerName": "Fam. Gruber", "address": "Gentzgasse 129",
               "postalCode": "1180"}
            ]}
            """)
        let entries = ErayImport.entries(from: document)
        #expect(entries.count == 2)
        #expect(entries[0].kunde.isEmpty)
        #expect(entries[1].kunde == "Fam. Gruber")
    }

    /// Just the array, pasted out of the middle of a document.
    @Test func readsABareDeliveriesArray() throws {
        let document = try ErayImport.parse("""
            [{"customerName": "Fam. Gruber", "address": "Gentzgasse 129", "postalCode": "1180"}]
            """)
        #expect(document.tourName.isEmpty)
        #expect(ErayImport.entries(from: document).count == 1)
    }

    @Test func refusesWhatIsNotADocument() {
        #expect(throws: AppError.self) { try ErayImport.parse("") }
        #expect(throws: AppError.self) { try ErayImport.parse("Guten Morgen") }
        #expect(throws: AppError.self) { try ErayImport.parse("{\"tourName\": \"T\"}") }
        #expect(throws: AppError.self) { try ErayImport.parse("{\"deliveries\": []}") }
    }

    // MARK: - Naming the tour it creates

    @Test func namesTheTourAfterTheDocument() {
        let document = ErayImport.Document(tourName: "VM 1 MO · Teil 2/2")
        #expect(ErayImport.routeName(for: document) == "VM 1 MO · Teil 2/2")
    }

    /// The name already ends in a date, so a second import of the same
    /// document is counted rather than dated again.
    @Test func countsUpWhenTheNameIsTaken() {
        let document = ErayImport.Document(tourName: "VM 1")
        #expect(ErayImport.routeName(for: document, taken: ["VM 1"]) == "VM 1 (2)")
        #expect(ErayImport.routeName(for: document, taken: ["VM 1", "VM 1 (2)"]) == "VM 1 (3)")
    }

    /// Empty, so `RouteStore.createRoute` falls back to its own dated name.
    @Test func leavesTheNameToTheStoreWhenThereIsNone() {
        #expect(ErayImport.routeName(for: ErayImport.Document()).isEmpty)
    }
}
