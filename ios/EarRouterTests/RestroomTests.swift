import Foundation
import Testing
@testable import EarRouter

/// The public toilets on the map: the list, its hours, and the driver's marks.
struct RestroomTests {
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

    @Test func bundledFileReadsBothSourcesAndIsAllInAustria() {
        #expect(Restroom.all.count { $0.oeklo != true } > 120)
        #expect(Restroom.all.count { $0.oeklo == true } > 250)
        #expect(Restroom.all.allSatisfy { Coordinates.isPlausible(lat: $0.lat, lon: $0.lon) })
        #expect(Restroom.all.allSatisfy { !$0.name.isEmpty })
    }

    @Test func everyToiletHasItsOwnPin() {
        #expect(Restroom.pinsByID.count == Restroom.all.count)
        #expect(Restroom.pins.allSatisfy { $0.key == $0.restroom.key })
    }

    @Test @MainActor func aMarkOutlivesARefreshOfTheListAndCanBeTakenBack() {
        let r = restroom("shut-\(UUID().uuidString)", 48.2, 16.37)
        RestroomMarks.shared.setBad(true, r)
        #expect(RestroomMarks.shared.isBad(r))
        // The same toilet after a refresh corrected its walk and its hours.
        let refreshed = restroom(r.name, 48.2, 16.37, walk: 40, hours: Array(repeating: [0, 600], count: 7))
        #expect(RestroomMarks.shared.isBad(refreshed))
        RestroomMarks.shared.setBad(false, r)
        #expect(!RestroomMarks.shared.isBad(r))
    }

    @Test @MainActor func aNoteIsTrimmedCappedAndRemovedWhenEmptied() {
        let r = restroom("note-\(UUID().uuidString)", 48.2, 16.37)
        #expect(RestroomMarks.shared.note(for: r) == nil)
        RestroomMarks.shared.setNote("  Code 1234 \n", for: r)
        #expect(RestroomMarks.shared.note(for: r) == "Code 1234")
        RestroomMarks.shared.setNote(String(repeating: "x", count: 500), for: r)
        #expect(RestroomMarks.shared.note(for: r)?.count == RestroomMarks.maxNoteLength)
        RestroomMarks.shared.setNote("   ", for: r)
        #expect(RestroomMarks.shared.note(for: r) == nil)
    }

    @Test @MainActor func marksAndNotesSurviveTheBackupFile() throws {
        let marks = RestroomMarks.shared
        let before = marks.backup()
        defer { marks.restore(before, replacing: true) }

        let shut = restroom("shut-\(UUID().uuidString)", 48.2, 16.37)
        let coded = restroom("coded-\(UUID().uuidString)", 48.21, 16.37)
        marks.setBad(true, shut)
        marks.setNote("Code 1234", for: coded)

        var archive = BackupArchive()
        archive.restrooms = marks.backup()
        let read = try BackupArchive.decode(archive.encoded())

        marks.restore([], replacing: true)
        #expect(!marks.isBad(shut) && marks.note(for: coded) == nil)
        marks.restore(read.restrooms, replacing: true)
        #expect(marks.isBad(shut) && !marks.isBad(coded))
        #expect(marks.note(for: coded) == "Code 1234")
    }

    @Test @MainActor func mergingABackupAddsItsMarksAndKeepsTheNotesHere() {
        let marks = RestroomMarks.shared
        let before = marks.backup()
        defer { marks.restore(before, replacing: true) }

        let here = restroom("here-\(UUID().uuidString)", 48.2, 16.37)
        let there = restroom("there-\(UUID().uuidString)", 48.21, 16.37)
        marks.setNote("meine", for: here)
        marks.restore(
            [
                .init(key: here.key, bad: true, note: "aus der Datei"),
                .init(key: there.key, bad: false, note: "neu"),
            ], replacing: false)
        #expect(marks.isBad(here))
        #expect(marks.note(for: here) == "meine")
        #expect(marks.note(for: there) == "neu")
    }

    @Test func aBackupFromBeforeTheToiletsStillReads() throws {
        let old = #"{"format":"ear-router-backup","version":1,"routes":[],"stockwerke":[]}"#
        #expect(try BackupArchive.decode(Data(old.utf8)).restrooms.isEmpty)
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
}
