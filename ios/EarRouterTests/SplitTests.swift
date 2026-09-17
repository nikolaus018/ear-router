import CoreGraphics
import CoreLocation
import Testing
@testable import EarRouter

/// Splitting a tour between people: who ends up with which door, and what the
/// shares are called once they become tours.
struct SplitStateTests {

    private func state(_ count: Int = 6, people: Int = 3) -> SplitState {
        let stops = (0..<count).map {
            SplitStop(
                id: $0, name: "Kunde \($0)", address: "Gentzgasse \($0 + 1)", plz: "1180",
                coordinate: CLLocationCoordinate2D(latitude: 48.23, longitude: 16.34))
        }
        return SplitState(tourName: "VM 4 DO Vormittag", people: people, stops: stops)
    }

    @Test func circlingTakesOnlyTheFreeStops() {
        var split = state()
        split.claim([0, 1], for: 0)
        // Person 2 circles across one of person 1's: a circle never takes what
        // somebody already has.
        let added = split.claim([1, 2], for: 1)
        #expect(added == 1)
        #expect(split.owner(of: split.stops[1]) == 0)
        #expect(split.owner(of: split.stops[2]) == 1)
    }

    @Test func tappingTakesAStopFromWhoeverHasIt() {
        var split = state()
        split.claim([0], for: 0)
        split.toggle(0, for: 1)
        #expect(split.owner(of: split.stops[0]) == 1)
    }

    @Test func tappingYourOwnStopFreesItAgain() {
        var split = state()
        split.claim([0], for: 0)
        split.toggle(0, for: 0)
        #expect(split.owner(of: split.stops[0]) == nil)
        #expect(split.freeCount == 6)
    }

    @Test func undoGoesBackOneStepAtATime() {
        var split = state()
        split.claim([0, 1], for: 0)
        split.claim([2], for: 1)
        split.undo()
        #expect(split.stops(of: 1).isEmpty)
        #expect(split.stops(of: 0).count == 2)
        split.undo()
        #expect(split.freeCount == 6)
        #expect(!split.canUndo)
    }

    @Test func claimingNothingIsNotAStepToUndo() {
        var split = state()
        split.claim([0], for: 0)
        // Every id already belongs to person 1 — nothing changes, so there is
        // nothing for "Rückgängig" to take back but the first claim.
        #expect(split.claim([0], for: 1) == 0)
        split.undo()
        #expect(split.freeCount == 6)
    }

    @Test func resetFreesEverythingAndCanBeTakenBack() {
        var split = state()
        split.claim([0, 1, 2], for: 0)
        split.reset()
        #expect(split.freeCount == 6)
        split.undo()
        #expect(split.stops(of: 0).count == 3)
    }

    @Test func aShareIsNamedAfterTheTourAndThePerson() {
        let split = state()
        #expect(split.routeName(for: 1) == "VM 4 DO Vormittag · P2")
    }

    @Test func aNameAlreadyOpenGetsItsDayAppended() {
        let split = SplitState(
            tourName: "VM 4 DO Vormittag",
            date: Date(timeIntervalSince1970: 1_757_980_800),  // 16.09.2026
            people: 2, stops: [])
        let taken: Set<String> = ["VM 4 DO Vormittag · P1"]
        let name = split.routeName(for: 0, taken: taken)
        #expect(name.hasPrefix("VM 4 DO Vormittag · P1 – "))
        #expect(name != "VM 4 DO Vormittag · P1")
    }

    @Test func theSharedTextNamesEveryPersonAndWhatIsLeft() {
        var split = state(4, people: 2)
        split.claim([0, 1], for: 0)
        split.claim([2], for: 1)
        let text = split.shareText
        #expect(text.contains("VM 4 DO Vormittag"))
        #expect(text.contains("Person 1 (2)"))
        #expect(text.contains("Person 2 (1)"))
        #expect(text.contains("Nicht zugeteilt (1)"))
    }

    @Test func aFullyDealtSplitSaysNothingAboutLeftovers() {
        var split = state(2, people: 2)
        split.claim([0, 1], for: 0)
        #expect(!split.shareText.contains("Nicht zugeteilt"))
    }

    /// The stop as it reaches the import when the portal's detail call is not
    /// available — name and address, which is all the split ever loaded.
    @Test func aStopWithoutDetailsStillBecomesAnEntry() {
        let stop = SplitStop(
            id: 7, name: "Fam. Gruber", address: "Gentzgasse 129/1", plz: "1180",
            coordinate: nil)
        let entry = stop.plainEntry
        #expect(entry.kunde == "Fam. Gruber")
        #expect(entry.strasse == "Gentzgasse 129/1")
        #expect(entry.plz == "1180")
        #expect(entry.paket == nil)
    }
}

/// What a finger drew round on the map.
struct LassoTests {
    private let square = [
        CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
    ]

    @Test func aPointInsideIsCircled() {
        #expect(Lasso.contains(CGPoint(x: 50, y: 50), in: square))
    }

    @Test func aPointOutsideIsNot() {
        #expect(!Lasso.contains(CGPoint(x: 150, y: 50), in: square))
    }

    @Test func theNotchOfAConcaveShapeStaysOutside() {
        // A "U": the gap between the arms is not inside it.
        let u = [
            CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 70),
            CGPoint(x: 70, y: 70), CGPoint(x: 70, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
        ]
        #expect(!Lasso.contains(CGPoint(x: 50, y: 30), in: u))
        #expect(Lasso.contains(CGPoint(x: 15, y: 30), in: u))
    }

    @Test func aStrokeWithNoAreaCirclesNothing() {
        #expect(!Lasso.contains(.zero, in: [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: 1)]))
    }

    /// A circle drawn tight around a pin usually clips its edge rather than
    /// enclosing its centre, and the driver meant to have it.
    @Test func aPinTheLineRunsThroughCounts() {
        #expect(Lasso.catches(CGPoint(x: 100, y: 50), in: square, radius: 14))
        #expect(Lasso.catches(CGPoint(x: 108, y: 50), in: square, radius: 14))
        #expect(!Lasso.catches(CGPoint(x: 130, y: 50), in: square, radius: 14))
    }
}
