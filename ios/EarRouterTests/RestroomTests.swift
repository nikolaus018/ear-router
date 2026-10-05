import Foundation
import Testing
@testable import EarRouter

/// The WC button: which toilet, and where on the tour it goes.
struct RestroomTests {
    private typealias Point = RestroomPicker.Point

    private func restroom(
        _ name: String, _ lat: Double, _ lon: Double, walk: Int = 0,
        hours: [[Int]?]? = nil, winterClosed: Bool? = nil
    ) -> Restroom {
        Restroom(
            name: name, lat: lat, lon: lon, walk: walk, hours: hours,
            winterClosed: winterClosed, oeklo: nil)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// Straight-line minutes over `anchors + candidates`, as `choose` indexes them.
    private func crow(_ anchors: [Point], _ candidates: [Restroom]) -> (Int, Int) -> Double? {
        let points = anchors + candidates.map { Point(lat: $0.lat, lon: $0.lon) }
        return { RestroomPicker.crowMinutes(points[$0], points[$1]) }
    }

    // A tour running north along one street, a stop every ~550 m.
    private let anchors = (0..<5).map { Point(lat: 48.20 + Double($0) * 0.005, lon: 16.37) }

    @Test func bundledFileReadsBothSourcesAndIsAllInAustria() {
        #expect(Restroom.all.count { $0.oeklo != true } > 120)
        #expect(Restroom.all.count { $0.oeklo == true } > 250)
        #expect(Restroom.all.allSatisfy { Coordinates.isPlausible(lat: $0.lat, lon: $0.lon) })
        #expect(Restroom.all.allSatisfy { !$0.name.isEmpty })
    }

    @Test func everyToiletHasItsOwnPin() {
        #expect(Restroom.pinsByID.count == Restroom.all.count)
        let some = Restroom.all[Restroom.all.count / 2]
        #expect(some.pin.flatMap { Restroom.pinsByID[$0.id] }?.restroom == some)
        #expect(restroom("gone", 48.2, 16.37).pin == nil)
    }

    @Test @MainActor func aBannedToiletStaysBannedUntilTakenBack() {
        let r = restroom("shut-\(UUID().uuidString)", 48.2, 16.37)
        RestroomPlan.shared.ban(r)
        #expect(RestroomPlan.shared.isBanned(r))
        // The same toilet after a refresh corrected its walk and its hours.
        let refreshed = restroom(r.name, 48.2, 16.37, walk: 40, hours: Array(repeating: [0, 600], count: 7))
        #expect(RestroomPlan.shared.isBanned(refreshed))
        RestroomPlan.shared.unban(r)
        #expect(!RestroomPlan.shared.isBanned(r))
    }

    @Test func neitherKindOfToiletIsPreferred() {
        // The same spot once as the city's and once as öKlo's: whichever is
        // listed first wins, either way round.
        let city = restroom("city", 48.2025, 16.37)
        var oeklo = restroom("oeklo", 48.2025, 16.37)
        oeklo.oeklo = true
        for pair in [[city, oeklo], [oeklo, city]] {
            let choice = RestroomPicker.choose(
                anchors: anchors, candidates: pair, doorMinutes: 4, firstIsStop: false,
                minutes: crow(anchors, pair))
            #expect(choice?.restroom == pair[0])
        }
    }

    // MARK: - Fetching the list again

    @Test func readsAPlainTimetable() throws {
        let parsed = try #require(RestroomUpdater.hours("Mo-Fr: 6-18.30 Uhr \r\nSA: 6-17 Uhr"))
        let week = [360, 1110]
        #expect(parsed.table == [week, week, week, week, week, [360, 1020], nil])
        #expect(!parsed.winterClosed)
    }

    @Test func roundTheClockHasNoTableAndKeepsItsWinterClosure() throws {
        #expect(try #require(RestroomUpdater.hours("Mo-So: 0-24:00 Uhr")).table == nil)
        let winter = try #require(
            RestroomUpdater.hours("Mo-So: 0-24 Uhr/ Wintersperre von November bis März "))
        #expect(winter.table == nil)
        #expect(winter.winterClosed)
    }

    @Test(arguments: [
        "Lokalöffnungszeiten", "Parköffnungszeiten", "Gesperrt", "",
        "Mär-Okt:\r\nMo-So: 11-17 Uhr\r\nNov-Feb:Mo-So: 0-24 Uhr",
        "Jan-April+Okt-Nov:\r\nMo-Sa: 9-18 Uhr\r\nMai-Sep+Dez:\r\nMo-So: 9-19 Uhr",
    ])
    func leavesOutHoursItCannotRead(_ text: String) {
        #expect(RestroomUpdater.hours(text) == nil)
    }

    @Test func readsTheCitysListWithoutPissoirsStaffedOnesOrUnreadableHours() throws {
        func feature(_ street: String, _ kind: String, _ hours: String) -> String {
            """
            {"type":"Feature","geometry":{"type":"Point","coordinates":[16.338422,48.177641]},
             "properties":{"STRASSE":"\(street)","ONR":null,"OEFFNUNGSZEIT":"\(hours)",
             "KATEGORIE":"\(kind)"}}
            """
        }
        let json = """
            {"features":[\(feature("Markt", "WC-Anlage ohne Wartepersonal", "Mo-Sa: 7-18 Uhr")),
            \(feature("Gasse", "Pissoir", "Mo-So: 0-24 Uhr")),
            \(feature("Station", "WC-Anlage mit Euro-Key-Behindertenkabine und mit Wartepersonal", "Mo-So: 0-24 Uhr")),
            \(feature("Lokal", "WC-Anlage ohne Wartepersonal", "Lokalöffnungszeiten"))]}
            """
        let rows = try RestroomUpdater.parseCity(Data(json.utf8))
        #expect(rows.map(\.name) == ["Markt"])
        #expect(rows.first?.lat == 48.177641)
        #expect(rows.first?.hours?.last == .some(nil))
    }

    @Test func readsOeklosListAndDropsTheCityFromTheName() throws {
        let json = """
            {"features":[{"geometry":{"type":"Point","coordinates":[16.366711,48.214323]},
            "properties":{"accessible":false,"address":"Börseplatz 6, Wien","changing_table":false,"count":1}},
            {"geometry":{"type":"Point","coordinates":[13.600526,47.627511]},
            "properties":{"accessible":false,"address":"Muth 1-12, Bad Goisern","changing_table":false,"count":1}}]}
            """
        let rows = try RestroomUpdater.parseOeklo(Data(json.utf8))
        #expect(rows.map(\.name) == ["Börseplatz 6", "Muth 1-12, Bad Goisern"])
        #expect(rows.allSatisfy { $0.oeklo == true && $0.label == "öKlo" })
    }

    @Test func theAppReadsTheHoursTheBundledFileWasBuiltWith() {
        // Every timetable in the shipped file is one the tool parsed; the app
        // must agree with it on what the plain ones mean.
        let span = [420, 1080]
        #expect(RestroomUpdater.hours("Mo-Sa: 7-18 Uhr")?.table
            == [span, span, span, span, span, span, nil])
        #expect(RestroomUpdater.hours("Mo-Do: 8-13 Uhr +Fr-Sa: 7-13 Uhr")?.table
            == [[480, 780], [480, 780], [480, 780], [480, 780], [420, 780], [420, 780], nil])
    }

    @Test func alwaysOpenWithoutATable() {
        #expect(restroom("a", 48.2, 16.37).isOpen(at: date("2026-10-05T03:00:00+02:00")))
    }

    @Test func closedOutsideItsHoursAndOnAClosedDay() {
        let span = [420, 1080]  // 7–18
        let r = restroom("a", 48.2, 16.37, hours: [span, span, span, span, span, span, nil])
        #expect(r.isOpen(at: date("2026-10-05T12:00:00+02:00")))   // a Monday
        #expect(!r.isOpen(at: date("2026-10-05T06:30:00+02:00")))
        #expect(!r.isOpen(at: date("2026-10-11T12:00:00+02:00")))  // a Sunday
    }

    @Test func notOpenWhenItShutsBeforeTheDriverGetsThere() {
        let span = [420, 1080]
        let r = restroom("a", 48.2, 16.37, hours: Array(repeating: span, count: 7))
        #expect(!r.isOpen(at: date("2026-10-05T17:50:00+02:00")))
    }

    @Test func winterClosureRunsNovemberToMarch() {
        let r = restroom("a", 48.2, 16.37, winterClosed: true)
        #expect(r.isOpen(at: date("2026-10-05T12:00:00+02:00")))
        #expect(!r.isOpen(at: date("2026-11-05T12:00:00+01:00")))
        #expect(!r.isOpen(at: date("2027-03-31T12:00:00+02:00")))
        #expect(r.isOpen(at: date("2027-04-01T12:00:00+02:00")))
    }

    @Test func takesTheOneOnTheWayOverANearerOneOffIt() {
        // On the line between the driver and the first stop, against one the
        // same distance from the driver but off to the side.
        let onTheWay = restroom("on", 48.2025, 16.37)
        let aside = restroom("aside", 48.20, 16.3737)
        let choice = RestroomPicker.choose(
            anchors: anchors, candidates: [aside, onTheWay], doorMinutes: 4, firstIsStop: false,
            minutes: crow(anchors, [aside, onTheWay]))
        #expect(choice?.restroom == onTheWay)
        #expect(choice?.gap == 0)
        #expect((choice?.detourMinutes ?? 9) < 0.1)
    }

    @Test func waitsAStopOrTwoRatherThanDriveAcrossTown() {
        // Nothing near now; one right on the road after the second stop.
        let far = restroom("far", 48.20, 16.42)
        let later = restroom("later", 48.2125, 16.37)
        let choice = RestroomPicker.choose(
            anchors: anchors, candidates: [far, later], doorMinutes: 4, firstIsStop: false,
            minutes: crow(anchors, [far, later]))
        #expect(choice?.restroom == later)
        #expect(choice?.gap == 2)
    }

    @Test func goesNowWhenLaterSavesLittle() {
        // Two minutes of detour now, none four stops on: now.
        let near = restroom("near", 48.2025, 16.3725)
        let later = restroom("later", 48.2175, 16.37)
        let choice = RestroomPicker.choose(
            anchors: anchors, candidates: [near, later], doorMinutes: 4, firstIsStop: false,
            minutes: crow(anchors, [near, later]))
        #expect(choice?.restroom == near)
        #expect(choice?.gap == 0)
    }

    @Test func aLongWalkCountsAsDetour() {
        let kerb = restroom("kerb", 48.2025, 16.371, walk: 10)
        let park = restroom("park", 48.2025, 16.37, walk: 240)
        let choice = RestroomPicker.choose(
            anchors: anchors, candidates: [park, kerb], doorMinutes: 4, firstIsStop: false,
            minutes: crow(anchors, [park, kerb]))
        #expect(choice?.restroom == kerb)
    }

    @Test func aLoneStopIsThereAndBack() {
        let only = [anchors[0]]
        let r = restroom("r", 48.2025, 16.37)
        let choice = RestroomPicker.choose(
            anchors: only, candidates: [r], doorMinutes: 4, firstIsStop: true,
            minutes: crow(only, [r]))
        #expect(choice?.gap == 0)
        #expect((choice?.detourMinutes ?? 0) > 1)
    }

    @Test func skipsACandidateWithNoRoadToIt() {
        let r = restroom("island", 48.2025, 16.37)
        let choice = RestroomPicker.choose(
            anchors: anchors, candidates: [r], doorMinutes: 4, firstIsStop: false
        ) { i, j in max(i, j) == 5 ? nil : 1 }
        #expect(choice == nil)
    }

    @Test func shortlistIsSmallAndLeavesOutParkToilets() {
        let list = RestroomPicker.shortlist(anchors: anchors, restrooms: Restroom.all)
        #expect(!list.isEmpty)
        #expect(list.count <= RestroomPicker.perGap * (anchors.count - 1))
        #expect(list.allSatisfy { $0.walk <= RestroomPicker.maxWalk })
    }
}
