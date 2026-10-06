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
}
