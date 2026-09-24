import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// A tour used to store one bit per door. These pin down what replaced it: four
/// outcomes, the line between "the meal left the van" and "it came back", and
/// the promise that a stop ticked off by a build that had never heard of any of
/// this still reads as a delivery.
@MainActor
struct DeliveryOutcomeTests {

    private func store() throws -> ModelContext {
        ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func customer(_ name: String = "Fam. Gruber") -> Stop {
        Stop(
            kind: .customer, kunde: name, strasse: "Gentzgasse 129/1", plz: "1180",
            lat: 48.2301, lon: 16.3201)
    }

    /// The whole reason the schema change could be lightweight: a row written
    /// before outcomes existed carries `delivered` and no `outcomeRaw`, and
    /// "delivered" is exactly what that bit meant.
    @Test func aStopTickedOffBeforeOutcomesExistedReadsAsDelivered() {
        let stop = customer()
        stop.delivered = true
        stop.outcomeRaw = nil

        #expect(stop.outcome == .delivered)
        #expect(stop.isSettled)
        #expect(!stop.isOpenDelivery)
    }

    @Test func aStopNobodyHasTouchedIsOpen() {
        let stop = customer()
        #expect(stop.outcome == nil)
        #expect(!stop.isSettled)
        #expect(stop.isOpenDelivery)
        #expect(stop.settledAt == nil)
    }

    /// The three stored facts move together or the app tells two stories about
    /// one door. `record` is the only thing allowed to write them.
    @Test(arguments: DeliveryOutcome.allCases)
    func recordingAnOutcomeWritesAllThreeFactsAtOnce(outcome: DeliveryOutcome) {
        let stop = customer()
        let when = Date(timeIntervalSince1970: 1_757_000_000)

        stop.record(outcome, at: when)

        #expect(stop.outcome == outcome)
        #expect(stop.delivered == outcome.handedOver)
        #expect(stop.settledAt == when)
        #expect(stop.isSettled)
    }

    /// A meal left with a neighbour did leave the van, and every count in the
    /// app that reads `delivered` has to agree.
    @Test func aMealLeftWithANeighbourCountsAsHandedOver() {
        let stop = customer()
        stop.record(.neighbour)
        #expect(stop.delivered)
        #expect(stop.outcome?.handedOver == true)
        #expect(stop.outcome?.needsFollowUp == false)
    }

    /// And a locked door did not — which is the distinction the whole change
    /// exists for.
    @Test func aDoorNobodyOpenedIsSettledButNotDelivered() {
        let stop = customer()
        stop.record(.notHome)
        #expect(!stop.delivered)
        #expect(stop.isSettled)
        #expect(stop.outcome?.needsFollowUp == true)
    }

    /// Exactly one outcome ends the day owing somebody a phone call. An
    /// abbestellt customer was never owed a meal and a neighbour took theirs.
    @Test func onlyAnUnansweredDoorNeedsFollowingUp() {
        let needing = DeliveryOutcome.allCases.filter(\.needsFollowUp)
        #expect(needing == [.notHome])
    }

    /// Re-opening a stop takes the time back with it. A settled-at left behind
    /// would put a door into the day's report that the driver had explicitly
    /// un-ticked.
    @Test func reopeningAStopClearsTheTimeAsWell() {
        let stop = customer()
        stop.record(.delivered)
        stop.record(nil)

        #expect(stop.outcome == nil)
        #expect(!stop.delivered)
        #expect(stop.settledAt == nil)
    }

    /// A raw value this build does not recognise — a store written by a later
    /// version, then opened by this one — must not silently become a delivery.
    @Test func anUnknownStoredOutcomeFallsBackToTheDeliveredBit() {
        let stop = customer()
        stop.outcomeRaw = "teleported"
        stop.delivered = false
        #expect(stop.outcome == nil)

        stop.delivered = true
        #expect(stop.outcome == .delivered)
    }

    /// The plain tick is still the plain tick: on means delivered, off means
    /// not answered for yet — including off a door that was recorded as
    /// something else entirely.
    @Test func thePlainTickStillSetsAndClearsADelivery() throws {
        let context = try store()
        let stop = customer()
        context.insert(stop)

        try RouteStore.setDelivered(stop, true, in: context)
        #expect(stop.outcome == .delivered)

        try RouteStore.setDelivered(stop, false, in: context)
        #expect(stop.outcome == nil)

        try RouteStore.record(.notHome, for: stop, in: context)
        try RouteStore.setDelivered(stop, false, in: context)
        #expect(stop.outcome == nil)
    }

    /// Resetting the tour clears every kind of answer, not only the ticks. It
    /// is the button a driver presses on a list still carrying yesterday.
    @Test func resettingTheTourReopensEveryOutcome() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let delivered = customer("A")
        let missed = customer("B")
        for s in [delivered, missed] {
            s.route = route
            context.insert(s)
        }
        try RouteStore.record(.delivered, for: delivered, in: context)
        try RouteStore.record(.notHome, for: missed, in: context)
        // Two doors, and the Lager ticked along with the first of them.
        #expect(route.settledCount == 3)

        try RouteStore.resetDelivered(route, in: context)

        #expect(route.settledCount == 0)
        #expect(route.deliveredCount == 0)
        #expect(delivered.settledAt == nil)
        #expect(missed.outcome == nil)
    }

    /// A tour where one customer was out is a tour that has been driven. The
    /// screen used to hold "Noch 1 Stopp" over a van already back at the depot,
    /// until somebody ticked a meal as delivered that never was.
    @Test func aTourIsCompleteOnceEveryDoorIsAnsweredFor() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let a = customer("A"), b = customer("B")
        for s in [a, b] {
            s.route = route
            context.insert(s)
        }

        try RouteStore.record(.delivered, for: a, in: context)
        #expect(!route.isComplete)

        try RouteStore.record(.notHome, for: b, in: context)
        #expect(route.deliveredCount == 1)

        // Lager and Ziel are stops too: the tour is not done until both are
        // ticked off.
        #expect(!route.isComplete)
        for fixed in route.stops where fixed.isCheckpoint {
            try RouteStore.setDelivered(fixed, true, in: context)
        }
        #expect(route.isComplete)
        #expect(route.settledCount == 4)
    }

    /// And the next-stop card moves past it. A door already answered for is not
    /// somewhere the driver is standing.
    @Test func theNextOpenStopSkipsADoorAlreadyAnsweredFor() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let a = customer("A"), b = customer("B")
        a.orderIndex = 10
        b.orderIndex = 11
        for s in [a, b] {
            s.route = route
            context.insert(s)
        }

        #expect(route.nextOpenStop?.kunde == "Lager")
        try RouteStore.setDelivered(
            try #require(route.stops.first { $0.kind == .via }), true, in: context)
        #expect(route.nextOpenStop?.kunde == "A")
        try RouteStore.record(.notHome, for: a, in: context)
        #expect(route.nextOpenStop?.kunde == "B")
        try RouteStore.record(.delivered, for: b, in: context)
        #expect(route.nextOpenStop?.kunde == "Ziel")
    }

    /// A door answered for means the van has loaded. A Lager nobody ticked used
    /// to stay "next" on Jetzt, the lock screen and in the car all day.
    @Test func answeringTheFirstDoorTicksAForgottenLager() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let a = customer("A"), b = customer("B")
        a.orderIndex = 10
        b.orderIndex = 11
        for s in [a, b] {
            s.route = route
            context.insert(s)
        }

        try RouteStore.record(.notHome, for: a, in: context)
        let lager = try #require(route.stops.first { $0.kind == .via })
        #expect(lager.isSettled)
        #expect(route.nextOpenStop?.kunde == "B")
    }

    /// Abbestellt is ticked in the yard, before anything is loaded.
    @Test func anAbbestelltTickLeavesTheLagerOpen() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let a = customer("A")
        a.orderIndex = 10
        a.route = route
        context.insert(a)

        try RouteStore.record(.cancelled, for: a, in: context)
        #expect(route.nextOpenStop?.kunde == "Lager")
    }

    /// A tour that skips the Lager has nothing to tick.
    @Test func anExcludedLagerStaysAsItWas() throws {
        let context = try store()
        let route = try RouteStore.createRoute(name: "Test", in: context)
        let lager = try #require(route.stops.first { $0.kind == .via })
        lager.excluded = true
        let a = customer("A")
        a.route = route
        context.insert(a)

        try RouteStore.record(.delivered, for: a, in: context)
        #expect(!lager.isSettled)
    }
}
