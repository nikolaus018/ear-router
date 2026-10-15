import CoreLocation
import Foundation

/// The drive between every two places of a split, as OSRM's table has it.
///
/// Asked for once, when the split is loaded: the fair split needs it, and so
/// does every "ca. 4 h 10" the screen shows under a person — for a split
/// drawn by hand as much as for one worked out.
struct SplitDurations: Sendable {
    /// Matrix point of each placed stop. Stops at the very same point share
    /// one, so a Gemeindebau is one row of the table rather than twelve.
    let point: [Int: Int]
    /// `[from][to]` in seconds. Point 0 is the Lager, point 1 the Start,
    /// which is also every share's Ziel — see `RouteStore.createRoute`.
    let seconds: [[Double]]
    /// `true` when OSRM could not be asked and the drive is a guess from the
    /// straight line. Good enough to share doors out by; said on screen.
    let estimated: Bool

    var startToLagerSeconds: Double { seconds[1][0] }

    /// One table call over every distinct point; the straight line when that
    /// cannot be had — no signal, or more points than the server takes.
    static func load(for stops: [SplitStop]) async -> SplitDurations {
        var coordinates: [(lat: Double, lon: Double)] = [
            (Coordinates.via.lat, Coordinates.via.lon),
            (Coordinates.start.lat, Coordinates.start.lon),
        ]
        var byKey: [PointKey: Int] = [:]
        var point: [Int: Int] = [:]
        for stop in stops {
            guard let c = stop.coordinate else { continue }
            let key = PointKey(c)
            if let known = byKey[key] {
                point[stop.id] = known
            } else {
                byKey[key] = coordinates.count
                point[stop.id] = coordinates.count
                coordinates.append((c.latitude, c.longitude))
            }
        }
        if coordinates.count <= osrmMaxTripCoords,
           let table = try? await OSRMClient.shared.durations(between: coordinates)
        {
            return SplitDurations(point: point, seconds: table, estimated: false)
        }
        return SplitDurations(
            point: point, seconds: straightLine(coordinates), estimated: true)
    }

    /// Crow-flies distance, a third longer for the streets, at the 25 km/h a
    /// van makes across Vienna, plus half a minute for setting off.
    static func straightLine(_ c: [(lat: Double, lon: Double)]) -> [[Double]] {
        c.map { a in
            c.map { b in
                let metres = CLLocation(latitude: a.lat, longitude: a.lon)
                    .distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
                return metres < 1 ? 0 : 30 + metres * 1.35 / (25 / 3.6)
            }
        }
    }

    /// One point to about a metre — the same tolerance `SameDoor` uses.
    private struct PointKey: Hashable {
        let lat: Int64, lon: Int64
        init(_ c: CLLocationCoordinate2D) {
            lat = Int64((c.latitude * 100_000).rounded())
            lon = Int64((c.longitude * 100_000).rounded())
        }
    }
}

/// What one person's share comes to, the way "Tour vorbereiten" would count it.
struct SplitDay: Equatable, Sendable {
    var stops: Int
    var drivingMinutes: Double
    var doorMinutes: Double
    /// From leaving for the Lager to being back: the morning lead and the
    /// loading are everybody's, and in it so the figure is the day's.
    var totalMinutes: Double
}

/// What the planner needs, cut off from the screen so it can run off the
/// main actor.
struct FairSplitInput: Sendable {
    /// The stop ids behind each door, in `doors` order.
    let units: [[Int]]
    let doors: [SplitPlanner.Door]
    let people: Int
    let durations: SplitDurations
    /// Minutes every share carries whoever drives it: the morning to the
    /// Lager and the loading there.
    let fixedMinutes: Double

    func days(_ planned: [SplitPlanner.Day]) -> [SplitDay] {
        planned.map { day in
            let stops = day.doors.reduce(0) { $0 + units[$1].count }
            let driving = day.drivingSeconds / 60
            let doors = day.doorSeconds / 60
            return SplitDay(
                stops: stops, drivingMinutes: driving, doorMinutes: doors,
                totalMinutes: stops == 0 ? 0 : fixedMinutes + driving + doors)
        }
    }

    /// The planner's answer as who has which stop.
    func owners(_ planned: [SplitPlanner.Day]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (person, day) in planned.enumerated() {
            for door in day.doors { for id in units[door] { out[id] = person } }
        }
        return out
    }
}

extension FairSplitInput {
    /// What the alert after a fair split says: everybody's day, and how far
    /// apart the longest and the shortest are.
    static func summary(_ days: [SplitDay], estimated: Bool, unplacedFree: Int) -> String {
        var lines = days.enumerated().map { index, day in
            day.stops == 0
                ? "Person \(index + 1): keine Stopps"
                : "Person \(index + 1): \(Format.stops(day.stops)) · ca. \(day.clock)"
        }
        let worked = days.filter { $0.stops > 0 }.map(\.totalMinutes)
        if worked.count > 1, let longest = worked.max(), let shortest = worked.min() {
            let gap = Int((longest - shortest).rounded())
            lines.append("")
            lines.append(
                gap == 0
                    ? "Alle Tage sind gleich lang."
                    : "Längster und kürzester Tag liegen \(gap) min auseinander.")
        }
        if estimated {
            lines.append("")
            lines.append("OSRM war nicht erreichbar — die Fahrzeiten sind nach Luftlinie geschätzt.")
        }
        if unplacedFree > 0 {
            lines.append("")
            lines.append(
                unplacedFree == 1
                    ? "1 Stopp ohne Ort auf der Karte ist noch frei."
                    : "\(unplacedFree) Stopps ohne Ort auf der Karte sind noch frei.")
        }
        return lines.joined(separator: "\n")
    }
}

extension SplitState {
    /// The split as the planner sees it: every placed stop in a door, and
    /// every door with the time it takes.
    ///
    /// A door is one address, or one exactly known point — two flats in one
    /// Gemeindebau. Its households always go to one driver: the second is
    /// carried up on the same walk, at `RouteSnapshot.Pace.sharedDoor` of a
    /// door's time, and splitting them would send two vans to one Haustür.
    /// The one exception is a door whose households were already given to two
    /// different people by hand: each keeps theirs, and a free household
    /// there goes with the first.
    ///
    /// A door's time is each customer's own, from the tours driven before —
    /// the fourth floor without a lift is in it, and so is the lady who
    /// talks — pulled towards what a door on this tour takes. See
    /// `PaceHistory.doorMinutes(forCustomer:onTour:)`.
    ///
    /// Stops with no place on the map are left out: there is no telling what
    /// the drive to them is. They stay where they are, free or not.
    func fairSplitInput(history: PaceHistory) -> FairSplitInput? {
        guard let durations else { return nil }
        let placed = stops.filter { durations.point[$0.id] != nil }

        // Union-find over the placed stops: by address, and by exact point.
        var parent = Array(placed.indices)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            return r
        }
        var byAddress: [String: Int] = [:]
        var byPoint: [Int: Int] = [:]
        for (i, stop) in placed.enumerated() {
            let street = AddressText.matchKey(stop.address)
            if !street.isEmpty {
                let key = "\(street)|\(stop.plz.trimmed)"
                if let first = byAddress[key] { parent[find(i)] = find(first) } else { byAddress[key] = i }
            }
            if stop.exactPoint, let point = durations.point[stop.id] {
                if let first = byPoint[point] { parent[find(i)] = find(first) } else { byPoint[point] = i }
            }
        }
        var groups: [Int: [SplitStop]] = [:]
        var order: [Int] = []
        for i in placed.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(placed[i])
        }

        var units: [[Int]] = []
        var doors: [SplitPlanner.Door] = []
        for root in order {
            let members = groups[root] ?? []
            // By owner, so two people's households at one door stay apart.
            let firstOwner = members.lazy.compactMap { owner[$0.id] }.first
            var byOwner: [Int?: [SplitStop]] = [:]
            var owners: [Int?] = []
            for stop in members {
                let who = owner[stop.id] ?? firstOwner
                if byOwner[who] == nil { owners.append(who) }
                byOwner[who, default: []].append(stop)
            }
            for who in owners {
                let share = byOwner[who] ?? []
                guard let point = share.first.flatMap({ durations.point[$0.id] }) else { continue }
                let minutes = share
                    .map {
                        history.doorMinutes(
                            forCustomer: StockwerkKey.make(kunde: $0.name, strasse: $0.address, plz: $0.plz),
                            onTour: tourName)
                    }
                    .sorted(by: >)
                // The longest is the door; every further household is
                // carried up on the same walk.
                let total = minutes.enumerated().reduce(0.0) { sum, item in
                    sum + item.element * (item.offset == 0 ? 1 : RouteSnapshot.Pace.sharedDoor)
                }
                units.append(share.map(\.id))
                doors.append(SplitPlanner.Door(point: point, seconds: total * 60, owner: who))
            }
        }

        let lead = history.leadMinutes ?? durations.startToLagerSeconds / 60
        let loading = history.lagerMinutes ?? RouteSnapshot.Pace.lagerMinutes
        return FairSplitInput(
            units: units, doors: doors, people: people, durations: durations,
            fixedMinutes: lead + loading)
    }

    /// Each person's day with the split as it stands — drawn by hand or not.
    /// `nil` until the drive between the stops is known.
    func days(history: PaceHistory = .current) -> [SplitDay]? {
        guard let input = fairSplitInput(history: history) else { return nil }
        var shares = [[Int]](repeating: [], count: people)
        for (index, door) in input.doors.enumerated() {
            if let who = door.owner, who < people { shares[who].append(index) }
        }
        let planned = SplitPlanner.evaluate(
            shares, doors: input.doors, durations: input.durations.seconds)
        return input.days(planned)
    }
}

extension SplitDay {
    /// "4 h 05" — the day in the short form the person picker has room for.
    var clock: String {
        let total = Int(totalMinutes.rounded())
        return String(format: "%d h %02d", total / 60, total % 60)
    }
}
