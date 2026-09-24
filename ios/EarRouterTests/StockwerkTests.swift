import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// Which floor a customer lives on, and — just as important — when the app
/// stops asking.
///
/// The floor is the one thing here that is not on any list the office sends: it
/// is learned once, in a stairwell, and if it is filed under the wrong key or
/// asked for twice, the feature is worse than not having it.
@MainActor
struct StockwerkTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func customer(
        _ kunde: String = "Fam. Gruber", _ strasse: String = "Gentzgasse 129/1",
        _ plz: String = "1180"
    ) -> Stop {
        Stop(kind: .customer, kunde: kunde, strasse: strasse, plz: plz,
             lat: 48.23, lon: 16.32)
    }

    // MARK: - StockwerkKey

    /// The case this key exists for: two households behind one front door.
    /// One ring of the bell, two meals carried up — to two different floors.
    @Test func twoCustomersAtOneAddressAreTwoEntries() {
        #expect(
            StockwerkKey.make(kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1", plz: "1180")
                != StockwerkKey.make(
                    kunde: "Fam. Novak", strasse: "Gentzgasse 129/1", plz: "1180"))
    }

    @Test func oneCustomerSurvivesEverySpellingOfTheirNameAndAddress() {
        let a = StockwerkKey.make(kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1", plz: "1180")
        let b = StockwerkKey.make(kunde: "Fam Gruber", strasse: "Gentzgasse 129 / 1", plz: "1180")
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func theSameStreetInTwoDistrictsIsTwoEntries() {
        // Vienna has a Hauptstraße in several districts, and a floor from the
        // wrong one sends the driver up the wrong stairs.
        #expect(
            StockwerkKey.make(kunde: "Fam. Gruber", strasse: "Hauptstraße 12", plz: "1030")
                != StockwerkKey.make(
                    kunde: "Fam. Gruber", strasse: "Hauptstraße 12", plz: "1140"))
    }

    @Test func oneCustomerAtTwoStiegenIsTwoEntries() {
        // Two stairwells, two front doors, two floor numberings.
        #expect(
            StockwerkKey.make(kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1", plz: "1180")
                != StockwerkKey.make(
                    kunde: "Fam. Gruber", strasse: "Gentzgasse 129/2", plz: "1180"))
    }

    /// A list that carries no names still works — the address alone is the key
    /// then, rather than nothing at all.
    @Test func aStopWithNoNameStillHasAKey() {
        #expect(StockwerkKey.make(kunde: nil, strasse: "Gentzgasse 129", plz: "1180") != nil)
    }

    @Test func anAddressWithNoStreetAtAllHasNoKey() {
        #expect(StockwerkKey.make(kunde: "Fam. Gruber", strasse: nil, plz: "1180") == nil)
        #expect(StockwerkKey.make(kunde: "Fam. Gruber", strasse: "   ", plz: "1180") == nil)
    }

    // MARK: - Asking

    @Test func asksAboutACustomerItHasNeverBeenToldAbout() throws {
        let context = try makeContext()
        let stop = customer()
        context.insert(stop)
        #expect(StockwerkStore.shouldAsk(stop, in: context))
    }

    @Test func neverAsksAgainOnceTheFloorIsKnown() throws {
        let context = try makeContext()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: context)
        #expect(!StockwerkStore.shouldAsk(stop, in: context))
    }

    @Test func neverAsksAgainWhenTheDriverSaidNotTo() throws {
        let context = try makeContext()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(stockwerk: nil, dontAsk: true, for: stop, in: context)
        #expect(!StockwerkStore.shouldAsk(stop, in: context))
    }

    @Test func answeringOneCustomerDoesNotAnswerTheStopNextToIt() throws {
        let context = try makeContext()
        let answered = customer("Fam. Gruber", "Gentzgasse 129/1")
        let other = customer("Fam. Novak", "Währinger Straße 4")
        context.insert(answered)
        context.insert(other)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: answered, in: context)
        #expect(StockwerkStore.shouldAsk(other, in: context))
    }

    /// The neighbour across the landing is still asked about. This is the one
    /// that a key built from the address alone got wrong: the second household
    /// at one door inherited the first one's floor and was never asked.
    @Test func theOtherHouseholdAtTheSameDoorIsStillAsked() throws {
        let context = try makeContext()
        let first = customer("Fam. Gruber", "Gentzgasse 129/1")
        let neighbour = customer("Fam. Novak", "Gentzgasse 129/1")
        context.insert(first)
        context.insert(neighbour)

        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: first, in: context)

        #expect(StockwerkStore.shouldAsk(neighbour, in: context))
        try StockwerkStore.save(stockwerk: "5", dontAsk: false, for: neighbour, in: context)

        let floors = try StockwerkStore.all(in: context).floors(for: [first, neighbour])
        #expect(floors[first.id] == "3")
        #expect(floors[neighbour.id] == "5")
        #expect(try StockwerkStore.all(in: context).count == 2)
    }

    /// The whole point of keying by door rather than by stop: tomorrow's list
    /// is a different `Stop` row for the same household.
    @Test func tomorrowsRowForTheSameHouseholdIsNotAskedAgain() throws {
        let context = try makeContext()
        let today = customer()
        context.insert(today)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: today, in: context)
        context.delete(today)
        try context.save()

        let tomorrow = customer("Fam Gruber", "Gentzgasse 129 / 1")
        context.insert(tomorrow)
        #expect(!StockwerkStore.shouldAsk(tomorrow, in: context))
    }

    @Test func neverAsksAboutTheDepotOrTheWarehouse() throws {
        let context = try makeContext()
        let depot = Stop(
            kind: .start, kunde: "Start", strasse: "Petritschgasse 24", plz: "1210",
            lat: 48.2, lon: 16.4)
        context.insert(depot)
        #expect(!StockwerkStore.shouldAsk(depot, in: context))
    }

    // MARK: - Writing

    @Test func keepsExactlyOneRowPerCustomerHoweverOftenItIsAnswered() throws {
        let context = try makeContext()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(stockwerk: "2", dontAsk: false, for: stop, in: context)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: context)
        try StockwerkStore.save(stockwerk: "4", dontAsk: false, for: stop, in: context)

        let all = try StockwerkStore.all(in: context)
        #expect(all.count == 1)
        #expect(all.first?.stockwerk == "4")
    }

    @Test func anAnswerThatSaysNothingLeavesNoRowBehind() throws {
        let context = try makeContext()
        let stop = customer()
        context.insert(stop)

        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: context)
        // Cleared — which is how a floor typed wrong is taken back out.
        try StockwerkStore.save(stockwerk: "   ", dontAsk: false, for: stop, in: context)

        #expect(try StockwerkStore.all(in: context).isEmpty)
        #expect(StockwerkStore.shouldAsk(stop, in: context))
    }

    @Test func storesTheFloorTrimmedOfWhatWasTypedAroundIt() throws {
        let context = try makeContext()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(stockwerk: "  3  ", dontAsk: false, for: stop, in: context)
        #expect(try StockwerkStore.all(in: context).first?.stockwerk == "3")
    }

    // MARK: - Reading a whole list

    @Test func mapsEveryStopOnTheTourToItsOwnFloor() throws {
        let context = try makeContext()
        let a = customer("Fam. Gruber", "Gentzgasse 129/1")
        let b = customer("Fam. Novak", "Währinger Straße 4")
        let c = customer("Fam. Berger", "Hauptstraße 12", "1030")
        for s in [a, b, c] { context.insert(s) }

        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: a, in: context)
        try StockwerkStore.save(stockwerk: "EG", dontAsk: false, for: c, in: context)

        let floors = try StockwerkStore.all(in: context).floors(for: [a, b, c])
        #expect(floors[a.id] == "3")
        #expect(floors[c.id] == "EG")
        // Never answered for — and an absent floor is what draws no badge.
        #expect(floors[b.id] == nil)
    }

    /// A "nicht mehr fragen" row carries no floor, and must not put an empty
    /// badge on the row it belongs to.
    @Test func aCustomerThatIsOnlyMutedShowsNoFloor() throws {
        let context = try makeContext()
        let stop = customer()
        context.insert(stop)
        try StockwerkStore.save(stockwerk: nil, dontAsk: true, for: stop, in: context)

        let floors = try StockwerkStore.all(in: context).floors(for: [stop])
        #expect(floors[stop.id] == nil)
    }

    // MARK: - A corrected name

    /// The key carries the name, so a typo fixed in the editor used to leave
    /// the floor behind under the old spelling and ask for it again.
    @Test func aCorrectedNameKeepsItsGlobaleInfos() async throws {
        let context = try makeContext()
        let stop = customer("Gruber Maria")
        context.insert(stop)
        try StockwerkStore.save(
            CustomerInfo(stockwerk: "3", notiz: "Hört schlecht"), for: stop, in: context)

        try await RouteStore.updateStop(
            stop, kunde: "Maria Gruber", strasse: "Gentzgasse 129/1", plz: "1180",
            paket: nil, notiz: nil, reroute: false, in: context)

        let note = try StockwerkStore.note(for: stop, in: context)
        #expect(note?.stockwerk == "3")
        #expect(note?.notiz == "Hört schlecht")
        #expect(note?.kunde == "Maria Gruber")
        #expect(try StockwerkStore.all(in: context).count == 1)
        #expect(!StockwerkStore.shouldAsk(stop, in: context))
    }

    /// Never over the top of what the new name already has.
    @Test func aCorrectedNameDoesNotOverwriteAnEntryItAlreadyHas() async throws {
        let context = try makeContext()
        let stop = customer("Gruber Maria")
        let other = customer("Maria Gruber")
        context.insert(stop)
        context.insert(other)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: context)
        try StockwerkStore.save(stockwerk: "EG", dontAsk: false, for: other, in: context)

        try await RouteStore.updateStop(
            stop, kunde: "Maria Gruber", strasse: "Gentzgasse 129/1", plz: "1180",
            paket: nil, notiz: nil, reroute: false, in: context)

        #expect(try StockwerkStore.note(for: stop, in: context)?.stockwerk == "EG")
    }

    /// The same name correction arriving in a re-pasted list.
    @Test func aListThatRenamesACustomerCarriesTheirGlobaleInfos() async throws {
        let context = try makeContext()
        let route = Route(name: "Tour")
        context.insert(route)
        let stop = customer("Gruber Maria")
        stop.route = route
        context.insert(stop)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: context)

        _ = try await RouteStore.importJSON(
            [CustomerJSON(
                kunde: "Maria Gruber", strasse: "Gentzgasse 129/1", plz: "1180",
                paket: nil, notiz: nil)],
            into: route, in: context, reroute: false)

        #expect(stop.kunde == "Maria Gruber")
        #expect(try StockwerkStore.note(for: stop, in: context)?.stockwerk == "3")
    }
}
