import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// When the van gets to each remaining door.
///
/// Driving time is the only thing OSRM knows and it is about half of this
/// round; the rest is parking, a staircase and two minutes with somebody who
/// has not spoken to anybody since yesterday. So the estimate is driving plus a
/// per-door figure, and that figure is measured off the day's own timestamps
/// rather than assumed. These pin down both halves, and the refusals — the
/// cases where saying nothing beats saying a number.
@MainActor
struct ArrivalEstimateTests {

    private func route(_ stops: [Stop]) throws -> Route {
        let context = ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let route = Route(name: "Test")
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

    private let noon = Date(timeIntervalSince1970: 1_757_000_000)

    private func minutesFromNow(_ date: Date?) -> Double? {
        date.map { $0.timeIntervalSince(noon) / 60 }
    }

    /// The first open door is however far the van still has to drive, plus
    /// nothing — there are no other doors in between.
    @Test func theNextDoorIsPureDrivingTime() throws {
        let a = customer("A"), b = customer("B")
        let route = try route([a, b])
        let snapshot = RouteSnapshot(route)

        #expect(minutesFromNow(snapshot.eta(for: a, from: noon)) == 0.0)
    }

    /// A point the van has already passed gets none. The depot and the
    /// warehouse carry no outcome and so are never "settled" — left to the
    /// clamp alone they sat at the top of the list all day promising an
    /// arrival of exactly now.
    @Test func aPointTheVanHasAlreadyPassedIsGivenNoArrivalTime() throws {
        let depot = Stop(
            kind: .start, kunde: "Start", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz,
            lat: Coordinates.start.lat, lon: Coordinates.start.lon)
        depot.nextLegKm = 1
        depot.nextLegMin = 10
        let a = customer("A"), b = customer("B")
        let route = try route([depot, a, b])

        // Before setting off: the depot is where the driver is standing.
        #expect(RouteSnapshot(route).eta(for: depot, from: noon) == nil)

        // And after a delivery it is behind them, rather than promising `now`
        // for the rest of the shift.
        a.record(.delivered, at: noon)
        #expect(RouteSnapshot(route).eta(for: depot, from: noon) == nil)
        #expect(RouteSnapshot(route).eta(for: b, from: noon) != nil)
    }

    /// And every door after it pays for the ones in front: the drive, plus the
    /// assumed four minutes at each door still to be answered.
    @Test func eachFurtherDoorPaysForTheStopsInFrontOfIt() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        let snapshot = RouteSnapshot(route)

        #expect(snapshot.pace == .assumed)
        // B: ten minutes of driving out of A, plus A's own door.
        #expect(minutesFromNow(snapshot.eta(for: b, from: noon)) == 14.0)
        // C: twenty minutes of driving, plus two doors.
        #expect(minutesFromNow(snapshot.eta(for: c, from: noon)) == 28.0)
    }

    /// A fixed point still ahead of the van keeps its arrival time — "when am
    /// I at the warehouse" and "when am I back at the depot" are both real
    /// questions, and the rule above only silences the ones already behind.
    @Test func aFixedPointStillAheadKeepsItsArrivalTime() throws {
        let depot = Stop(
            kind: .start, kunde: "Start", strasse: Coordinates.startAddress,
            plz: Coordinates.startPlz,
            lat: Coordinates.start.lat, lon: Coordinates.start.lon)
        depot.nextLegKm = 1
        depot.nextLegMin = 10
        let warehouse = Stop(
            kind: .via, kunde: "Lager", strasse: Coordinates.viaAddress,
            plz: Coordinates.viaPlz, lat: Coordinates.via.lat, lon: Coordinates.via.lon)
        warehouse.nextLegKm = 1
        warehouse.nextLegMin = 10
        let a = customer("A")
        let route = try route([depot, warehouse, a])

        #expect(minutesFromNow(RouteSnapshot(route).eta(for: warehouse, from: noon)) == 10.0)
    }

    /// Counted from where the driver is now, not from the depot. A morning that
    /// ran late moves every remaining estimate with it rather than staying
    /// quietly wrong all day.
    @Test func theEstimateIsCountedFromWhereTheDriverIsStanding() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)

        let snapshot = RouteSnapshot(route)
        // B is the next door: the drive out of A, and no doors in between.
        #expect(minutesFromNow(snapshot.eta(for: b, from: noon)) == 10.0)
        #expect(minutesFromNow(snapshot.eta(for: c, from: noon)) == 24.0)
    }

    /// A door already answered for has no arrival time. An estimate for a
    /// delivery made an hour ago is noise on the row.
    @Test func aSettledStopIsGivenNoArrivalTime() throws {
        let a = customer("A"), b = customer("B")
        let route = try route([a, b])
        a.record(.notHome, at: noon)

        #expect(RouteSnapshot(route).eta(for: a, from: noon) == nil)
    }

    /// A route nobody has optimized has a zero for every leg. Estimating from
    /// that promises all thirty customers their meal at the same minute, which
    /// is worse than promising nothing.
    @Test func aRouteWithNoLegsIsGivenNoArrivalTimesAtAll() throws {
        let a = customer("A", minutes: nil), b = customer("B", minutes: nil)
        a.nextLegKm = nil
        b.nextLegKm = nil
        let route = try route([a, b])
        let snapshot = RouteSnapshot(route)

        #expect(snapshot.eta(for: a, from: noon) == nil)
        #expect(snapshot.eta(for: b, from: noon) == nil)
        #expect(snapshot.etaFinish(from: noon) == nil)
    }

    // MARK: - Pace

    /// Three settled doors is the floor. Two give one interval, and one
    /// interval is a coincidence rather than a pace.
    @Test func twoSettledStopsAreNotYetAPace() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)
        b.record(.delivered, at: noon.addingTimeInterval(20 * 60))

        #expect(RouteSnapshot(route).pace == .assumed)
    }

    /// Measured: the wall-clock time between the first and last settled door,
    /// less the driving OSRM says lies between them, spread over the doors in
    /// between.
    ///
    /// Three doors ten driving-minutes apart, settled at noon, 12:15 and 12:30:
    /// thirty minutes elapsed, twenty of them driving, ten left over two doors.
    @Test func thePaceIsMeasuredOffTheDaysOwnTimestamps() throws {
        let a = customer("A"), b = customer("B"), c = customer("C"), d = customer("D")
        let route = try route([a, b, c, d])
        a.record(.delivered, at: noon)
        b.record(.delivered, at: noon.addingTimeInterval(15 * 60))
        c.record(.delivered, at: noon.addingTimeInterval(30 * 60))

        let pace = RouteSnapshot(route).pace
        #expect(pace.measured)
        #expect(pace.minutesPerStop == 5)
    }

    /// An abbestellt ticked in the yard, when the office rang, before the van
    /// had moved. Counted as a door it moved the start of the clock back to
    /// the yard: four deliveries two minutes apart at the door measured as
    /// twelve, and every arrival after them slid by hours.
    @Test func anAbbestelltTickedInTheYardDoesNotSkewThePace() throws {
        var stops: [Stop] = []
        for i in 1...20 { stops.append(customer("K\(i)", minutes: 4)) }
        let route = try route(stops)
        stops[19].record(.cancelled, at: noon)
        stops[0].record(.delivered, at: noon.addingTimeInterval(30 * 60))
        stops[1].record(.delivered, at: noon.addingTimeInterval(36 * 60))
        stops[2].record(.delivered, at: noon.addingTimeInterval(42 * 60))
        stops[3].record(.delivered, at: noon.addingTimeInterval(48 * 60))

        // 18 minutes between the first and last delivery, 12 of them driving,
        // over three doors.
        let pace = RouteSnapshot(route).pace
        #expect(pace.measured)
        #expect(pace.minutesPerStop == 2)
    }

    /// A driver catching up on three ticks at a red light would otherwise have
    /// the app promise the whole round by half past ten.
    @Test func animplausiblyFastMeasurementIsRefused() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        a.record(.delivered, at: noon)
        b.record(.delivered, at: noon.addingTimeInterval(2))
        c.record(.delivered, at: noon.addingTimeInterval(4))

        #expect(RouteSnapshot(route).pace == .assumed)
    }

    /// A tour driven before stops carried a time has none to measure from, and
    /// falls back rather than refusing to estimate at all.
    @Test func stopsWithNoRecordedTimeFallBackToTheAssumption() throws {
        let a = customer("A"), b = customer("B"), c = customer("C")
        let route = try route([a, b, c])
        for s in [a, b, c] {
            s.delivered = true
            s.settledAt = nil
        }

        #expect(RouteSnapshot(route).pace == .assumed)
    }

    /// The measured pace is what the remaining estimates are then built on —
    /// the point of measuring it at all.
    @Test func aMeasuredPaceFeedsTheRemainingArrivals() throws {
        let a = customer("A"), b = customer("B"), c = customer("C"), d = customer("D")
        let route = try route([a, b, c, d])
        a.record(.delivered, at: noon)
        b.record(.delivered, at: noon.addingTimeInterval(15 * 60))
        c.record(.delivered, at: noon.addingTimeInterval(30 * 60))

        let snapshot = RouteSnapshot(route)
        // Standing at C, one leg to D and no doors in between.
        #expect(minutesFromNow(snapshot.eta(for: d, from: noon)) == 10.0)
        // And the shift ends after the drive still ahead — the leg into D and
        // the leg out of it — plus D's own five-minute door.
        #expect(minutesFromNow(snapshot.etaFinish(from: noon)) == 25.0)
    }

    /// Nothing left to deliver means no finishing time to promise — the tour is
    /// over, and the drive home is reported as kilometres elsewhere.
    @Test func aFinishedTourIsGivenNoFinishingTime() throws {
        let a = customer("A")
        let route = try route([a])
        a.record(.delivered, at: noon)

        #expect(RouteSnapshot(route).etaFinish(from: noon) == nil)
    }
}
