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

    @Test func theSharedTextListsEachPersonsDoorsAndTheRest() {
        var split = state(4, people: 2)
        split.claim([0, 1], for: 0)
        split.claim([2], for: 1)
        let text = split.shareText()
        #expect(text.hasPrefix("VM 4 DO Vormittag – "))
        #expect(text.contains("Person 1 · 2 Stopps\n1. Kunde 0 – Gentzgasse 1, 1180\n2. Kunde 1 – Gentzgasse 2, 1180"))
        #expect(text.contains("Person 2 · 1 Stopp\n1. Kunde 2 – Gentzgasse 3, 1180"))
        #expect(text.contains("Nicht zugeteilt · 1\n– Kunde 3 – Gentzgasse 4, 1180"))
        #expect(!text.contains("{"))
    }

    @Test func aSingleShareHoldsOnlyThatPerson() {
        var split = state(2, people: 2)
        split.claim([0, 1], for: 1)
        let text = split.shareText(for: 1)
        #expect(text.contains("Person 2 · 2 Stopps"))
        #expect(!text.contains("Person 1"))
        #expect(!text.contains("Nicht zugeteilt"))
    }

    @Test func theServerPartCarriesTheDayAndTheGlobaleInfos() throws {
        var split = SplitState(
            tourName: "VM 4 DO Vormittag",
            date: Date(timeIntervalSince1970: 1_757_980_800),  // 16.09.2025, 02:00 in Vienna
            people: 2,
            stops: (0..<3).map {
                SplitStop(
                    id: $0, name: "Kunde \($0)", address: "Gentzgasse \($0 + 1)", plz: "1180",
                    coordinate: nil)
            })
        split.claim([0, 1], for: 1)
        let data = try split.serverPart(
            for: 1, infos: [1: CustomerInfo(stockwerk: "3", notiz: "Hund")])
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("{\n\"tour\""))
        let part = try JSONDecoder().decode(SplitServer.Part.self, from: data)
        #expect(part.tour == "VM 4 DO Vormittag")
        #expect(part.date == "2025-09-16")
        #expect(part.persons.count == 1)
        #expect(part.persons[0].person == 2)
        #expect(part.stops.map(\.name) == ["Kunde 0", "Kunde 1"])
        #expect(part.stops[0].stockwerk == nil && part.stops[0].notiz == nil)
        #expect(part.stops[1].stockwerk == "3")
        #expect(part.stops[1].notiz == "Hund")
        // Without its Globale Infos, a stop carries only name, address and PLZ.
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let persons = try #require(raw["persons"] as? [[String: Any]])
        let stops = try #require(persons[0]["stops"] as? [[String: String]])
        #expect(Set(stops[0].keys) == ["name", "address", "plz"])
    }

    /// Paket, phone and the day's note go along, or the phone that loads the
    /// part has an empty Ladeliste and nobody to call — and come back out as
    /// the import entries.
    @Test func theServerPartCarriesTodaysDeliveryBothWays() throws {
        var split = SplitState(
            tourName: "VM 4", people: 2,
            stops: [
                SplitStop(id: 1, name: "Fam. Gruber", address: "Gentzgasse 129/1", plz: "1180", coordinate: nil),
                SplitStop(
                    id: -1, name: "Herr Maier", address: "Hauptstraße 5", plz: "1210", coordinate: nil,
                    typed: CustomerJSON(
                        kunde: "Herr Maier", strasse: "Hauptstraße 5", plz: "1210",
                        paket: "Nachlieferung", notiz: "Hintertür", telefon: "0660 1"))
            ])
        split.claim([1, -1], for: 0)
        let data = try split.serverPart(
            for: 0,
            entries: [1: CustomerJSON(
                kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1", plz: "1180",
                paket: "2x Menü A", notiz: "Bitte läuten", telefon: "+43 660 2", paketCount: 2)],
            infos: [1: CustomerInfo(stockwerk: "2", notiz: "Hund")])
        let part = try JSONDecoder().decode(SplitServer.Part.self, from: data)
        let gruber = try #require(part.entries.first)
        #expect(gruber.paket == "2x Menü A" && gruber.paketCount == 2)
        #expect(gruber.telefon == "+43 660 2")
        #expect(gruber.notiz == "Bitte läuten")  // the day's note, not the Globale one
        #expect(part.stops[0].notiz == "Hund")
        // A typed-in stop with no fetched entry sends what it was typed with.
        let maier = part.entries[1]
        #expect(maier.paket == "Nachlieferung" && maier.notiz == "Hintertür" && maier.telefon == "0660 1")
    }

    /// A loaded part finds its portal deliveries: by name and address, then
    /// by name in the postcode for an address the sender corrected; each
    /// delivery once, and a typed-in stop matches nothing.
    @Test func aLoadedPartFindsItsPortalDeliveries() {
        let stops = [
            SplitServer.Stop(name: "Fam. Gruber", address: "Gentzgasse 129/1", plz: "1180"),
            SplitServer.Stop(name: "Fam. Gruber", address: "Gentzgasse 129/1", plz: "1180"),
            SplitServer.Stop(name: "Herr Maier", address: "Hauptstr. 7", plz: "1210"),
            SplitServer.Stop(name: "Nachlieferung Huber", address: "Brünner Straße 3", plz: "1210"),
        ]
        let candidates = [
            SplitServer.Candidate(id: 10, name: "Fam Gruber", address: "Gentzgasse 129 / 1", plz: "1180"),
            SplitServer.Candidate(id: 11, name: "Fam. Gruber", address: "Gentzgasse 129/1", plz: "1180"),
            SplitServer.Candidate(id: 20, name: "Herr Maier", address: "Hauptstraße 5", plz: "1210"),
            SplitServer.Candidate(id: 30, name: "Frau Novak", address: "Brünner Straße 3", plz: "1210"),
        ]
        #expect(SplitServer.match(stops, to: candidates) == [10, 11, 20, nil])
    }

    /// What the review says about a loaded part, for each way the portal
    /// can fail to help.
    @Test func thePortalResultSaysWhatCameFromTheSender() {
        let entries = [CustomerJSON(kunde: "A", strasse: "Gentzgasse 1", plz: "1180", paket: nil, notiz: nil)]
        func result(_ outcome: SplitServer.PortalResult.Outcome) -> SplitServer.PortalResult {
            SplitServer.PortalResult(entries: entries, outcome: outcome)
        }
        #expect(result(.noLogin).notice(tour: "VM 4", day: nil)?.contains("kein Zusteller-Portal-Login") == true)
        #expect(result(.unreachable("Passwort falsch")).notice(tour: "VM 4", day: nil)?.contains("Passwort falsch") == true)
        #expect(result(.tourNotFound).notice(tour: "VM 4", day: nil)?.contains("„VM 4“ gibt es") == true)
        #expect(result(.noDeliveries).notice(tour: "VM 4", day: "2026-11-06")?.contains("am 06.11.2026") == true)
        // Said once at the top, not on every row.
        #expect(result(.noLogin).hint(at: 0) == nil)

        var checked = result(.checked)
        #expect(checked.notice(tour: "VM 4", day: nil) == nil)
        checked.missing = [0]
        #expect(checked.notice(tour: "VM 4", day: nil)?.hasPrefix("1 Kunde ist") == true)
        #expect(checked.hint(at: 0)?.contains("Nicht im Zusteller-Portal") == true)
        #expect(checked.hint(at: 1) == nil)
    }

    /// Without a portal login every portal stop is a gap; a typed-in one never.
    @Test func entriesWithoutDetailsAreMarkedAsGaps() async {
        var split = SplitState(
            tourName: "VM 4", people: 1,
            stops: [
                SplitStop(id: 1, name: "A", address: "Gentzgasse 1", plz: "1180", coordinate: nil),
                SplitStop(
                    id: -1, name: "B", address: "Gentzgasse 2", plz: "1180", coordinate: nil,
                    typed: CustomerJSON(kunde: "B", strasse: "Gentzgasse 2", plz: "1180", paket: "x", notiz: nil)),
            ])
        split.claim([1, -1], for: 0)
        let (entries, gaps) = await split.entriesAndGaps(for: 0)
        #expect(entries.count == 2)
        #expect(gaps == [0])
    }

    @Test func aLoadedPartBecomesEntriesAndKeepsItsInfosApart() {
        let part = SplitServer.Part(
            tour: "VM 4", date: "2026-11-06",
            persons: [SplitServer.Person(person: 2, stops: [
                SplitServer.Stop(name: "Fam. Gruber", address: "Gentzgasse 129/1", plz: "1180", stockwerk: "2", notiz: "Hund"),
                SplitServer.Stop(name: "Herr Maier", address: "Hauptstraße 5", plz: "1210"),
            ])])
        #expect(part.entries.map(\.kunde) == ["Fam. Gruber", "Herr Maier"])
        #expect(part.entries.allSatisfy { $0.notiz == nil && $0.paket == nil })
        let key = StockwerkKey.make(kunde: "Fam Gruber", strasse: "Gentzgasse 129 / 1", plz: "1180")
        #expect(part.infos.count == 1)
        #expect(part.infos[key ?? ""]?.stockwerk == "2")
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
