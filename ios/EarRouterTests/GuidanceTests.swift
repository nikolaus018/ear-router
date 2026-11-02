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

/// Dead reckoning and the line geometry under it.
struct GuidanceReckoningTests {
    private let route = GuidanceRoute(
        steps: [
            GuidanceStep(
                type: "depart", modifier: nil, name: "A", exit: nil, distance: 221,
                geometry: [[48.2000, 16.3000], [48.2020, 16.3000]]),
            GuidanceStep(
                type: "turn", modifier: "right", name: "B", exit: nil, distance: 111,
                geometry: [[48.2020, 16.3000], [48.2020, 16.3015]]),
            GuidanceStep(
                type: "arrive", modifier: nil, name: "", exit: nil, distance: 0,
                geometry: [[48.2020, 16.3015]]),
        ],
        geometry: [], distance: 332, duration: 60)

    @Test func snappedPointSitsOnTheLineWithTheRoadsBearing() {
        // 15 m east of the street, half way up it.
        let p = GuidanceEngine.progress(route: route, at: (48.2010, 16.30020))
        #expect(abs(p.lon - 16.3000) < 0.00001)
        #expect(abs(p.bearing - 0) < 1)
    }

    @Test func advancingMovesAlongTheRoadAndShortensTheDistance() {
        let p = GuidanceEngine.progress(route: route, at: (48.2000, 16.3000))
        let q = GuidanceEngine.advanced(p, on: route, by: 100)
        #expect(abs(q.metersToManeuver - 121) < 5)
        #expect(q.lat > p.lat)
    }

    @Test func advancingPastTheTurnCrossesIntoTheNextStepAndTurnsTheBearing() {
        let p = GuidanceEngine.progress(route: route, at: (48.2000, 16.3000))
        let q = GuidanceEngine.advanced(p, on: route, by: 250)
        #expect(q.stepIndex == 1)
        #expect(abs(q.bearing - 90) < 2)
    }

    @Test func advancingNeverRunsPastTheEndAndArrives() {
        let p = GuidanceEngine.progress(route: route, at: (48.2000, 16.3000))
        let q = GuidanceEngine.advanced(p, on: route, by: 5000)
        #expect(q.stepIndex == 1)
        #expect(q.arrived)
        #expect(abs(q.lon - 16.3015) < 0.00001)
    }

    @Test func bearingsAndAngleDeltas() {
        #expect(abs(GuidanceEngine.bearing((48.2, 16.3), (48.3, 16.3)) - 0) < 0.5)
        #expect(abs(GuidanceEngine.bearing((48.2, 16.3), (48.2, 16.4)) - 90) < 0.5)
        #expect(GuidanceEngine.angleDelta(from: 350, to: 10) == 20)
        #expect(GuidanceEngine.angleDelta(from: 10, to: 350) == -20)
    }
}

/// Speed limits from OpenStreetMap tags, matched onto the route.
struct SpeedLimitTests {
    // North along 16.3000 from 48.2000 for ~221 m.
    private let route = GuidanceRoute(
        steps: [
            GuidanceStep(
                type: "depart", modifier: nil, name: "A", exit: nil, distance: 221,
                geometry: [[48.2000, 16.3000], [48.2020, 16.3000]]),
            GuidanceStep(
                type: "arrive", modifier: nil, name: "", exit: nil, distance: 0,
                geometry: [[48.2020, 16.3000]]),
        ],
        geometry: [[48.2000, 16.3000], [48.2020, 16.3000]], distance: 221, duration: 30)

    @Test func matchesTheRoadUnderTheRoute() {
        let way = LimitWay(
            forward: 30, backward: 30, geometry: [[48.1990, 16.30003], [48.2030, 16.30003]])
        let profile = SpeedLimits.profile(route: route, ways: [way])
        #expect(profile.limit(step: 0, along: 100) == 30)
    }

    @Test func ignoresACrossingRoad() {
        let cross = LimitWay(
            forward: 70, backward: 70, geometry: [[48.2010, 16.2990], [48.2010, 16.3010]])
        let profile = SpeedLimits.profile(route: route, ways: [cross])
        #expect(profile.limit(step: 0, along: 110) == nil)
    }

    @Test func usesTheBackwardLimitAgainstTheWaysDirection() {
        // Way digitised southwards; the route drives north, against it.
        let way = LimitWay(
            forward: 50, backward: 30, geometry: [[48.2030, 16.30003], [48.1990, 16.30003]])
        let profile = SpeedLimits.profile(route: route, ways: [way])
        #expect(profile.limit(step: 0, along: 100) == 30)
    }

    @Test func bridgesSmallGapsButNotRealChanges() {
        #expect(SpeedLimits.fillSmallGaps([50, nil, nil, 50]) == [50, 50, 50, 50])
        #expect(SpeedLimits.fillSmallGaps([50, nil, nil, 30]) == [50, nil, nil, 30])
        #expect(SpeedLimits.fillSmallGaps([nil, nil, 50]) == [nil, nil, 50])
    }

    @Test func theBundledViennaFileLoads() throws {
        let ways = try #require(SpeedLimits.bundled)
        #expect(ways.count > 40_000)
        #expect(ways.contains { $0.forward == 30 })
    }

    @Test func readsThePackedFormat() throws {
        let json = #"[[30,null,[48.2,16.3,48.201,16.3]],[null,null,[48.2,16.3]]]"#
        let ways = try #require(SpeedLimits.parse(Data(json.utf8)))
        #expect(ways.count == 1)
        #expect(ways[0].forward == 30 && ways[0].backward == nil)
        #expect(ways[0].geometry[1] == [48.201, 16.3])
    }
}

struct SpeedCameraTests {
    private let route = GuidanceRoute(
        steps: [
            GuidanceStep(
                type: "depart", modifier: nil, name: "A", exit: nil, distance: 221,
                geometry: [[48.2000, 16.3000], [48.2020, 16.3000]]),
            GuidanceStep(
                type: "turn", modifier: "right", name: "B", exit: nil, distance: 111,
                geometry: [[48.2020, 16.3000], [48.2020, 16.3015]]),
            GuidanceStep(
                type: "arrive", modifier: nil, name: "", exit: nil, distance: 0,
                geometry: [[48.2020, 16.3015]]),
        ],
        geometry: [], distance: 332, duration: 60)

    @Test func findsOnlyCamerasOnTheRoute() {
        let points = [
            SpeedCameras.Point(lat: 48.2010, lon: 16.30005, kmh: 50),   // on the street
            SpeedCameras.Point(lat: 48.2010, lon: 16.3010, kmh: 30),    // 75 m away
            SpeedCameras.Point(lat: 48.2020, lon: 16.3010, kmh: nil),   // after the turn
        ]
        let profile = SpeedCameras.profile(route: route, points: points)
        #expect(profile.cameras.count == 2)
        #expect(abs(profile.cameras[0].along - 110) < 5)
        #expect(profile.cameras[0].kmh == 50)
        #expect(abs(profile.cameras[1].along - (221 + 74)) < 6)
    }

    @Test func warnsOnlyAheadAndWithinRange() {
        let points = [SpeedCameras.Point(lat: 48.2010, lon: 16.30005, kmh: 50)]
        let profile = SpeedCameras.profile(route: route, points: points)
        #expect(profile.next(step: 0, along: 0, within: 800)?.kmh == 50)
        #expect(profile.next(step: 0, along: 0, within: 50) == nil)
        #expect(profile.next(step: 0, along: 150, within: 800) == nil)
    }

    @Test func aPairAtOnePlaceIsOneCamera() {
        let points = [
            SpeedCameras.Point(lat: 48.2010, lon: 16.30005, kmh: 50),
            SpeedCameras.Point(lat: 48.20101, lon: 16.29995, kmh: 50),
        ]
        #expect(SpeedCameras.profile(route: route, points: points).cameras.count == 1)
    }

    @Test func readsTheBundledFormat() {
        let pts = SpeedCameras.parse(Data("[[48.2,16.3,50],[48.3,16.4,null]]".utf8))
        #expect(pts == [.init(lat: 48.2, lon: 16.3, kmh: 50), .init(lat: 48.3, lon: 16.4, kmh: nil)])
    }
}

struct UpcomingManeuverTests {
    private func step(_ type: String, _ modifier: String?, _ distance: Double, _ geometry: [[Double]]) -> GuidanceStep {
        GuidanceStep(type: type, modifier: modifier, name: "X", exit: nil, distance: distance, geometry: geometry)
    }

    @Test func skipsRoadNameChangesAndAddsTheirDistance() {
        let route = GuidanceRoute(
            steps: [
                step("depart", nil, 100, [[48.2000, 16.3000], [48.2009, 16.3000]]),
                step("new name", "straight", 200, [[48.2009, 16.3000], [48.2027, 16.3000]]),
                step("turn", "left", 50, [[48.2027, 16.3000], [48.2027, 16.2993]]),
                step("arrive", nil, 0, [[48.2027, 16.2993]]),
            ],
            geometry: [], distance: 350, duration: 40)
        let p = GuidanceEngine.progress(route: route, at: (48.2000, 16.3000))
        let up = try! #require(GuidanceEngine.upcoming(route: route, progress: p))
        #expect(up.index == 2)
        #expect(up.step.modifier == "left")
        #expect(abs(up.meters - 300) < 8)
    }

    @Test func remainderStartsAtTheVanAndKeepsTheRest() {
        let line: [[Double]] = [[48.2000, 16.3000], [48.2020, 16.3000]]
        let rest = GuidanceEngine.remainder(of: line, from: 110)
        #expect(rest.count == 2)
        #expect(abs(rest[0][0] - 48.2010) < 0.0001)
        #expect(rest[1] == [48.2020, 16.3000])
    }
}
