import Testing
import Foundation
@testable import EarRouter

/// The in-app guidance's arithmetic: which step the van is on, how far to the
/// turn, when it has left the line. Along a straight street running north from
/// 48.2000, 16.3000 that turns right after ~222 m and ends ~111 m later.
struct GuidanceTests {

    // 0.002° latitude ≈ 221 m; 0.001° longitude at 48.2° ≈ 74 m.
    private let route = GuidanceRoute(
        steps: [
            GuidanceStep(
                type: "depart", modifier: nil, name: "Gentzgasse", exit: nil, distance: 221,
                geometry: [[48.2000, 16.3000], [48.2020, 16.3000]]),
            GuidanceStep(
                type: "turn", modifier: "right", name: "Währinger Straße", exit: nil, distance: 111,
                geometry: [[48.2020, 16.3000], [48.2020, 16.3015]]),
            GuidanceStep(
                type: "arrive", modifier: nil, name: "", exit: nil, distance: 0,
                geometry: [[48.2020, 16.3015]]),
        ],
        geometry: [], distance: 332, duration: 60)

    @Test func distanceToTheTurnShrinksAlongTheStreet() {
        let start = GuidanceEngine.progress(route: route, at: (48.2000, 16.3000))
        let later = GuidanceEngine.progress(route: route, at: (48.2010, 16.3000))
        #expect(start.stepIndex == 0)
        #expect(abs(start.metersToManeuver - 221) < 5)
        #expect(abs(later.metersToManeuver - 110) < 5)
        #expect(!later.offRoute && !later.arrived)
    }

    @Test func advancesToTheNextStepAfterTheTurn() {
        let p = GuidanceEngine.progress(route: route, at: (48.2020, 16.3007), after: 0)
        #expect(p.stepIndex == 1)
        #expect(p.metersToManeuver > 0 && p.metersToManeuver < 111)
    }

    @Test func farFromTheLineIsOffRoute() {
        // ~150 m east of the street.
        let p = GuidanceEngine.progress(route: route, at: (48.2010, 16.3020))
        #expect(p.offRoute)
    }

    @Test func gpsNoiseOnTheLineIsNotOffRoute() {
        // ~15 m east.
        let p = GuidanceEngine.progress(route: route, at: (48.2010, 16.30020))
        #expect(!p.offRoute)
    }

    @Test func arrivesNearTheEnd() {
        let p = GuidanceEngine.progress(route: route, at: (48.2020, 16.3014), after: 1)
        #expect(p.arrived)
    }

    @Test func routeWithoutManeuversCountsAsArrived() {
        let empty = GuidanceRoute(steps: [], geometry: [], distance: 0, duration: 0)
        #expect(GuidanceEngine.progress(route: empty, at: (48.2, 16.3)).arrived)
    }

    @Test func germanInstructions() {
        #expect(ManeuverText.instruction(route.steps[1]) == "Rechts abbiegen auf Währinger Straße")
        #expect(ManeuverText.instruction(route.steps[2]) == "Ziel erreicht")
        let round = GuidanceStep(
            type: "roundabout", modifier: "right", name: "Gürtel", exit: 2, distance: 50, geometry: [])
        #expect(ManeuverText.instruction(round) == "Im Kreisverkehr 2. Ausfahrt nehmen auf Gürtel")
        #expect(ManeuverText.spoken(route.steps[1], in: 240).hasPrefix("In 250 Metern: "))
        #expect(ManeuverText.spoken(route.steps[1], in: 30) == "Rechts abbiegen auf Währinger Straße")
    }

    @Test func providerChoiceStillHandsOutsideUrlsToAppleMaps() {
        let url = NavigationHandoff.Provider.inApp.point(lat: 48.2, lon: 16.3)
        #expect(url?.host == "maps.apple.com")
    }
}
