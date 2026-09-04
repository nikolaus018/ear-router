import Testing
import SwiftData
@testable import EarRouter

/// Two households in one Gemeindebau is one ring of the bell and two meals
/// carried up. Getting this wrong either hides that fact or claims a whole
/// district lives at one address.
@MainActor
struct SameDoorTests {

    private func makeStop(
        _ kunde: String, _ strasse: String, _ plz: String,
        lat: Double = 48.21, lon: Double = 16.35,
        precision: Precision? = nil
    ) -> Stop {
        Stop(
            kind: .customer, kunde: kunde, strasse: strasse, plz: plz,
            lat: lat, lon: lon, precision: precision)
    }

    @Test func groupsTwoCustomersAtTheSameWrittenAddress() {
        let a = makeStop("Fam. Gruber", "Gentzgasse 129/1", "1180")
        let b = makeStop("Fam. Novak", "Gentzgasse 129/1", "1180")
        let groups = SameDoor.groups(for: [a, b])
        #expect(groups[a.id]?.count == 2)
        #expect(groups[b.id]?.count == 2)
    }

    @Test func groupsAcrossDifferentSpellingsOfOneAddress() {
        let a = makeStop("Fam. A", "Großfeldstraße 9/Parz.68", "1210")
        let b = makeStop("Fam. B", "Großfeldstrasse 9 Parz. 68", "1210")
        #expect(SameDoor.groups(for: [a, b])[a.id]?.count == 2)
    }

    @Test func groupsByExactCoordinateEvenWhenWrittenDifferently() {
        // Same registered point, two ways of writing it.
        let a = makeStop("Fam. A", "Gentzgasse 129/1", "1180", lat: 48.2301, lon: 16.3201)
        let b = makeStop("Fam. B", "Gentzgasse 129 Stiege 1", "1180", lat: 48.2301, lon: 16.3201)
        #expect(SameDoor.groups(for: [a, b])[a.id]?.count == 2)
    }

    @Test func doesNotGroupApproximateStopsSharingACentroid() {
        // Every unresolved address in a district lands on one centroid. Grouping
        // those would claim thirty unrelated customers live at one door.
        let a = makeStop("Fam. A", "Irgendgasse 1", "1100",
                         lat: 48.166, lon: 16.378, precision: .district)
        let b = makeStop("Fam. B", "Anderegasse 2", "1100",
                         lat: 48.166, lon: 16.378, precision: .district)
        let groups = SameDoor.groups(for: [a, b])
        #expect(groups[a.id]?.count == 1)
        #expect(groups[b.id]?.count == 1)
    }

    @Test func doesNotGroupTheSameStreetInDifferentDistricts() {
        let a = makeStop("Fam. A", "Hauptstraße 1", "1140", lat: 48.20, lon: 16.28)
        let b = makeStop("Fam. B", "Hauptstraße 1", "1190", lat: 48.24, lon: 16.34)
        #expect(SameDoor.groups(for: [a, b])[a.id]?.count == 1)
    }

    @Test func transitivelyMergesGroupsRevealedByAThirdStop() {
        // A and B share an address; B and C share a coordinate. All three are
        // one door — which "put each stop in the first group it matches" gets
        // wrong, and union-find gets right.
        let a = makeStop("Fam. A", "Gentzgasse 129", "1180", lat: 48.2301, lon: 16.3201)
        let b = makeStop("Fam. B", "Gentzgasse 129", "1180", lat: 48.2301, lon: 16.3201)
        let c = makeStop("Fam. C", "Gentzgasse 129 Stg 1", "1180", lat: 48.2301, lon: 16.3201)
        let groups = SameDoor.groups(for: [a, b, c])
        #expect(groups[a.id]?.count == 3)
        #expect(groups[c.id]?.count == 3)
    }

    @Test func aLoneStopIsItsOwnGroupOfOne() {
        let a = makeStop("Fam. A", "Gentzgasse 1", "1180")
        #expect(SameDoor.groups(for: [a])[a.id] == [a.id])
    }

    @Test func fixedStopsAreNotGrouped() {
        let start = Stop(
            kind: .start, kunde: "Start", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz,
            lat: Coordinates.start.lat, lon: Coordinates.start.lon)
        let end = Stop(
            kind: .end, kunde: "Ziel", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz,
            lat: Coordinates.start.lat, lon: Coordinates.start.lon)
        let groups = SameDoor.groups(for: [start, end])
        #expect(groups.isEmpty)
    }
}
