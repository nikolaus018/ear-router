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

    /// Two *neighbouring* buildings are two doors.
    ///
    /// The point grouping quantises to about a metre, which is what lets the
    /// same registered address survive being re-geocoded a few billionths of a
    /// degree away. Loosened to ten metres it would start merging the house
    /// next door — and "2 an dieser Tür" is a claim the driver acts on by
    /// carrying two meals to one bell.
    @Test func neighbouringBuildingsAreNotOneDoor() {
        // ~3 m apart in latitude: two distinct buckets at five decimal places
        // and one shared bucket at four. Different addresses, so the point is
        // the only thing that could join them. (Picked deliberately — eight
        // metres apart still straddles a four-decimal boundary, so a test
        // built on that would pass at either tolerance.)
        let a = makeStop("Fam. A", "Gentzgasse 129", "1180", lat: 48.23011, lon: 16.3201)
        let b = makeStop("Fam. B", "Gentzgasse 131", "1180", lat: 48.23014, lon: 16.3201)
        let counts = SameDoor.counts(for: [a, b])
        #expect(counts[a.id] == 1)
        #expect(counts[b.id] == 1)
    }

    /// And the tolerance it does have still earns its keep: the same door,
    /// re-resolved, comes back a few billionths of a degree away.
    @Test func theSameDoorSurvivesBeingReGeocoded() {
        let a = makeStop("Fam. A", "Gentzgasse 129", "1180", lat: 48.2301, lon: 16.3201)
        let b = makeStop("Fam. B", "Gentzgasse 131", "1180",
                         lat: 48.230100000003, lon: 16.320099999998)
        #expect(SameDoor.counts(for: [a, b])[a.id] == 2)
    }

    /// An address nobody wrote is not an address two people share.
    ///
    /// No screen in the app can produce a customer stop with no street, but a
    /// hand-edited backup can — and every one of them keyed to the same empty
    /// address, so two unrelated customers came back as "2 an dieser Tür".
    /// Their points are the unusable default, which `PointDoor` already
    /// refuses, so the address was the only thing joining them.
    @Test func stopsWithNoStreetAreNotAllOneDoor() {
        let a = makeStop("Fam. A", "", "1210", lat: 0, lon: 0)
        let b = makeStop("Fam. B", "", "1210", lat: 0, lon: 0)
        let counts = SameDoor.counts(for: [a, b])
        #expect(counts[a.id] == 1)
        #expect(counts[b.id] == 1)
    }

    /// Even where such a row does have a real point, it still groups by that
    /// point and not by its missing address — so a genuine shared door is not
    /// lost with the fix above.
    @Test func aStopWithNoStreetStillSharesARealPoint() {
        let a = makeStop("Fam. A", "", "1180", lat: 48.2301, lon: 16.3201)
        let b = makeStop("Fam. B", "", "1180", lat: 48.2301, lon: 16.3201)
        #expect(SameDoor.counts(for: [a, b])[a.id] == 2)
    }
}
