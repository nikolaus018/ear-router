import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// When the van gets to each remaining door.
///
/// Driving time is the only thing OSRM knows and it is about half of this
/// round; the rest is parking, a staircase and two minutes with somebody who
/// has not spoken to anybody since yesterday. So the estimate is driving plus a
/// per-door figure, counted from the last tick, and that figure is measured
/// off the day's own timestamps and the tours before it rather than assumed.
/// These pin down each of those, and the refusals — the cases where saying
/// nothing beats saying a number.
@MainActor
struct ArrivalEstimateTests {

    private func route(_ stops: [Stop], finished: Bool = false) throws -> Route {
        let context = ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let route = Route(name: "Test")
        if finished { route.status = .completed }
        context.insert(route)
        for (i, s) in stops.enumerated() {
            s.orderIndex = i
            s.route = route
            context.insert(s)
        }
        try context.save()
        return route
    }

    /// Every stop drives ten minutes to the next one, so the arithmetic in
    /// these tests is legible.
    private func customer(_ name: String, minutes: Double? = 10) -> Stop {
        let s = Stop(
            kind: .customer, kunde: name, strasse: "Gentzgasse \(name)", plz: "1180",
            lat: 48.20, lon: 16.32)
        s.nextLegKm = 1
        s.nextLegMin = minutes
        return s
    }

    private func fixed(_ kind: StopKind, minutes: Double? = 10) -> Stop {
        let s = Stop(
            kind: kind, kunde: "Fix", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz, lat: Coordinates.start.lat, lon: Coordinates.start.lon)
        s.nextLegKm = minutes == nil ? nil : 1
        s.nextLegMin = minutes
        return s
    }

    /// With nothing learned from other tours, so every figure here is the
    /// test's own.
    private func snap(_ route: Route, history: PaceHistory = .none) -> RouteSnapshot {
        RouteSnapshot(route, history: history)
    }

    private let noon = Date(timeIntervalSince1970: 1_757_000_000)
    private func at(_ minutes: Double) -> Date { noon.addingTimeInterval(minutes * 60) }

    private func minutesAfterNoon(_ date: Date?) -> Double? {
        date.map { ($0.timeIntervalSince(noon) / 60 * 1000).rounded() / 1000 }
    }

    private let door = RouteSnapshot.Pace.assumedMinutes

    // MARK: - Arrival times

    /// The first open door is however far the van still has to drive, plus
    /// nothing — there are no other doors in between.
    @Test func theNextDoorIsPureDrivingTime() throws {
        let a = customer("A"), b = customer("B")
        let snapshot = snap(try route([a, b]))
        #expect(minutesAfterNoon(snapshot.eta(for: a, from: noon)) == 0)
    }

    /// A point the van has already passed gets none. The depot carries no
    /// outcome and so is never "settled" — left to the clamp alone it sat at
    /// the top of the list all day promising an arrival of exactly now.
    @Test func aPointTheVanHasAlreadyPassedIsGivenNoArrivalTime() throws {
        let depot = fixed(.start)
        let a = customer("A"), b = customer("B")
        let route = try route([depot, a, b])

        #expect(snap(route).eta(for: depot, from: noon) == nil)
        a.record(.delivered, at: noon)
        #expect(snap(route).eta(for: depot, from: noon) == nil)
        #expect(snap(route).eta(for: b, from: noon) != nil)
    }

    // MARK: - A planned departure

    /// The evening before: with a departure set, every estimate is counted
    /// from it instead of from the moment the driver happens to be looking,
    /// and the tour is as long as it always was.
    @Test func aPlannedDepartureIsWhereTheEstimateStarts() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        let plain = snap(route)
        let planned = RouteSnapshot(route, history: .none, plannedStart: .some(at(600)))

        #expect(planned.pendingStart(from: noon) == at(600))
        #expect(minutesAfterNoon(planned.eta(for: a, from: noon)) == 600)
        #expect(minutesAfterNoon(planned.eta(for: c, from: noon)) == 600 + 20 + 2 * door)
        #expect(
            planned.etaFinish(from: noon)
                == plain.etaFinish(from: noon)?.addingTimeInterval(600 * 60))
        #expect(planned.plannedDuration(from: noon) == plain.plannedDuration(from: noon))
        #expect(planned.plannedDuration(from: noon) == 30 + 3 * door)
    }

    /// A departure that has passed, or a tour already under way, is counted
    /// the way it always was: the van is where the clock or the ticks say.
    /// An abbestellt customer is not a tour under way — the office rings the
    /// evening before.
    @Test func aPlannedDepartureStopsCountingOnceItIsBehind() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])

        let late = RouteSnapshot(route, history: .none, plannedStart: .some(at(-30)))
        #expect(late.pendingStart(from: noon) == nil)
        #expect(late.etaFinish(from: noon) == snap(route).etaFinish(from: noon))

        c.record(.cancelled, at: noon)
        let cancelled = RouteSnapshot(route, history: .none, plannedStart: .some(at(600)))
        #expect(cancelled.pendingStart(from: noon) == at(600))

        a.record(.delivered, at: noon)
        let started = RouteSnapshot(route, history: .none, plannedStart: .some(at(600)))
        #expect(started.pendingStart(from: noon) == nil)
        #expect(started.etaFinish(from: noon) == snap(route).etaFinish(from: noon))
    }

    /// The picker opens on the next time the clock shows the hour asked for:
    /// later today if that is still ahead, tomorrow otherwise.
    @Test func theSuggestedDepartureIsTheNextSuchTimeOfDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 21))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 6))!
        let wanted = calendar.date(
            from: DateComponents(year: 2026, month: 10, day: 13, hour: 7, minute: 30))!

        #expect(PlannedStart.suggestion(after: evening, clockMinutes: 450, calendar: calendar) == wanted)
        #expect(PlannedStart.suggestion(after: morning, clockMinutes: 450, calendar: calendar) == wanted)
    }

    /// And every door after it pays for the ones in front: the drive, plus
    /// the assumed minutes at each door still to be answered.
    @Test func eachFurtherDoorPaysForTheStopsInFrontOfIt() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let snapshot = snap(try route([a, b, c]))

        #expect(snapshot.pace == .assumed)
        #expect(minutesAfterNoon(snapshot.eta(for: b, from: noon)) == 10 + door)
        #expect(minutesAfterNoon(snapshot.eta(for: c, from: noon)) == 20 + 2 * door)
    }

    /// A door already answered for has no arrival time.
    @Test func aSettledStopIsGivenNoArrivalTime() throws {
        let a = customer("A"), b = customer("B")
        let route = try route([a, b])
        a.record(.notHome, at: noon)
        #expect(snap(route).eta(for: a, from: noon) == nil)
    }

    /// A route nobody has optimized has a zero for every leg. Estimating from
    /// that promises all thirty customers their meal at the same minute.
    @Test func aRouteWithNoLegsIsGivenNoArrivalTimesAtAll() throws {
        let a = customer("A", minutes: nil), b = customer("B", minutes: nil)
        a.nextLegKm = nil
        b.nextLegKm = nil
        let snapshot = snap(try route([a, b]))

        #expect(snapshot.eta(for: a, from: noon) == nil)
        #expect(snapshot.eta(for: b, from: noon) == nil)
        #expect(snapshot.etaFinish(from: noon) == nil)
    }

    // MARK: - Counted from the last tick

    /// Half way along a ten-minute drive the next door is five minutes away,
    /// not ten: the estimates stand still between two ticks instead of
    /// sliding back a minute a minute.
    @Test func timeSinceTheLastTickIsTimeAlreadyOnTheWay() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)
        let snapshot = snap(route)

        for now in [0.0, 4, 9] {
            #expect(minutesAfterNoon(snapshot.eta(for: b, from: at(now))) == 10)
            #expect(minutesAfterNoon(snapshot.eta(for: c, from: at(now))) == 20 + door)
        }
    }

    /// Later than the plan, the driver is taken to be arriving now — never in
    /// the past — and the doors behind move with it.
    @Test func aLateDriverIsArrivingNow() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)
        let snapshot = snap(route)

        // At B's door, inside the time a door takes: C has not moved.
        #expect(minutesAfterNoon(snapshot.eta(for: b, from: at(12))) == 12)
        #expect(minutesAfterNoon(snapshot.eta(for: c, from: at(12))) == 20 + door)
        // Half an hour behind: B now, a minute to tick it, then the drive.
        #expect(minutesAfterNoon(snapshot.eta(for: b, from: at(40))) == 40)
        #expect(minutesAfterNoon(snapshot.eta(for: c, from: at(40))) == 51)
    }

    /// Ticked against the driving order, the last tick is not where the van
    /// is — so nothing is taken off the drive for it.
    @Test func anOutOfOrderTickIsNoPosition() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)
        c.record(.delivered, at: at(3))

        #expect(minutesAfterNoon(snap(route).eta(for: b, from: at(8))) == 18)
    }

    /// Nor a tick from hours ago: a tour picked up again after a long pause
    /// starts counting from now.
    @Test func aTickFromHoursAgoIsNoPosition() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)

        #expect(minutesAfterNoon(snap(route).eta(for: b, from: at(200))) == 210)
        #expect(minutesAfterNoon(snap(route).eta(for: c, from: at(200))) == 220 + door)
    }

    // MARK: - Doors that are not a whole door

    /// A second household at the door the van is already standing at costs
    /// part of a door: no parking, no second walk to the Haustür.
    @Test func aSharedDoorCostsLessThanADoorOfItsOwn() throws {
        let a = customer("A", minutes: 0), b = customer("B"), c = customer("C")
        let snapshot = snap(try route([a, b, c]))

        #expect(minutesAfterNoon(snapshot.eta(for: b, from: noon)) == door)
        #expect(minutesAfterNoon(snapshot.eta(for: c, from: noon))
            == ((door + RouteSnapshot.Pace.sharedDoor * door + 10) * 1000).rounded() / 1000)
    }

    // MARK: - The Lager

    /// Loading takes time too, and until the first door is answered for it is
    /// still ahead — whether the Lager is ticked yet or not.
    @Test func loadingAtTheLagerIsCountedUntilTheFirstDoor() throws {
        let depot = fixed(.start), lager = fixed(.via)
        let a = customer("A"), b = customer("B")
        let route = try route([depot, lager, a, b])
        let loading = RouteSnapshot.Pace.lagerMinutes

        #expect(minutesAfterNoon(snap(route).eta(for: lager, from: noon)) == 10)
        #expect(minutesAfterNoon(snap(route).eta(for: a, from: noon)) == 20 + loading)

        // Ticked on arriving there: the loading and the drive follow the tick.
        lager.record(.delivered, at: noon)
        #expect(minutesAfterNoon(snap(route).eta(for: a, from: at(5))) == loading + 10)

        // What this phone measured for it outranks the assumption.
        let learned = PaceHistory(doorMinutes: nil, lagerMinutes: 25)
        #expect(minutesAfterNoon(snap(route, history: learned).eta(for: a, from: at(5))) == 35)

        // Once a door is answered for, the van has loaded.
        a.record(.delivered, at: at(30))
        #expect(minutesAfterNoon(snap(route).eta(for: b, from: at(30))) == 40)
    }

    // MARK: - Pace

    /// Before the first tick the figure is the assumption — or what the tours
    /// before this one took, where the phone has driven any.
    @Test func withoutTicksThePaceIsTheStartingFigure() throws {
        let route = try route([customer("A"), customer("B")])

        #expect(snap(route).pace == .assumed)
        let learned = snap(route, history: PaceHistory(doorMinutes: 5.5, lagerMinutes: nil)).pace
        #expect(learned.minutesPerStop == 5.5 && learned.learned && !learned.measured)
    }

    /// Each pair of doors ticked one after the other is one measurement: the
    /// time between the ticks, less the drive. Today's are blended into the
    /// starting figure rather than replacing it.
    @Test func thePaceIsMeasuredOffTheDaysOwnTimestamps() throws {
        let stops = (0..<5).map { customer("K\($0)") }
        let route = try route(stops)
        for (i, stop) in stops.prefix(4).enumerated() {
            stop.record(.delivered, at: at(Double(i) * 15))
        }
        let snapshot = snap(route)

        #expect(snapshot.doorSamples == [5, 5, 5])
        #expect(snapshot.pace.measured)
        let weight = RouteSnapshot.Pace.priorWeight
        #expect(abs(snapshot.pace.minutesPerStop - (15 + weight * door) / (3 + weight)) < 1e-9)
    }

    /// A break, a tick made the next morning and three ticks caught up at a
    /// red light are none of them a door time. Measured first tick to last,
    /// one of them was spread over every door of the day.
    @Test func breaksAndLateTicksAreNotDoorTimes() throws {
        let stops = (0..<6).map { customer("K\($0)") }
        let route = try route(stops)
        let times: [Double] = [0, 16, 76, 76.2, 92, 1500]
        for (stop, time) in zip(stops, times) { stop.record(.delivered, at: at(time)) }

        // 0→16 and 76.2→92; the hour's break, the double tick and the next
        // day are left out.
        let samples = snap(route).doorSamples
        #expect(samples.count == 2)
        #expect(abs(samples[0] - 6) < 1e-9 && abs(samples[1] - 5.8) < 1e-9)
    }

    /// One slow door counts, but only for so much.
    @Test func oneSlowDoorIsCapped() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)
        b.record(.delivered, at: at(44))
        let pace = snap(route).pace
        let weight = RouteSnapshot.Pace.priorWeight

        #expect(snap(route).doorSamples == [34])
        #expect(abs(pace.minutesPerStop
            - (RouteSnapshot.Pace.cap + weight * door) / (1 + weight)) < 1e-9)
    }

    /// An abbestellt door, or a meal for the Lager, is ticked whenever the
    /// office rings — in the yard at half past seven, as often as not.
    @Test func aDoorNobodyWentToIsNotInThePace() throws {
        let stops = (0..<4).map { customer("K\($0)") }
        let route = try route(stops)
        stops[3].record(.toLager, at: at(-20))
        stops[0].record(.delivered, at: noon)
        stops[1].record(.delivered, at: at(15))

        #expect(snap(route).doorSamples == [5])
    }

    /// Stops ticked before a time was kept with the tick measure nothing.
    @Test func stopsWithNoRecordedTimeMeasureNothing() throws {
        let stops = (0..<4).map { customer("K\($0)") }
        let route = try route(stops)
        for stop in stops.prefix(3) {
            stop.record(.delivered)
            stop.settledAt = nil
        }
        #expect(snap(route).doorSamples.isEmpty)
        #expect(snap(route).pace == .assumed)
    }

    // MARK: - The end of the shift

    /// The last point the tour drives to: every leg and every door.
    @Test func theFinishIsEveryLegAndEveryDoor() throws {
        let a = customer("A"), b = customer("B")
        let home = fixed(.end, minutes: nil)
        let route = try route([a, b, home])

        #expect(minutesAfterNoon(snap(route).etaFinish(from: noon)) == 20 + 2 * door)

        // After A, counted from its tick: the drive, B's door, the drive home.
        a.record(.delivered, at: noon)
        #expect(minutesAfterNoon(snap(route).etaFinish(from: at(6))) == 20 + door)
    }

    @Test func aFinishedTourIsGivenNoFinishingTime() throws {
        let a = customer("A"), b = customer("B")
        let route = try route([a, b])
        a.record(.delivered, at: noon)
        b.record(.delivered, at: at(15))
        #expect(snap(route).etaFinish(from: at(15)) == nil)
    }

    // MARK: - What the tours before say

    /// A finished tour's ticks become the next one's starting figure.
    @Test func finishedToursTeachTheDoorTime() throws {
        let stops = (0..<12).map { customer("K\($0)") }
        let route = try route(stops, finished: true)
        for (i, stop) in stops.enumerated() { stop.record(.delivered, at: at(Double(i) * 14)) }

        let learned = PaceHistory.learn(from: [route])
        #expect(learned.doorMinutes == 4)
    }

    /// Too few ticks is no history, and a tour still being driven is its own
    /// measurement, not history.
    @Test func aThinOrUnfinishedTourTeachesNothing() throws {
        let few = (0..<5).map { customer("K\($0)") }
        let thin = try route(few, finished: true)
        for (i, stop) in few.enumerated() { stop.record(.delivered, at: at(Double(i) * 14)) }
        #expect(PaceHistory.learn(from: [thin]) == .none)

        let stops = (0..<12).map { customer("K\($0)") }
        let driving = try route(stops)
        for (i, stop) in stops.enumerated() { stop.record(.delivered, at: at(Double(i) * 14)) }
        #expect(PaceHistory.learn(from: [driving]) == .none)
    }

    /// The loading is what is left between the Lager's tick and the first
    /// door's, once the drive and that door are taken off — and a Lager
    /// ticked by the first door itself measures nothing.
    @Test func finishedToursTeachTheLoadingTime() throws {
        func tour(lagerAt: Double?) throws -> Route {
            let lager = fixed(.via)
            let stops = (0..<12).map { customer("K\($0)") }
            let route = try route([lager] + stops, finished: true)
            // First door 34 minutes in: 10 of driving, 4 at the door, 20 loading.
            for (i, stop) in stops.enumerated() {
                stop.record(.delivered, at: at(34 + Double(i) * 14))
            }
            lager.record(.delivered, at: at(lagerAt ?? 34))
            return route
        }
        let learned = PaceHistory.learn(from: [try tour(lagerAt: 0), try tour(lagerAt: 0)])
        #expect(learned.doorMinutes == 4)
        #expect(learned.lagerMinutes == 20)

        let auto = PaceHistory.learn(from: [try tour(lagerAt: nil), try tour(lagerAt: nil)])
        #expect(auto.lagerMinutes == nil)
    }
}
