import Testing
import Foundation
@testable import EarRouter

/// Which stops of a portal tour are the other driver's — what the map's
/// "Stopps der anderen" shows — and the link that says which tour a route came
/// from.
struct OtherStopsTests {

    private func delivery(
        id: Int, first: String = "Fam.", last: String, street: String, flat: String? = nil,
        zip: String = "1100"
    ) -> GourmetPortal.Delivery {
        GourmetPortal.Delivery(
            id: id, state: "assigned",
            customer: GourmetPortal.Customer(
                firstname: first, lastname: last, comment: nil, phone: nil),
            deliveryAddress: GourmetPortal.Address(
                street: street, street2: nil, staircase: nil, flatNumber: flat,
                zip: zip, city: "Wien", comment: nil),
            tours: [], deliveryBundles: nil)
    }

    private func mine(names: [String] = [], addresses: [(String, String)] = []) -> OtherStops.Mine {
        OtherStops.Mine(
            names: Set(names.map(AddressText.matchKey)),
            addresses: Set(addresses.map { OtherStops.Mine.addressKey($0.0, $0.1) }))
    }

    @Test func keepsOnlyDeliveriesThatAreNotMine() {
        let all = [
            delivery(id: 1, last: "Gruber", street: "Gentzgasse 129", flat: "1"),
            delivery(id: 2, last: "Huber", street: "Raxstraße 30", flat: "4"),
            delivery(id: 3, last: "Maier", street: "Troststraße 15", flat: "22"),
        ]
        let rest = OtherStops.others(
            in: all, excluding: mine(names: ["Fam. Gruber"], addresses: [("Troststraße 15/22", "1100")]))
        #expect(rest.map(\.id) == [2])
    }

    @Test func aCustomerWhoMovedIsStillMine() {
        let all = [delivery(id: 1, last: "Gruber", street: "Neue Gasse 1")]
        let rest = OtherStops.others(in: all, excluding: mine(names: ["Fam. Gruber"]))
        #expect(rest.isEmpty)
    }

    @Test func namesAreFoldedTheWayReImportsFoldThem() {
        let all = [delivery(id: 1, last: "Grüber", street: "Neue Gasse 1")]
        let rest = OtherStops.others(in: all, excluding: mine(names: ["Fam Grueber"]))
        #expect(rest.isEmpty)
    }

    @Test func theSameBuildingAnotherFlatIsNotMine() {
        let all = [delivery(id: 1, last: "Huber", street: "Troststraße 15", flat: "23")]
        let rest = OtherStops.others(
            in: all, excluding: mine(addresses: [("Troststraße 15/22", "1100")]))
        #expect(rest.map(\.id) == [1])
    }

    @Test func nothingMineMeansEverythingIsTheOthers() {
        let all = [
            delivery(id: 1, last: "A", street: "Eins 1"),
            delivery(id: 2, last: "B", street: "Zwei 2"),
        ]
        #expect(OtherStops.others(in: all, excluding: .init()).count == 2)
    }

    @Test func linkSurvivesARoundTripAndIsForgotten() {
        let id = UUID()
        defer { PortalTourLink.forget(id) }
        #expect(PortalTourLink.load(for: id) == nil)
        let link = PortalTourLink(tourID: 7, tourName: "TK 1", date: Date(timeIntervalSince1970: 1_790_000_000))
        link.save(for: id)
        #expect(PortalTourLink.load(for: id) == link)
        PortalTourLink.forget(id)
        #expect(PortalTourLink.load(for: id) == nil)
    }

    @Test func handAddedStopsKeepTheirOwnIdsAndCanBeRemoved() {
        let route = UUID()
        defer { ManualOtherStops.forget(route) }
        #expect(ManualOtherStops.load(for: route).isEmpty)
        let a = ManualOtherStops.add(
            name: "", address: " Hörlgasse 4 ", plz: "1090", latitude: 48.2, longitude: 16.36, to: route)
        let b = ManualOtherStops.add(
            name: "Fam. Gruber", address: "Gentzgasse 129", plz: "1180", latitude: nil, longitude: nil,
            to: route)
        #expect(a.isManual && b.isManual && a.id != b.id)
        #expect(a.name == "Nachlieferung" && a.address == "Hörlgasse 4")
        #expect(ManualOtherStops.load(for: route) == [a, b])
        ManualOtherStops.remove(id: a.id, from: route)
        #expect(ManualOtherStops.load(for: route) == [b])
        ManualOtherStops.remove(id: b.id, from: route)
        #expect(ManualOtherStops.load(for: route).isEmpty)
    }

    @Test func aPortalStopTakenOffTheOthersStaysOffUntilBroughtBack() {
        let route = UUID()
        defer { ManualOtherStops.forget(route) }
        #expect(ManualOtherStops.hidden(for: route).isEmpty)
        ManualOtherStops.hide(id: 11, for: route)
        ManualOtherStops.hide(id: 12, for: route)
        ManualOtherStops.hide(id: 11, for: route)
        #expect(ManualOtherStops.hidden(for: route) == [11, 12])
        ManualOtherStops.unhideAll(for: route)
        #expect(ManualOtherStops.hidden(for: route).isEmpty)
    }

    @Test func aStopHandedOverKeepsItsNotizAndPhone() {
        let route = UUID()
        defer { ManualOtherStops.forget(route) }
        let given = ManualOtherStops.add(
            name: "Fam. Gruber", address: "Gentzgasse 129/1/23", plz: "1180", latitude: 48.22,
            longitude: 16.33, notiz: " Tür 20 läuten ", telefon: "+4369912345678", to: route)
        #expect(given.notiz == "Tür 20 läuten" && given.telefon == "+4369912345678")
        #expect(ManualOtherStops.load(for: route) == [given])
    }

    @Test func aTakenOverStopBecomesAnEntryWithinTheFieldLimits() {
        let stop = OtherStop(
            id: 5, name: "  Fam. Gruber ", address: "Gentzgasse 129/1/23", plz: "1180",
            notiz: "Tür 20 läuten", telefon: "+436763095249 Schwester Frau Koch und noch viel mehr Text",
            latitude: nil, longitude: nil)
        let entry = OtherStops.plainEntry(for: stop)
        #expect(entry.kunde == "Fam. Gruber")
        #expect(entry.strasse == "Gentzgasse 129/1/23" && entry.plz == "1180")
        #expect(entry.notiz == "Tür 20 läuten")
        #expect((entry.telefon ?? "").count == FieldLimits.telefon)
        #expect(entry.paket == nil)
        #expect((try? RouteStore.validateCustomerFields(
            kunde: entry.kunde, strasse: entry.strasse, paket: entry.paket,
            notiz: entry.notiz, telefon: entry.telefon)) != nil)
    }

    @Test func aStopHandedOverAndFetchedAgainIsNotShownTwice() {
        let held = [OtherStop(
            id: OtherStops.manualBase, name: "Fam. Gruber", address: "Gentzgasse 129/1/23", plz: "1180",
            notiz: nil, telefon: nil, latitude: nil, longitude: nil)]
        let fetched = [
            OtherStop(id: 1, name: "Fam Grueber", address: "Gentzgasse 129/1/23", plz: "1180",
                      notiz: nil, telefon: nil, latitude: nil, longitude: nil),
            OtherStop(id: 2, name: "Huber", address: "Raxstraße 30/4", plz: "1100",
                      notiz: nil, telefon: nil, latitude: nil, longitude: nil),
        ]
        #expect(OtherStops.dropping(fetched, alreadyHeld: held).map(\.id) == [2])
        #expect(OtherStops.dropping(fetched, alreadyHeld: []).count == 2)
    }

    @Test func aHandedOverStopTakesItsPaketBackWithIt() {
        let route = UUID()
        defer { ManualOtherStops.forget(route) }
        let given = ManualOtherStops.add(
            name: "Fam. Gruber", address: "Gentzgasse 129/1/23", plz: "1180", latitude: nil,
            longitude: nil, paket: "Rindsgulasch, Spätzle", paketCount: 2, to: route)
        let entry = OtherStops.plainEntry(for: given)
        #expect(entry.paket == "Rindsgulasch, Spätzle" && entry.paketCount == 2)
    }

    @Test func aHandedOverStopSaysSoAndATypedOneDoesNot() throws {
        let route = UUID()
        defer { ManualOtherStops.forget(route) }
        let typed = ManualOtherStops.add(
            name: "", address: "Hörlgasse 4", plz: "1090", latitude: nil, longitude: nil, to: route)
        let given = ManualOtherStops.add(
            name: "Fam. Gruber", address: "Gentzgasse 129/1/23", plz: "1180", latitude: nil,
            longitude: nil, handedOver: true, to: route)
        #expect(typed.handedOver == nil && given.handedOver == true)
        #expect(ManualOtherStops.load(for: route) == [typed, given])

        // One kept before the mark existed still reads, as a typed one.
        let old = #"[{"id":1000000000,"name":"Huber","address":"Raxstraße 30","plz":"1100"}]"#
        let stops = try JSONDecoder().decode([OtherStop].self, from: Data(old.utf8))
        #expect(stops.first?.handedOver == nil && stops.first?.isManual == true)
    }
}
