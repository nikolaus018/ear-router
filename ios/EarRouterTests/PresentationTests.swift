import Testing
import Foundation
@testable import EarRouter

/// What the driver reads off a row, and the ordering the map's change detection
/// depends on. Both are small, both are hit constantly, and both were wrong in
/// ways that only showed up on a real tour.
struct LegFormattingTests {

    @Test func formatsAnOrdinaryLeg() {
        #expect(Format.leg(km: 3.24, minutes: 8) == "3,2 km · 8 min")
    }

    @Test func spellsOutHoursPastSixtyMinutes() {
        #expect(Format.minutes(72) == "1 h 12 min")
        #expect(Format.minutes(59) == "59 min")
    }

    /// Two households in one Gemeindebau are a routed leg of zero metres.
    /// "→ 0,0 km · 0 min" under one of them reads as missing data rather than
    /// as "you are already standing there".
    @Test func saysNothingAboutALegThatRoundsAwayToNothing() {
        #expect(Format.leg(km: 0, minutes: 0) == nil)
        #expect(Format.leg(km: 0.004, minutes: 0.2) == nil)
    }

    /// …but a leg that is genuinely short is still a leg to drive.
    @Test func stillReportsAShortButRealLeg() {
        #expect(Format.leg(km: 0.4, minutes: 1) == "0,4 km · 1 min")
    }

    @Test func reportsNothingForMissingValues() {
        #expect(Format.leg(km: nil, minutes: nil) == nil)
    }

    @Test func pluralisesStopsWithoutALocalisationCatalogue() {
        #expect(Format.stops(1) == "1 Stopp")
        #expect(Format.stops(0) == "0 Stopps")
        #expect(Format.stops(12) == "12 Stopps")
    }
}

struct ListAddressTests {

    private func stop(_ strasse: String?, _ plz: String?) -> Stop {
        Stop(kind: .customer, strasse: strasse, plz: plz, lat: 48.2, lon: 16.37)
    }

    /// The city is dropped in the list — every stop on every tour is in Vienna,
    /// and those six characters are what pushed an ordinary address onto a
    /// second line beside the row's buttons.
    @Test func dropsTheCityButKeepsTheDistrict() {
        #expect(stop("Gentzgasse 129/1", "1180").listAddress == "Gentzgasse 129/1, 1180")
    }

    /// The handoff to a navigation app keeps the city and the country — a bare
    /// street and postcode is a navigation app guessing — and drops the
    /// Stiege, which no navigation app can search for.
    @Test func theNavigationFormKeepsTheCityAndDropsTheStiege() {
        #expect(
            stop("Gentzgasse 129/1", "1180").navigationAddress
                == "Gentzgasse 129, 1180 Wien, Österreich")
    }

    @Test func theNavigationFormNamesNoCityOutsideVienna() {
        #expect(
            stop("Kirchenplatz 3", "2201").navigationAddress == "Kirchenplatz 3, 2201, Österreich")
    }

    @Test func theNavigationFormSpellsTheStreetOut() {
        #expect(
            stop("Hauptstr. 5", "1140").navigationAddress == "Hauptstraße 5, 1140 Wien, Österreich")
    }

    @Test func survivesEitherHalfBeingMissing() {
        #expect(stop("Gentzgasse 129", nil).listAddress == "Gentzgasse 129")
        #expect(stop(nil, "1180").listAddress == "1180")
        #expect(stop(nil, nil).listAddress.isEmpty)
    }
}

/// The map rebuilds its change keys on every frame of a pan, and those keys are
/// sorted by stop id. Ordering by `uuidString` allocated a string per
/// comparison; this has to be a genuine total order without doing that.
struct IDOrderingTests {

    @Test func agreesWithTheStringOrderingItReplaced() {
        let ids = (0..<400).map { _ in UUID() }
        let byBytes = ids.sorted(by: UUID.idOrderedBefore)
        let byString = ids.sorted { $0.uuidString < $1.uuidString }
        #expect(byBytes == byString)
    }

    @Test func isIrreflexiveAndAntisymmetric() {
        let a = UUID(), b = UUID()
        #expect(!UUID.idOrderedBefore(a, a))
        #expect(UUID.idOrderedBefore(a, b) != UUID.idOrderedBefore(b, a))
    }

    /// The bytes are compared most-significant first, so two ids differing only
    /// in the very last byte still order correctly — the case a naive
    /// early-return chain gets wrong.
    @Test func comparesTheWholeIdIncludingTheLastByte() {
        let low = [UInt8](repeating: 0, count: 16)
        var high = low
        high[15] = 1
        let a = UUID(uuid: (low[0], low[1], low[2], low[3], low[4], low[5], low[6], low[7],
                            low[8], low[9], low[10], low[11], low[12], low[13], low[14], low[15]))
        let b = UUID(uuid: (high[0], high[1], high[2], high[3], high[4], high[5], high[6], high[7],
                            high[8], high[9], high[10], high[11], high[12], high[13], high[14],
                            high[15]))
        #expect(UUID.idOrderedBefore(a, b))
        #expect(!UUID.idOrderedBefore(b, a))
    }
}
