import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// Where the car sends the driver when the phone is plugged in.
///
/// The intent's own `perform` cannot be reached from a test, so the part that
/// can be wrong in a way that costs a morning is pulled out into
/// `CarPlayNavigation.destination` and pinned down here: the wrong tour, or a
/// door already answered for, is a driver sent back across Vienna.
@MainActor
struct CarPlayNavigationTests {

    private func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @discardableResult
    private func tour(
        _ name: String, in context: ModelContext, status: RouteStatus = .active,
        createdAt: Date = Date(), kunden: [String] = ["Erste", "Zweite"]
    ) throws -> Route {
        let route = try RouteStore.createRoute(name: name, in: context)
        route.status = status
        route.createdAt = createdAt
        for (i, kunde) in kunden.enumerated() {
            let stop = Stop(
                kind: .customer, kunde: kunde, strasse: "Gentzgasse \(i + 1)", plz: "1180",
                lat: 48.2301, lon: 16.3201, orderIndex: 10 + i)
            stop.route = route
            context.insert(stop)
        }
        try context.save()
        return route
    }

    /// A suite of its own per test. The switch lives in `UserDefaults`, which
    /// is process-wide, and these run in parallel alongside the backup tests
    /// that capture and restore the very same key.
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    /// Off until somebody turns it on. A feature that opens a navigation app on
    /// its own does not get to be on by default.
    @Test func theSwitchStartsOff() {
        #expect(CarPlayNavigation.isEnabled(in: defaults()) == false)
    }

    @Test func theSwitchRemembersWhatItWasSetTo() {
        let store = defaults()
        store.set(true, forKey: CarPlayNavigation.enabledKey)
        #expect(CarPlayNavigation.isEnabled(in: store))
        store.set(false, forKey: CarPlayNavigation.enabledKey)
        #expect(CarPlayNavigation.isEnabled(in: store) == false)
    }

    @Test func itNavigatesToTheFirstOpenDoor() throws {
        let context = try context()
        try tour("VM4", in: context)

        let (stop, url) = try CarPlayNavigation.destination(in: context)
        #expect(stop.kunde == "Erste")
        #expect(url.absoluteString.contains("Gentzgasse"))
    }

    /// The door just delivered is behind the van, and this runs every time the
    /// engine starts — so a settled stop is never the destination.
    @Test func aDoorAlreadyAnsweredForIsNotDrivenToAgain() throws {
        let context = try context()
        let route = try tour("VM4", in: context)
        try RouteStore.record(.delivered, for: route.customerStops[0], in: context)

        #expect(try CarPlayNavigation.destination(in: context).stop.kunde == "Zweite")
    }

    /// Not home is an answer too: the van is not going back past that door.
    @Test func aDoorNobodyAnsweredIsStillSettled() throws {
        let context = try context()
        let route = try tour("VM4", in: context)
        try RouteStore.record(.notHome, for: route.customerStops[0], in: context)

        #expect(try CarPlayNavigation.destination(in: context).stop.kunde == "Zweite")
    }

    /// The same tour every other screen falls back to — the newest active one,
    /// not yesterday's, which is still sitting in the list.
    @Test func theNewestActiveTourWins() throws {
        let context = try context()
        try tour(
            "Gestern", in: context, createdAt: Date(timeIntervalSinceNow: -86_400),
            kunden: ["Alte Tour"])
        try tour("Heute", in: context, kunden: ["Neue Tour"])

        #expect(try CarPlayNavigation.destination(in: context).stop.kunde == "Neue Tour")
    }

    @Test func aFinishedTourIsNotDrivenAgain() throws {
        let context = try context()
        try tour("VM4", in: context, status: .completed)

        #expect(throws: CarPlayNavigation.Failure.noTour) {
            try CarPlayNavigation.destination(in: context)
        }
    }

    @Test func withNoTourAtAllItSaysSo() throws {
        let context = try context()

        #expect(throws: CarPlayNavigation.Failure.noTour) {
            try CarPlayNavigation.destination(in: context)
        }
    }

    @Test func aTourWithEveryDoorDoneSaysSo() throws {
        let context = try context()
        let route = try tour("VM4", in: context)
        for stop in route.customerStops {
            try RouteStore.record(.delivered, for: stop, in: context)
        }

        #expect(throws: CarPlayNavigation.Failure.allDone) {
            try CarPlayNavigation.destination(in: context)
        }
    }

    /// A tour with no customers on it yet is the same answer as one with none
    /// left: there is no door to drive to.
    @Test func aTourWithNoStopsSaysSo() throws {
        let context = try context()
        try tour("VM4", in: context, kunden: [])

        #expect(throws: CarPlayNavigation.Failure.allDone) {
            try CarPlayNavigation.destination(in: context)
        }
    }

    /// Whichever maps app the driver picked in Mehr — the car does not get its
    /// own setting.
    @Test func itFollowsTheDriversChosenMapsApp() throws {
        let previous = NavigationHandoff.provider
        defer { NavigationHandoff.provider = previous }
        let context = try context()
        try tour("VM4", in: context)

        NavigationHandoff.provider = .waze
        #expect(try CarPlayNavigation.destination(in: context).url.host() == "waze.com")

        NavigationHandoff.provider = .apple
        #expect(try CarPlayNavigation.destination(in: context).url.host() == "maps.apple.com")
    }
}
