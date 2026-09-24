import Testing
import Foundation
@testable import EarRouter

/// Mapping the Zusteller-Portal's wire shapes onto `CustomerJSON`, and
/// picking which of a driver's standing tours actually runs on a given day.
///
/// Every field name exercised here is exactly what a captured HAR from the
/// real backend used — this is the reverse-engineered contract, pinned down
/// so a refactor cannot quietly change what a Vitalmenü or a Stiege turns
/// into without a test noticing.
struct GourmetPortalTests {

    // MARK: - Building blocks

    private func address(
        street: String? = "Gentzgasse 129", street2: String? = nil,
        staircase: String? = nil, flatNumber: String? = nil,
        zip: String? = "1180", comment: String? = nil
    ) -> GourmetPortal.Address {
        GourmetPortal.Address(
            street: street, street2: street2, staircase: staircase, flatNumber: flatNumber,
            zip: zip, city: "Wien", comment: comment)
    }

    private func customer(
        firstname: String? = "Fam.", lastname: String? = "Gruber", comment: String? = nil,
        phone: String? = nil
    ) -> GourmetPortal.Customer {
        GourmetPortal.Customer(
            firstname: firstname, lastname: lastname, comment: comment, phone: phone)
    }

    private func line(_ name: String, quantity: Double = 1) -> GourmetPortal.DeliveryLine {
        GourmetPortal.DeliveryLine(name: name, quantity: quantity)
    }

    private func delivery(
        customer: GourmetPortal.Customer? = nil,
        address: GourmetPortal.Address? = nil,
        tours: [GourmetPortal.TourRef] = [],
        bundles: [GourmetPortal.DeliveryBundle]? = nil
    ) -> GourmetPortal.Delivery {
        GourmetPortal.Delivery(
            id: 1, state: "assigned",
            customer: customer ?? self.customer(),
            deliveryAddress: address ?? self.address(),
            tours: tours, deliveryBundles: bundles)
    }

    // MARK: - Kunde

    @Test func joinsFirstAndLastName() {
        let d = delivery(customer: customer(firstname: "Maria", lastname: "Novak"))
        #expect(GourmetPortal.customerJSON(from: d).kunde == "Maria Novak")
    }

    @Test func aMissingFirstNameStillGivesTheLastNameAlone() {
        let d = delivery(customer: customer(firstname: nil, lastname: "Novak"))
        #expect(GourmetPortal.customerJSON(from: d).kunde == "Novak")
    }

    @Test func bothNamesMissingGivesAnEmptyKunde() {
        let d = delivery(customer: customer(firstname: nil, lastname: nil))
        #expect(GourmetPortal.customerJSON(from: d).kunde == "")
    }

    // MARK: - Straße

    @Test func plainStreetNeedsNoSuffix() {
        let d = delivery(address: address(street: "Alser Straße 21"))
        #expect(GourmetPortal.customerJSON(from: d).strasse == "Alser Straße 21")
    }

    /// The one thing worth pinning down hardest: no space before the slash.
    /// `AddressText` reads "{street} {housenumber}/{Stiege}/{Tür}" back out of
    /// a free-text address, and the housenumber is already the tail of
    /// `street` here — a stray space would turn a real Stiege into text
    /// `AddressText` cannot parse at all.
    @Test func stiegeAndTuerJoinDirectlyOntoTheHousenumber() {
        let d = delivery(address: address(
            street: "Gentzgasse 129", staircase: "1", flatNumber: "23"))
        #expect(GourmetPortal.customerJSON(from: d).strasse == "Gentzgasse 129/1/23")
    }

    @Test func street2ComesBeforeStaircaseAndFlatNumber() {
        let d = delivery(address: address(
            street: "Großfeldstraße 9", street2: "Parz. 68", staircase: "1"))
        #expect(GourmetPortal.customerJSON(from: d).strasse == "Großfeldstraße 9/Parz. 68/1")
    }

    @Test func aBlankStaircaseIsDroppedRatherThanLeavingATrailingSlash() {
        let d = delivery(address: address(street: "Alser Straße 21", staircase: "  "))
        #expect(GourmetPortal.customerJSON(from: d).strasse == "Alser Straße 21")
    }

    @Test func plzComesStraightFromTheAddress() {
        let d = delivery(address: address(zip: "1210"))
        #expect(GourmetPortal.customerJSON(from: d).plz == "1210")
    }

    @Test func aMissingZipGivesAnEmptyPlzRatherThanCrashing() {
        let d = delivery(address: address(zip: nil))
        #expect(GourmetPortal.customerJSON(from: d).plz == "")
    }

    // MARK: - Paket

    @Test func oneLineOfQuantityOneIsNamedAlone() {
        let d = delivery(bundles: [
            GourmetPortal.DeliveryBundle(deliveryLines: [line("Vitalmenü EP TGM7")])
        ])
        #expect(GourmetPortal.customerJSON(from: d).paket == "Vitalmenü EP TGM7")
    }

    @Test func aQuantityOtherThanOneIsPrefixed() {
        let d = delivery(bundles: [
            GourmetPortal.DeliveryBundle(deliveryLines: [line("Suppe", quantity: 2)])
        ])
        #expect(GourmetPortal.customerJSON(from: d).paket == "2x Suppe")
    }

    @Test func aFractionalQuantityKeepsItsDecimals() {
        let d = delivery(bundles: [
            GourmetPortal.DeliveryBundle(deliveryLines: [line("Brot", quantity: 0.5)])
        ])
        #expect(GourmetPortal.customerJSON(from: d).paket == "0.50x Brot")
    }

    /// "Stopps wählen": an order is the driver's own only if they changed it.
    /// Dropping stops is choosing which to drive, not in what order.
    @MainActor @Test func onlyAChangedOrderIsTheDriversOwn() {
        let portal = [1, 2, 3, 4]
        #expect(!GourmetStopSelectionView.isOwnOrder(picked: [1, 2, 3, 4], portal: portal))
        #expect(!GourmetStopSelectionView.isOwnOrder(picked: [1, 3, 4], portal: portal))
        #expect(GourmetStopSelectionView.isOwnOrder(picked: [3, 1, 2, 4], portal: portal))
        // Ticked off and on again: it went to the back, and that is an order.
        #expect(GourmetStopSelectionView.isOwnOrder(picked: [1, 3, 4, 2], portal: portal))
    }

    @Test func linesFromSeveralBundlesAreAllListed() {
        let d = delivery(bundles: [
            GourmetPortal.DeliveryBundle(deliveryLines: [line("Vitalmenü EP TGM7")]),
            GourmetPortal.DeliveryBundle(deliveryLines: [line("Suppe", quantity: 2)]),
        ])
        #expect(GourmetPortal.customerJSON(from: d).paket == "Vitalmenü EP TGM7, 2x Suppe")
    }

    @Test func noBundlesAtAllGivesNoPaketRatherThanAnEmptyString() {
        let d = delivery(bundles: nil)
        #expect(GourmetPortal.customerJSON(from: d).paket == nil)
    }

    @Test func bundlesWithNoLinesAlsoGiveNoPaket() {
        let d = delivery(bundles: [GourmetPortal.DeliveryBundle(deliveryLines: [])])
        #expect(GourmetPortal.customerJSON(from: d).paket == nil)
    }

    // MARK: - Notiz

    @Test func theDeliveryAddressCommentIsTheNotiz() {
        let d = delivery(address: address(comment: "bitte laut klingeln"))
        #expect(GourmetPortal.customerJSON(from: d).notiz == "bitte laut klingeln")
    }

    /// The delivery address is where the driver actually goes; a comment left
    /// on the customer's own (often billing) address only surfaces once
    /// there is nothing more specific to say.
    @Test func theCustomerCommentIsAFallbackBehindTheAddressOne() {
        let d = delivery(
            customer: customer(comment: "Kunde seit 2019"),
            address: address(comment: nil))
        #expect(GourmetPortal.customerJSON(from: d).notiz == "Kunde seit 2019")
    }

    @Test func anAddressCommentWinsOverACustomerComment() {
        let d = delivery(
            customer: customer(comment: "Kunde seit 2019"),
            address: address(comment: "Stiege 2, hinten"))
        #expect(GourmetPortal.customerJSON(from: d).notiz == "Stiege 2, hinten")
    }

    @Test func noCommentAnywhereGivesNoNotiz() {
        let d = delivery(customer: customer(comment: nil), address: address(comment: nil))
        #expect(GourmetPortal.customerJSON(from: d).notiz == nil)
    }

    // MARK: - Telefon

    @Test func theCustomersPhoneBecomesTelefon() {
        let d = delivery(customer: customer(phone: "+4369910842229"))
        #expect(GourmetPortal.customerJSON(from: d).telefon == "+4369910842229")
    }

    @Test func noPhoneOnTheCustomerGivesNoTelefon() {
        let d = delivery(customer: customer(phone: nil))
        #expect(GourmetPortal.customerJSON(from: d).telefon == nil)
    }

    // MARK: - Which tours run on a given day

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Vienna")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    /// 2026-09-10 is a Thursday — the same date the real capture this
    /// contract came from used.
    @Test func recognisesTheRealWeekday() {
        #expect(GourmetPortal.germanWeekday(for: date("2026-09-10")) == "donnerstag")
        #expect(GourmetPortal.germanWeekday(for: date("2026-09-14")) == "montag")
    }

    @Test func aWeekTourRunsOnlyOnItsOwnWeekday() {
        let tour = GourmetPortal.Tour(
            id: 20, name: "VM 4 DO Vormittag", catalogueType: "week", weekday: "donnerstag",
            weekdays: [])
        #expect(GourmetPortal.runs(tour, on: date("2026-09-10")))
        #expect(!GourmetPortal.runs(tour, on: date("2026-09-11")))
    }

    @Test func aDayTourRunsOnEveryWeekdayItLists() {
        let tour = GourmetPortal.Tour(
            id: 25, name: "TP AST 14 - 1401", catalogueType: "day", weekday: "montag",
            weekdays: ["montag", "dienstag", "mittwoch", "donnerstag", "freitag"])
        #expect(GourmetPortal.runs(tour, on: date("2026-09-10")))
        // Saturday is not in this tour's weekday list, even though "day"
        // tours otherwise read as "every day" at a glance.
        #expect(!GourmetPortal.runs(tour, on: date("2026-09-12")))
    }

    @Test func aTourWithNeitherFieldSetNeverMatches() {
        let tour = GourmetPortal.Tour(
            id: 82, name: "Tk1", catalogueType: nil, weekday: nil, weekdays: [])
        #expect(!GourmetPortal.runs(tour, on: date("2026-09-10")))
    }

    // MARK: - The login body

    /// The one character that decides whether a driver can log in at all.
    ///
    /// The body is `application/x-www-form-urlencoded`, where a literal `+`
    /// means a space. `URLComponents` — which this used to be built with —
    /// encodes for a *query* instead and leaves `+` alone, so a password
    /// carrying one arrived at the server with a hole in it and the portal
    /// answered 403 for credentials that were correct.
    @Test func aPlusInThePasswordIsEscapedRatherThanLeftToMeanASpace() {
        let body = GourmetPortal.formEncoded([(name: "password", value: "Som+mer26")])
        #expect(String(decoding: body ?? Data(), as: UTF8.self) == "password=Som%2Bmer26")
    }

    /// The separators, and the `@` every one of these usernames carries.
    @Test func formEncodingEscapesEverythingOutsideTheUnreservedSet() {
        let body = GourmetPortal.formEncoded([
            (name: "username", value: "paul.leiner@samariterbund.net"),
            (name: "host", value: "https://staging.essen-fuer-daheim.at"),
            (name: "password", value: "a&b=c d?e"),
        ])
        #expect(
            String(decoding: body ?? Data(), as: UTF8.self)
                == "username=paul.leiner%40samariterbund.net"
                    + "&host=https%3A%2F%2Fstaging.essen-fuer-daheim.at"
                    + "&password=a%26b%3Dc%20d%3Fe")
    }

    // MARK: - Route naming

    private var vm4: GourmetPortal.Tour {
        GourmetPortal.Tour(
            id: 20, name: "VM 4 DO Vormittag", catalogueType: "week", weekday: "donnerstag",
            weekdays: [])
    }

    /// The tour's own name, and nothing that would push it past the large
    /// title on the tour screen.
    @Test func suggestedNameIsTheTourAlone() {
        #expect(
            GourmetPortal.suggestedRouteName(tour: vm4, date: date("2026-09-10"))
                == "VM 4 DO Vormittag")
    }

    /// A date only where it tells two open tours apart.
    @Test func suggestedNameAddsTheDateOnlyToTellTwoApart() {
        #expect(
            GourmetPortal.suggestedRouteName(
                tour: vm4, date: date("2026-09-10"), taken: ["VM 4 DO Vormittag"])
                == "VM 4 DO Vormittag – 10.09.")
    }
}
