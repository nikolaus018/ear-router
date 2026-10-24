import CoreLocation
import Testing
@testable import EarRouter

struct CompassTests {
    private let here = CLLocationCoordinate2D(latitude: 48.2200, longitude: 16.3500)

    @Test func bearingsFollowTheCompassRose() {
        let north = CLLocationCoordinate2D(latitude: 48.2210, longitude: 16.3500)
        let east = CLLocationCoordinate2D(latitude: 48.2200, longitude: 16.3515)
        let south = CLLocationCoordinate2D(latitude: 48.2190, longitude: 16.3500)
        let west = CLLocationCoordinate2D(latitude: 48.2200, longitude: 16.3485)
        #expect(abs(CompassMath.bearing(from: here, to: north) - 0) < 0.5)
        #expect(abs(CompassMath.bearing(from: here, to: east) - 90) < 0.5)
        #expect(abs(CompassMath.bearing(from: here, to: south) - 180) < 0.5)
        #expect(abs(CompassMath.bearing(from: here, to: west) - 270) < 0.5)
    }

    @Test func relativeAngleWrapsAround() {
        #expect(CompassMath.relative(bearing: 10, facing: 350) == 20)
        #expect(CompassMath.relative(bearing: 350, facing: 10) == 340)
        #expect(CompassMath.relative(bearing: 90, facing: 90) == 0)
    }

    @Test func anglesAndDistancesAreRounded() {
        #expect(CompassMath.quantized(7) == 0)
        #expect(CompassMath.quantized(8) == 15)
        #expect(CompassMath.quantized(359) == 0)
        #expect(CompassMath.roundedMeters(47) == 50)
        #expect(CompassMath.roundedMeters(113) == 125)
    }

    @Test func theArrowShowsOnlyWhenCloseAndHasHysteresis() {
        let far = CompassMath.hint(distance: 400, bearing: 0, facing: 0, wasShown: false)
        #expect(far == nil)
        // Appears inside 250, stays until 300.
        #expect(CompassMath.hint(distance: 260, bearing: 0, facing: 0, wasShown: false) == nil)
        #expect(CompassMath.hint(distance: 240, bearing: 0, facing: 0, wasShown: false) != nil)
        #expect(CompassMath.hint(distance: 290, bearing: 0, facing: 0, wasShown: true) != nil)
        #expect(CompassMath.hint(distance: 310, bearing: 0, facing: 0, wasShown: true) == nil)
    }

    @Test func arrowPointsRelativeToFacing() throws {
        let h = try #require(CompassMath.hint(distance: 100, bearing: 90, facing: 0, wasShown: false))
        #expect(h.grad == 90 && !h.da)
    }

    @Test func atTheDoorItSaysSoAndNeedsNoDirection() throws {
        let h = try #require(CompassMath.hint(distance: 12, bearing: 33, facing: nil, wasShown: false))
        #expect(h.da)
    }

    @Test func withoutADirectionThereIsNoArrow() {
        #expect(CompassMath.hint(distance: 100, bearing: 33, facing: nil, wasShown: false) == nil)
    }
}
