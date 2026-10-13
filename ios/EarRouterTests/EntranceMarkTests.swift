import Testing
import CoreLocation
@testable import EarRouter

/// The door mark Karte draws beside a pin that is not on the street door.
struct EntranceMarkTests {

    private func at(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    @Test func noMarkForADoorUnderItsPin() {
        // About five metres apart: the balloon covers it.
        let marks = MapTab.entranceMarks(for: [(at(48.2, 16.37), at(48.20004, 16.37003))])
        #expect(marks.isEmpty)
    }

    @Test func marksADoorAwayFromItsPin() {
        // About forty metres north.
        let marks = MapTab.entranceMarks(for: [(at(48.2, 16.37), at(48.20036, 16.37))])
        #expect(marks.count == 1)
        #expect(marks.first?.latitude == 48.20036)
        #expect(marks.first?.pins.count == 1)
        #expect(marks.first?.pins.first?.latitude == 48.2)
    }

    @Test func stiegenBehindOneDoorShareItsMark() {
        let door = at(48.2, 16.37)
        let marks = MapTab.entranceMarks(for: [
            (at(48.2005, 16.37), door),
            (at(48.2005, 16.3706), door),
            // Two customers under one pin are one thread, not two.
            (at(48.2005, 16.3706), door),
        ])
        #expect(marks.count == 1)
        #expect(marks.first?.pins.count == 2)
    }

    @Test func twoHousesKeepTheirOwnDoors() {
        let marks = MapTab.entranceMarks(for: [
            (at(48.2005, 16.37), at(48.2, 16.37)),
            (at(48.2105, 16.38), at(48.21, 16.38)),
        ])
        #expect(marks.map(\.pins.count) == [1, 1])
    }
}
