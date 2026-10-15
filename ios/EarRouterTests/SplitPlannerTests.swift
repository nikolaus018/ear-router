import CoreLocation
import Foundation
import Testing
@testable import EarRouter

/// The fair split: who gets which doors so that nobody's day is longer than
/// it has to be.
struct SplitPlannerTests {

    /// Points on a flat map, in metres, driven at 8 m/s; point 0 is the Lager
    /// and point 1 the Ziel.
    private func matrix(_ points: [(Double, Double)]) -> [[Double]] {
        points.map { a in points.map { b in hypot(a.0 - b.0, a.1 - b.1) / 8 } }
    }

    private func doors(_ count: Int, seconds: Double = 420, from first: Int = 2) -> [SplitPlanner.Door] {
        (0..<count).map { SplitPlanner.Door(point: first + $0, seconds: seconds, owner: nil) }
    }

    /// A deterministic scatter, so a failing case can be looked at again.
    private func scatter(_ count: Int, seed: UInt64) -> [(Double, Double)] {
        var random = TourPolish.SplitMix(seed: seed)
        return (0..<count).map { _ in
            (Double(random.next() % 12_000), Double(random.next() % 12_000))
        }
    }

    @Test func twoNeighbourhoodsGoToTwoPeople() {
        // Six doors in the west, six in the east, the Lager and Ziel between.
        let west = (0..<6).map { (Double(-5_000 + $0 * 50), Double($0 * 40)) }
        let east = (0..<6).map { (Double(5_000 + $0 * 50), Double($0 * 40)) }
        let m = matrix([(0, 0), (0, 0)] + west + east)
        let days = SplitPlanner.plan(doors: doors(12), people: 2, durations: m, rounds: 40)

        #expect(days.count == 2)
        let shares = days.map { Set($0.doors) }
        #expect(shares.contains(Set(0..<6)))
        #expect(shares.contains(Set(6..<12)))
    }

    /// Fair is the length of the day, not the count of doors: three slow
    /// doors are worth more than three quick ones.
    @Test func slowDoorsCountForMoreThanQuickOnes() {
        // Every door at one place, so only the door times can tell them apart.
        let m = matrix([(0, 0), (0, 0)] + Array(repeating: (1_000.0, 0.0), count: 8))
        let slow = (0..<2).map { SplitPlanner.Door(point: 2 + $0, seconds: 1_200, owner: nil) }
        let quick = (2..<8).map { SplitPlanner.Door(point: 2 + $0, seconds: 400, owner: nil) }
        let days = SplitPlanner.plan(doors: slow + quick, people: 2, durations: m, rounds: 40)

        // 2 × 20 + 6 × 6.7 min = 80 min: 40 each, which is one slow door and
        // three quick ones each — not four doors each by count.
        let doorMinutes = days.map { $0.doorSeconds / 60 }
        #expect(abs(doorMinutes[0] - doorMinutes[1]) < 0.01)
        for day in days { #expect(day.doors.filter { $0 < 2 }.count == 1) }
    }

    @Test func doorsGivenByHandStayWhereTheyAre() {
        let points = scatter(20, seed: 7)
        let m = matrix([(6_000, 6_000), (6_000, 6_000)] + points)
        var given = doors(20)
        given[0] = SplitPlanner.Door(point: 2, seconds: 420, owner: 1)
        given[1] = SplitPlanner.Door(point: 3, seconds: 420, owner: 1)
        given[2] = SplitPlanner.Door(point: 4, seconds: 420, owner: 0)
        let days = SplitPlanner.plan(doors: given, people: 3, durations: m, rounds: 30)

        #expect(days[1].doors.contains(0))
        #expect(days[1].doors.contains(1))
        #expect(days[0].doors.contains(2))
        // Every door handed out, and each only once.
        let all = days.flatMap(\.doors)
        #expect(all.count == 20)
        #expect(Set(all) == Set(0..<20))
    }

    @Test func theSameTourComesBackSplitTheSameWay() {
        let m = matrix([(6_000, 6_000), (6_000, 6_000)] + scatter(30, seed: 3))
        let a = SplitPlanner.plan(doors: doors(30), people: 3, durations: m, rounds: 40)
        let b = SplitPlanner.plan(doors: doors(30), people: 3, durations: m, rounds: 40)
        #expect(a == b)
    }

    /// Against the split a person makes by eye — the map cut into slices
    /// round the Lager — the planner's longest day is never longer, and the
    /// days come out close together.
    @Test func theLongestDayBeatsSlicingTheMapAndTheDaysAreEven() {
        for seed in [1, 2, 3, 4] as [UInt64] {
            let points = scatter(45, seed: seed)
            let centre = (6_000.0, 6_000.0)
            let m = matrix([centre, centre] + points)
            let given = doors(45)
            let planned = SplitPlanner.plan(doors: given, people: 3, durations: m, rounds: 120)

            // Three slices of fifteen doors by angle round the Lager.
            let byAngle = points.indices.sorted {
                atan2(points[$0].1 - centre.1, points[$0].0 - centre.0)
                    < atan2(points[$1].1 - centre.1, points[$1].0 - centre.0)
            }
            let slices = (0..<3).map { Array(byAngle[($0 * 15)..<($0 * 15 + 15)]) }
            let sliced = SplitPlanner.evaluate(slices, doors: given, durations: m)

            let longest = planned.map(\.seconds).max()!
            let shortest = planned.map(\.seconds).min()!
            #expect(longest <= sliced.map(\.seconds).max()! + 1)
            // Within ten minutes of each other on a day of several hours.
            #expect(longest - shortest < 600, "seed \(seed): \(planned.map { Int($0.seconds / 60) })")
        }
    }

    @Test func moreLeftToShareThanPeopleIsFineAndSoIsTheReverse() {
        let m = matrix([(0, 0), (0, 0), (100, 0), (200, 0)])
        let days = SplitPlanner.plan(doors: doors(2), people: 4, durations: m, rounds: 10)
        #expect(days.count == 4)
        #expect(days.flatMap(\.doors).sorted() == [0, 1])
        // A person with no doors has no day, rather than a drive to nowhere.
        for day in days where day.doors.isEmpty { #expect(day.seconds == 0) }
    }

    @Test func aBigTourFinishesInsideItsTime() {
        let m = matrix([(6_000, 6_000), (6_000, 6_000)] + scatter(100, seed: 11))
        let started = Date()
        let days = SplitPlanner.plan(
            doors: doors(100), people: 8, durations: m,
            deadline: Date().addingTimeInterval(SplitPlanner.thinkingTime))
        // The deadline is checked between moves; a pass may run past it.
        #expect(Date().timeIntervalSince(started) < SplitPlanner.thinkingTime + 3)
        #expect(days.flatMap(\.doors).count == 100)
    }
}

/// From the stops on the split screen to what the planner is asked.
struct FairSplitInputTests {
    private let gemeindebau = CLLocationCoordinate2D(latitude: 48.2301, longitude: 16.3401)

    private func stop(_ id: Int, _ address: String, at c: CLLocationCoordinate2D?, exact: Bool = true) -> SplitStop {
        SplitStop(
            id: id, name: "Kunde \(id)", address: address, plz: "1180", coordinate: c, exactPoint: exact)
    }

    private func durations(_ stops: [SplitStop]) -> SplitDurations {
        var points: [(lat: Double, lon: Double)] = [
            (Coordinates.via.lat, Coordinates.via.lon), (Coordinates.start.lat, Coordinates.start.lon),
        ]
        var point: [Int: Int] = [:]
        for s in stops {
            guard let c = s.coordinate else { continue }
            if let i = points.firstIndex(where: { $0.lat == c.latitude && $0.lon == c.longitude }) {
                point[s.id] = i
            } else {
                point[s.id] = points.count
                points.append((c.latitude, c.longitude))
            }
        }
        return SplitDurations(point: point, seconds: SplitDurations.straightLine(points), estimated: true)
    }

    @Test func householdsBehindOneDoorAreOneThingToHandOut() {
        let stops = [
            stop(1, "Gentzgasse 129/1/3", at: gemeindebau),
            stop(2, "Gentzgasse 129/2/7", at: gemeindebau),
            stop(3, "Gentzgasse 129/1/3", at: CLLocationCoordinate2D(latitude: 48.2302, longitude: 16.3402)),
            stop(4, "Währinger Straße 2", at: CLLocationCoordinate2D(latitude: 48.22, longitude: 16.36)),
        ]
        var state = SplitState(tourName: "VM 4", people: 2, stops: stops)
        state.durations = durations(stops)
        let input = state.fairSplitInput(history: .none)!

        // 1 and 2 share a point, 1 and 3 an address: one door, three meals.
        #expect(input.units.count == 2)
        #expect(Set(input.units[0]) == [1, 2, 3])
        // The first at a whole door's time, the other two carried up with it.
        let door = RouteSnapshot.Pace.assumedMinutes * 60
        #expect(abs(input.doors[0].seconds - door * (1 + 2 * RouteSnapshot.Pace.sharedDoor)) < 0.01)
    }

    /// A district centroid is no door: thirty customers there are not one
    /// Gemeindebau.
    @Test func anApproximatePointJoinsNothing() {
        let stops = [
            stop(1, "Irgendwo 1", at: gemeindebau, exact: false),
            stop(2, "Anderswo 9", at: gemeindebau, exact: false),
        ]
        var state = SplitState(tourName: "VM 4", people: 2, stops: stops)
        state.durations = durations(stops)
        #expect(state.fairSplitInput(history: .none)!.units.count == 2)
    }

    @Test func stopsWithNoPlaceOnTheMapAreLeftAlone() {
        let stops = [stop(1, "Gentzgasse 1", at: gemeindebau), stop(2, "Unbekannt 4", at: nil)]
        var state = SplitState(tourName: "VM 4", people: 2, stops: stops)
        state.durations = durations(stops)
        #expect(state.fairSplitInput(history: .none)!.units.flatMap { $0 } == [1])
    }

    @Test func aDoorTwoPeopleWereGivenStaysWithBoth() {
        let stops = [
            stop(1, "Gentzgasse 129/1", at: gemeindebau),
            stop(2, "Gentzgasse 129/2", at: gemeindebau),
            stop(3, "Gentzgasse 129/3", at: gemeindebau),
        ]
        var state = SplitState(tourName: "VM 4", people: 2, stops: stops)
        state.durations = durations(stops)
        state.claim([1], for: 0)
        state.claim([2], for: 1)
        let input = state.fairSplitInput(history: .none)!
        #expect(input.units.count == 2)
        // The free one goes with the first who has a household there.
        let first = input.units.firstIndex { $0.contains(1) }!
        #expect(Set(input.units[first]) == [1, 3])
        #expect(input.doors[first].owner == 0)
    }

    @Test func theFairSplitIsOneStepToUndo() {
        let stops = (0..<6).map {
            stop($0, "Gasse \($0 + 1)", at: CLLocationCoordinate2D(latitude: 48.20 + Double($0) * 0.01, longitude: 16.35))
        }
        var state = SplitState(tourName: "VM 4", people: 2, stops: stops)
        state.durations = durations(stops)
        let input = state.fairSplitInput(history: .none)!
        let planned = SplitPlanner.plan(
            doors: input.doors, people: 2, durations: input.durations.seconds, rounds: 10)
        #expect(state.assign(input.owners(planned)) == 6)
        #expect(state.freeCount == 0)
        #expect(state.days(history: .none)?.map(\.stops).reduce(0, +) == 6)
        state.undo()
        #expect(state.freeCount == 6)
    }

    @Test func theSummarySaysHowFarApartTheDaysAre() {
        let days = [
            SplitDay(stops: 12, drivingMinutes: 90, doorMinutes: 84, totalMinutes: 245),
            SplitDay(stops: 10, drivingMinutes: 100, doorMinutes: 70, totalMinutes: 251),
            SplitDay(stops: 0, drivingMinutes: 0, doorMinutes: 0, totalMinutes: 0),
        ]
        let text = FairSplitInput.summary(days, estimated: true, unplacedFree: 2)
        #expect(text.contains("Person 1: 12 Stopps · ca. 4 h 05"))
        #expect(text.contains("Person 2: 10 Stopps · ca. 4 h 11"))
        #expect(text.contains("Person 3: keine Stopps"))
        #expect(text.contains("6 min auseinander"))
        #expect(text.contains("Luftlinie"))
        #expect(text.contains("2 Stopps ohne Ort"))
    }
}

/// A customer's own door time, learned from the tours before.
struct CustomerDoorTimeTests {
    @Test func aCustomerIsPulledTowardsTheirTour() {
        var history = PaceHistory()
        history.doorMinutes = 6
        history.doorByCustomer["kunde|gasse 1|1180"] = .init(minutes: 14, samples: 3)
        // Three doors of fourteen against three doors' worth of six.
        #expect(history.doorMinutes(forCustomer: "kunde|gasse 1|1180", onTour: "VM 4") == 10)
        #expect(history.doorMinutes(forCustomer: "jemand|anders 2|1180", onTour: "VM 4") == 6)
        #expect(PaceHistory.none.doorMinutes(forCustomer: nil, onTour: "VM 4")
            == RouteSnapshot.Pace.assumedMinutes)
    }
}
