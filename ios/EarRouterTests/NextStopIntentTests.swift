import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// What Siri says when the driver asks who is next.
///
/// The sentence is the whole feature — it is heard once, at the wheel, with no
/// chance to re-read it — so it is pure and pinned down here rather than
/// assembled inside the intent where nothing could reach it.
@MainActor
struct NextStopIntentTests {

    private func customer(
        _ name: String? = "Fam. Gruber", paket: String? = nil
    ) -> Stop {
        Stop(
            kind: .customer, kunde: name, strasse: "Gentzgasse 129/1", plz: "1180",
            paket: paket, lat: 48.2301, lon: 16.3201)
    }

    private let noon = Date(timeIntervalSince1970: 1_757_000_000)

    /// Who, then where — the order it is needed in at the wheel.
    @Test func leadsWithTheStopNumberAndTheName() {
        let said = NextStopIntent.sentence(
            customer(), number: 7, floor: nil, eta: nil)
        #expect(said.hasPrefix("Stopp 7: Fam. Gruber, Gentzgasse 129/1, 1180"))
        #expect(said.hasSuffix("."))
    }

    /// The stairs and the box come after the address: both are things done once
    /// the van has already stopped.
    @Test func theStairsAndTheBoxComeAfterTheAddress() {
        let said = NextStopIntent.sentence(
            customer(paket: "2x Menü"), number: 3, floor: "3", eta: nil)
        let address = try? #require(said.range(of: "Gentzgasse"))
        let floor = try? #require(said.range(of: "3. Stock"))
        let paket = try? #require(said.range(of: "2x Menü"))
        #expect(address != nil && floor != nil && paket != nil)
        if let address, let floor { #expect(address.lowerBound < floor.lowerBound) }
        if let floor, let paket { #expect(floor.lowerBound < paket.lowerBound) }
    }

    /// A floor typed as a bare number is said the way somebody would say it.
    @Test func aBareFloorNumberIsSpokenAsAFloor() {
        let said = NextStopIntent.sentence(customer(), number: 1, floor: "3", eta: nil)
        #expect(said.contains("3. Stock"))
    }

    /// And anything the driver spelled out themselves is left as they wrote it.
    @Test func aFloorTheDriverWroteOutIsLeftAlone() {
        let said = NextStopIntent.sentence(
            customer(), number: 1, floor: "2/Tür 14", eta: nil)
        #expect(said.contains("2/Tür 14"))
        #expect(!said.contains("Stock"))
    }

    /// A stop carrying no name at all still gets a sentence rather than a gap
    /// where the customer should be.
    @Test func aStopWithNoNameStillSaysSomething() {
        let said = NextStopIntent.sentence(customer(nil), number: nil, floor: nil, eta: nil)
        #expect(said.hasPrefix("Der nächste Stopp, Gentzgasse"))
    }

    /// The arrival time goes last — it is the least of what is needed at the
    /// moment of asking, and the only part that is an estimate.
    @Test func theArrivalTimeComesLast() {
        let said = NextStopIntent.sentence(
            customer(paket: "1x Menü"), number: 2, floor: "1", eta: noon)
        #expect(said.hasSuffix("Ankunft etwa \(Format.time(noon))."))
    }

    /// Nothing known but the name: no empty clauses, no stray commas.
    @Test func sparseStopsProduceNoEmptyClauses() {
        let stop = Stop(kind: .customer, kunde: "Fr. Novak", lat: 48.2, lon: 16.3)
        let said = NextStopIntent.sentence(stop, number: nil, floor: "  ", eta: nil)
        #expect(said == "Fr. Novak.")
    }
}
