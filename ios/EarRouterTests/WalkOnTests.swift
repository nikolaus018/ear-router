import Foundation
import Testing
import SwiftData
@testable import EarRouter

/// Which doors are carried along from the one the van is standing at, and when
/// "Geliefert" starts the navigation by itself.
@MainActor
struct WalkOnTests {

    /// A customer in 1210, `north` metres up the street from the first one.
    private func door(_ name: String, north: Double, kind: StopKind = .customer) -> Stop {
        Stop(
            kind: kind, kunde: name, strasse: "Brünner Straße 34", plz: "1210",
            paket: "1x Menü", lat: 48.2620 + north / 111_000, lon: 16.4007)
    }

    @Test func listsTheDoorsWithinAWalk() {
        let a = door("A", north: 0), b = door("B", north: 60), c = door("C", north: 90)
        let far = door("D", north: 400)
        let doors = WalkOn.doors(after: a, in: [a, b, c, far])
        #expect(doors.map(\.name) == ["B", "C"])
        #expect(doors.first?.distance == "60 m")
        #expect(doors.first?.paket == "1x Menü")
    }

    @Test func stopsAtTheFirstDoorThatIsDrivenTo() {
        // C is back beside A, but D lies between them on the tour.
        let a = door("A", north: 0), d = door("D", north: 400), c = door("C", north: 20)
        #expect(WalkOn.doors(after: a, in: [a, d, c]).isEmpty)
    }

    @Test func passesOverDoorsAlreadyAnsweredFor() {
        let a = door("A", north: 0), b = door("B", north: 30), c = door("C", north: 50)
        b.delivered = true
        #expect(WalkOn.doors(after: a, in: [a, b, c]).map(\.name) == ["C"])
    }

    @Test func theSameHouseIsHere() {
        let a = door("A", north: 0), b = door("B", north: 3)
        #expect(WalkOn.doors(after: a, in: [a, b]).first?.distance == "hier")
    }

    @Test func nothingIsCarriedToTheZielOrFromTheLager() {
        let lager = door("Lager", north: 0, kind: .via)
        let a = door("A", north: 10), ziel = door("Ziel", north: 20, kind: .end)
        #expect(WalkOn.doors(after: lager, in: [lager, a, ziel]).isEmpty)
        #expect(WalkOn.doors(after: a, in: [lager, a, ziel]).isEmpty)
    }

    @Test func theStreetDoorCountsAsWhereAHouseIs() {
        // B's Stiege is 150 m off, its street door beside A.
        let a = door("A", north: 0), b = door("B", north: 150)
        b.setEntrance((lat: a.lat + 20.0 / 111_000, lon: a.lon))
        #expect(WalkOn.doors(after: a, in: [a, b]).count == 1)
    }

    @Test func anAddressNobodyFoundIsNotNextDoor() {
        // Both on the district's midpoint, which is where neither of them is.
        let a = door("A", north: 0), b = door("B", north: 0)
        a.precision = .district
        b.precision = .district
        #expect(WalkOn.doors(after: a, in: [a, b]).isEmpty)
        let found = door("C", north: 0)
        #expect(WalkOn.doors(after: found, in: [found, b]).isEmpty)
    }

    // MARK: - Geliefert, and on

    @Test func continuesToADoorThatIsDrivenTo() {
        let a = door("A", north: 0), far = door("D", north: 400)
        let next = AutoContinue.destination(
            after: a, outcome: .delivered, next: far, enabled: true)
        #expect(next?.id == far.id)
        // Nobody home is still a door stood at.
        #expect(
            AutoContinue.destination(
                after: a, outcome: .notHome, next: far, enabled: true) != nil)
    }

    @Test func staysPutForADoorThatIsWalkedTo() {
        let a = door("A", north: 0), b = door("B", north: 60)
        #expect(
            AutoContinue.destination(
                after: a, outcome: .delivered, next: b, enabled: true) == nil)
    }

    @Test func staysPutWhenThereIsNoDrivingToDo() {
        let a = door("A", north: 0), far = door("D", north: 400)
        func go(_ outcome: DeliveryOutcome, next: Stop?, on: Bool = true)
            -> Stop?
        {
            AutoContinue.destination(
                after: a, outcome: outcome, next: next, enabled: on)
        }
        // Noted from the phone, not at a door.
        #expect(go(.cancelled, next: far) == nil)
        #expect(go(.toLager, next: far) == nil)
        // The tour is done, or it is switched off.
        #expect(go(.delivered, next: nil) == nil)
        #expect(go(.delivered, next: far, on: false) == nil)
    }

    @Test func aStopJustSentToTheNavigationIsUnderWay() {
        let defaults = UserDefaults(suiteName: "WalkOnTests.\(UUID().uuidString)")!
        let stop = UUID(), other = UUID()
        let sent = Date(timeIntervalSince1970: 1_000_000)
        #expect(!NavigationHandoff.isUnderWay(to: stop, at: sent, in: defaults))
        NavigationHandoff.noteStarted(stop, at: sent, in: defaults)
        #expect(NavigationHandoff.isUnderWay(to: stop, at: sent + 120, in: defaults))
        // Another stop, or the same one after a break, is asked for again.
        #expect(!NavigationHandoff.isUnderWay(to: other, at: sent + 120, in: defaults))
        #expect(!NavigationHandoff.isUnderWay(to: stop, at: sent + 11 * 60, in: defaults))
        #expect(!NavigationHandoff.isUnderWay(to: stop, at: sent - 60, in: defaults))
    }

    @Test func everyNavigationAppCanBeBroughtToTheFront() {
        for provider in NavigationHandoff.Provider.allCases {
            #expect(provider.front != nil)
        }
    }

    @Test func goesOnFromTheLagerToTheFirstDoor() {
        let lager = door("Lager", north: 0, kind: .via), a = door("A", north: 30)
        #expect(
            AutoContinue.destination(
                after: lager, outcome: .delivered, next: a, enabled: true)
                != nil)
    }
}
