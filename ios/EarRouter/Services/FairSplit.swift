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
    /// How many addresses those stops are at: six customers at one address
    /// are six stops and one place to deliver to.
    var addresses = 0

    /// "21 Stopps an 16 Adressen", or just "16 Stopps" where every stop is
    /// an address of its own.
    var stopsLine: String {
        addresses > 0 && addresses < stops
            ? "\(Format.stops(stops)) an \(addresses) Adressen" : Format.stops(stops)
    }
}

/// What the planner needs, cut off from the screen so it can run off the
/// main actor.
struct FairSplitInput: Sendable {
    /// The stop ids behind each parking stop, in `doors` order.
    let units: [[Int]]
    let doors: [SplitPlanner.Door]
    /// How many addresses each parking stop is.
    let addresses: [Int]
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
                totalMinutes: stops == 0 ? 0 : fixedMinutes + driving + doors,
                addresses: day.doors.reduce(0) { $0 + addresses[$1] })
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
                : "Person \(index + 1): \(day.stopsLine) · ca. \(day.clock)"
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
    /// The split as the planner sees it: every placed stop in a parking stop
    /// — see `ParkingStops` — with the time it takes.
    ///
    /// A customer's time is their own, from the tours driven before — the
    /// fourth floor without a lift is in it, and so is the lady who talks —
    /// pulled towards what a door on this tour takes. See
    /// `PaceHistory.doorMinutes(forCustomer:onTour:)`.
    ///
    /// Stops with no place on the map are left out: there is no telling what
    /// the drive to them is. They stay where they are, free or not.
    ///
    /// `handedOutOnly` leaves the free stops out too: what each person's day
    /// is now, rather than what it would be with the free door next to one
    /// of theirs.
    func fairSplitInput(history: PaceHistory, handedOutOnly: Bool = false) -> FairSplitInput? {
        guard let durations else { return nil }
        let customers = stops.compactMap { stop -> ParkingStops.Customer? in
            guard let point = durations.point[stop.id], let coordinate = stop.coordinate,
                  !handedOutOnly || owner[stop.id] != nil
            else { return nil }
            return ParkingStops.Customer(
                id: stop.id, address: ParkingStops.addressKey(stop.door ?? stop.address, plz: stop.plz),
                point: point, coordinate: coordinate, exact: stop.exactPoint, owner: owner[stop.id],
                minutes: history.doorMinutes(
                    forCustomer: StockwerkKey.make(kunde: stop.name, strasse: stop.address, plz: stop.plz),
                    onTour: tourName))
        }
        let (units, doors, addresses) = ParkingStops.build(customers)
        let lead = history.leadMinutes ?? durations.startToLagerSeconds / 60
        let loading = history.lagerMinutes ?? RouteSnapshot.Pace.lagerMinutes
        return FairSplitInput(
            units: units, doors: doors, addresses: addresses, people: people,
            durations: durations, fixedMinutes: lead + loading)
    }

    /// Each person's day with the split as it stands — drawn by hand or not.
    /// `nil` until the drive between the stops is known.
    func days(history: PaceHistory = .current) -> [SplitDay]? {
        guard let input = fairSplitInput(history: history, handedOutOnly: true) else { return nil }
        var shares = [[Int]](repeating: [], count: people)
        for (index, door) in input.doors.enumerated() {
            if let who = door.owner, who < people { shares[who].append(index) }
        }
        let planned = SplitPlanner.evaluate(
            shares, doors: input.doors, durations: input.durations.seconds)
        return input.days(planned)
    }
}

/// Where the van stops: the customers one driver delivers from one parking
/// place, which is the thing the fair split hands out.
///
/// First the doors. One address, or one exactly known point, is one door —
/// two flats in one Gemeindebau, six meals for one office. Every household
/// after the first there is `sameDoorShare` of a door: no drive, no parking,
/// no second walk to the Haustür — only more to carry.
///
/// Then the doors a short walk apart — the next Stiege across the Hof, the
/// house two down — the same `WalkOn.reach` Jetzt carries parcels along for.
/// The van is parked once for all of them, so they are one parking stop:
/// split between two drivers, both would park there. Each door after the
/// first counts at `walkOnShare` of its time, with no drive. Every door in
/// one is within the reach of every other, so a long street of houses ninety
/// metres apart is not one parking stop a kilometre long. Only exactly known
/// points: a pin in the middle of a street says nothing about which houses
/// are next to each other.
///
/// Doors already given to somebody by hand stay theirs, and so does
/// everything in a parking stop with them: a free door twenty metres from
/// one of theirs goes along. Two people's doors are never one parking stop.
enum ParkingStops {
    /// A door a short walk from where the van stands, as a share of a door
    /// driven to — its walk, stairs and hand-over less the parking and the
    /// drive. Measured on the 13.10.2026 backup: two ticks in a row at most
    /// a hundred metres apart were 4.4 minutes apart (median of 12), against
    /// 6.3 minutes at a door driven to less its drive (median of 204).
    static let walkOnShare = 0.68

    /// Another household at the same door, as a share of a door: six
    /// customers at one address count as two doors. His rule (15.10.2026),
    /// from a split where the six went to one person whose 21 stops were
    /// "really 15", "but a lot to carry, so maybe count that as two".
    ///
    /// Lower than the arrival estimate's `RouteSnapshot.Pace.sharedDoor`
    /// on purpose. That one is a second household's minutes as the ticks
    /// say — measured on three pairs only — and a split is about how much
    /// of the day's work a share is, which the driver knows better.
    static let sameDoorShare = 0.2

    struct Customer {
        let id: Int
        /// `addressKey`: empty when there is no street.
        let address: String
        /// Matrix point, shared by customers at the very same coordinate.
        let point: Int
        let coordinate: CLLocationCoordinate2D
        let exact: Bool
        let owner: Int?
        let minutes: Double
    }

    static func addressKey(_ strasse: String, plz: String) -> String {
        let street = AddressText.matchKey(strasse)
        return street.isEmpty ? "" : "\(street)|\(plz.trimmed)"
    }

    /// The customer ids behind each parking stop, and the stop as the
    /// planner sees it.
    static func build(
        _ customers: [Customer]
    ) -> (units: [[Int]], doors: [SplitPlanner.Door], addresses: [Int]) {
        let doors = self.doors(customers)

        // Which doors are a walk apart and may share a van.
        func metres(_ a: Door, _ b: Door) -> Double {
            WalkOn.metres(from: [a.coordinate], to: [b.coordinate]) ?? .infinity
        }
        func compatible(_ a: Int?, _ b: Int?) -> Bool { a == nil || b == nil || a == b }
        let near: [[Int]] = doors.indices.map { i in
            guard doors[i].exact else { return [] }
            return doors.indices.filter { j in
                j != i && doors[j].exact && compatible(doors[i].owner, doors[j].owner)
                    && metres(doors[i], doors[j]) <= WalkOn.reach
            }
        }

        // The door with most neighbours first, so a Hof is one parking stop
        // round its middle rather than cut up from one corner.
        let byCrowd = doors.indices.sorted { (near[$0].count, $1) > (near[$1].count, $0) }
        var taken = [Bool](repeating: false, count: doors.count)
        var units: [[Int]] = []
        var out: [SplitPlanner.Door] = []
        var addresses: [Int] = []
        for anchor in byCrowd where !taken[anchor] {
            taken[anchor] = true
            var members = [anchor]
            var owner = doors[anchor].owner
            let candidates = near[anchor].filter { !taken[$0] }
                .sorted { (metres(doors[anchor], doors[$0]), $0) < (metres(doors[anchor], doors[$1]), $1) }
            for c in candidates where compatible(owner, doors[c].owner)
                && members.allSatisfy({ metres(doors[$0], doors[c]) <= WalkOn.reach })
            {
                taken[c] = true
                members.append(c)
                owner = owner ?? doors[c].owner
            }
            // The longest door is where the van is parked for; every other
            // is a walk from there.
            let times = members.map { doors[$0].minutes }.sorted(by: >)
            let minutes = times.enumerated().reduce(0.0) { sum, item in
                sum + item.element * (item.offset == 0 ? 1 : walkOnShare)
            }
            units.append(members.flatMap { doors[$0].ids })
            addresses.append(members.count)
            out.append(SplitPlanner.Door(point: doors[anchor].point, seconds: minutes * 60, owner: owner))
        }
        return (units, out, addresses)
    }

    private struct Door {
        let ids: [Int]
        let point: Int
        let coordinate: CLLocationCoordinate2D
        let exact: Bool
        let owner: Int?
        let minutes: Double
    }

    /// Households at one door together: by address — the flat left off,
    /// where the portal says which part is the flat — and by exact point. A
    /// door whose households were given to two people by hand is two doors,
    /// and a free household there goes with the first.
    private static func doors(_ customers: [Customer]) -> [Door] {
        var parent = Array(customers.indices)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            return r
        }
        var byAddress: [String: Int] = [:]
        var byPoint: [Int: Int] = [:]
        for (i, c) in customers.enumerated() {
            if !c.address.isEmpty {
                if let first = byAddress[c.address] { parent[find(i)] = find(first) } else { byAddress[c.address] = i }
            }
            if c.exact {
                if let first = byPoint[c.point] { parent[find(i)] = find(first) } else { byPoint[c.point] = i }
            }
        }
        var groups: [Int: [Customer]] = [:]
        var order: [Int] = []
        for i in customers.indices {
            let root = find(i)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(customers[i])
        }

        var out: [Door] = []
        for root in order {
            let members = groups[root] ?? []
            let firstOwner = members.lazy.compactMap(\.owner).first
            var byOwner: [Int?: [Customer]] = [:]
            var owners: [Int?] = []
            for c in members {
                let who = c.owner ?? firstOwner
                if byOwner[who] == nil { owners.append(who) }
                byOwner[who, default: []].append(c)
            }
            for who in owners {
                let share = byOwner[who] ?? []
                guard let first = share.first else { continue }
                // Where the door is: an exactly known household's point when
                // there is one.
                let placed = share.first(where: \.exact) ?? first
                let times = share.map(\.minutes).sorted(by: >)
                let minutes = times.enumerated().reduce(0.0) { sum, item in
                    sum + item.element * (item.offset == 0 ? 1 : sameDoorShare)
                }
                out.append(Door(
                    ids: share.map(\.id), point: placed.point, coordinate: placed.coordinate,
                    exact: placed.exact, owner: who, minutes: minutes))
            }
        }
        return out
    }
}

extension SplitDay {
    /// "4 h 05" — the day in the short form the person picker has room for.
    var clock: String {
        let total = Int(totalMinutes.rounded())
        return String(format: "%d h %02d", total / 60, total % 60)
    }
}
