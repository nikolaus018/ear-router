import Foundation


/// Everything one pass of the stop list needs to know about a route, computed
/// in a single walk of its stops.
///
/// Exists because each of these answers used to be a computed property on
/// `Route` or on the view, and every one of them re-sorted the whole stop array
/// on each read — several times per row, from inside a `ForEach`. The numbers
/// are identical; the difference is that they are worked out once.
struct RouteSnapshot {
    /// The stops in display order — one sort, shared by everything below.
    let ordered: [Stop]
    let customerCount: Int
    /// Meals that left the van — delivered, or handed to a neighbour.
    let deliveredCount: Int
    /// Doors the driver has answered for, whatever the answer was. The count
    /// the tour's own progress is measured against, because a customer who was
    /// not home is a door the van is not going back past.
    let settledCount: Int
    /// Customers marked abbestellt — never owed a meal today.
    let cancelledCount: Int
    /// The doors whose meal goes to the Lager instead — see `DeliveryOutcome.toLager`.
    let lagerCount: Int
    /// The next stop to tick off — a customer, or Lager or Ziel.
    let nextOpen: Stop?
    let totalKm: Double
    let totalMinutes: Double
    /// What is still to drive: every leg from the last stop the driver has
    /// actually settled to the end of the tour.
    ///
    /// Not the same number as the total, and the total is not the one a driver
    /// halfway through a shift is asking for — "27,3 km" stops meaning
    /// anything the moment the first meal is delivered. A leg belongs to the
    /// stop it leaves from, so everything before the last settled stop has
    /// been driven and everything from it onwards has not. With nothing
    /// settled yet this is the whole tour; with everything settled it is
    /// the drive back to the depot, which is real and still has to be made.
    let remainingKm: Double
    let remainingMinutes: Double

    /// The customers who did not get their meal and are the reason somebody
    /// makes a phone call, in the order they were driven.
    ///
    /// Only `notHome`. An abbestellt customer was never owed anything and a
    /// meal left with a neighbour arrived; the one outcome that ends the day
    /// owing somebody an explanation is the door nobody opened.
    let followUps: [Stop]

    /// How long a door actually takes today — parking, the stairs, the chat at
    /// the top of them. See `Pace`.
    let pace: Pace

    /// Each customer's position in driving order, so the list badge and the map
    /// pin show the same number.
    private let numbers: [UUID: Int]
    /// How many customers share each stop's front door — two households in one
    /// Gemeindebau is one ring of the bell and two meals carried up.
    private let doorCounts: [UUID: Int]
    /// Driving minutes from the start of the tour to arriving at each stop.
    private let arrivalMinutes: [UUID: Double]
    /// Where the driver is, in those same units: at the door of the last stop
    /// they settled, about to drive out of it.
    private let minutesDriven: Double
    /// The doors still to be answered before each stop — the stairs between
    /// here and there, which driving time alone knows nothing about. In doors,
    /// not minutes, and not a whole number: a second household at a door the
    /// van is already standing at costs `Pace.sharedDoor` of one.
    private let doorsBefore: [UUID: Double]
    /// What each open customer's own door counts for, in the same unit.
    private let ownDoor: [UUID: Double]
    /// Every open door on the tour, in that unit.
    private let openDoorUnits: Double
    /// The stops that still have the loading at the Lager in front of them.
    private let loadingBefore: Set<UUID>
    /// When the driver was last known to be at the point `minutesDriven`
    /// stands for: the time the last door in driving order was ticked. `nil`
    /// before the first tick, and when doors were ticked out of order — then
    /// the last tick says nothing about where the van is.
    private let anchorTime: Date?
    /// A departure to count from instead of now, for the one screen that
    /// asks "what if I leave at seven" — see `PlannedStart`. `nil` everywhere
    /// else.
    let plannedStart: Date?
    /// Whether the van has been anywhere yet: a door answered at the door, or
    /// the Lager or Ziel ticked. Not an abbestellt customer, who is ticked off
    /// the evening before when the office rings.
    let underWay: Bool
    /// What was learned from the tours already driven — see `PaceHistory`.
    private let history: PaceHistory
    /// Today's own door times, one per pair of doors ticked one after the
    /// other — what `pace` is measured from, and what `PaceHistory` collects.
    let doorSamples: [Double]

    /// Stops still to be ticked off: the open doors, plus Lager and Ziel while
    /// they are still ahead.
    let openCount: Int

    /// Whether the tour is finished — every stop ticked off, Lager and Ziel
    /// included, not every meal delivered.
    var isComplete: Bool { customerCount > 0 && openCount == 0 }

    /// Doors the driver has not reached yet — the customers alone, which is
    /// what the pace per door multiplies.
    var openDoors: Int { customerCount - settledCount }

    /// The meals this tour actually owes: every customer but the abbestellt
    /// ones. What "geliefert" is counted against, so two cancellations do not
    /// read as two failures.
    var owedCount: Int { customerCount - cancelledCount - lagerCount }

    /// "17 von 18 geliefert · 1 nicht angetroffen · 2 abbestellt" — the line
    /// over the stop list and over Jetzt.
    var deliveryLine: String {
        var parts = ["\(deliveredCount) von \(owedCount) geliefert"]
        if !followUps.isEmpty { parts.append("\(followUps.count) nicht angetroffen") }
        if cancelledCount > 0 { parts.append("\(cancelledCount) abbestellt") }
        if lagerCount > 0 { parts.append("\(lagerCount) ins Lager") }
        return parts.joined(separator: " · ")
    }

    func number(_ stop: Stop) -> Int? { numbers[stop.id] }
    func doorCount(_ stop: Stop) -> Int { doorCounts[stop.id] ?? 1 }

    /// How long a delivery takes, on foot, once the van has stopped.
    ///
    /// Driving time is the only thing OSRM knows, and on this round it is about
    /// half the day: the rest is parking, a Gemeindebau staircase, a locked
    /// Haustür, and two minutes with somebody who has not spoken to anybody
    /// else since yesterday. An arrival time built on driving alone is wrong by
    /// an hour by lunchtime, always in the same direction.
    ///
    /// So it is measured rather than assumed, off the day's own timestamps, and
    /// falls back to a figure that is merely plausible until there are enough
    /// of them to do better.
    struct Pace: Equatable {
        let minutesPerStop: Double
        /// `true` once today's own ticks are in it — which is the difference
        /// between "ca. 12:40" and a number worth putting on screen without a
        /// hedge.
        let measured: Bool
        /// `true` when the figure comes from tours driven before, rather than
        /// from the assumption every phone starts with.
        var learned = false

        /// Seven minutes a door, until this phone knows better. Measured, not
        /// guessed: across twelve tours of October 2026 the time between two
        /// ticks, less the drive between them, averaged a little under seven
        /// minutes. The four it used to be had every tour finishing an hour
        /// early on paper.
        static let assumedMinutes = 7.0
        static let assumed = Pace(minutesPerStop: assumedMinutes, measured: false)

        /// What a single door may count for in an average. A door that took
        /// forty minutes was a break, or a tick made late — real time, but not
        /// what the next door will take.
        static let cap = 15.0
        /// How many doors' worth the starting figure weighs against today's
        /// ticks: the first three doors of a day say little about the other
        /// twenty, and on those twelve tours trusting them sooner was worse.
        static let priorWeight = 8.0
        /// A second household at the same door, as a share of a door of its
        /// own: no parking, no second walk to the Haustür.
        static let sharedDoor = 0.55
        /// Loading at the Lager, until this phone has measured its own.
        static let lagerMinutes = 10.0
        /// The longest a tick is taken as "where the van is now".
        static let anchorMaxAge: TimeInterval = 90 * 60
    }

    init(
        _ route: Route, now: Date = Date(), history: PaceHistory = .current,
        plannedStart: Date? = nil
    ) {
        let ordered = route.orderedStops
        self.ordered = ordered
        self.history = history
        self.plannedStart = plannedStart
        self.underWay = ordered.contains {
            $0.countsAsStop && $0.isSettled && $0.outcome?.skipsDoor != true
        }

        var numbers: [UUID: Int] = [:]
        var customers = 0
        var delivered = 0
        var settled = 0
        var cancelled = 0
        var lager = 0
        var open = 0
        var next: Stop?
        var openEnd: Stop?
        var km = 0.0
        var minutes = 0.0
        var followUps: [Stop] = []
        var arrivals: [UUID: Double] = [:]
        var doorsBefore: [UUID: Double] = [:]
        var ownDoor: [UUID: Double] = [:]
        var doorsSoFar = 0.0
        // The Lager's loading is still ahead until the first door is answered
        // for — whether the Lager itself is ticked yet or not.
        let loaded = ordered.contains(where: \.passesLager)
        var loadingAhead = false
        var loadingBefore: Set<UUID> = []
        // The stop the van drove here from, for telling a shared door.
        var previousLeg: Double?
        var previousWasCustomer = false
        var anchor: Stop?
        // The legs already behind the driver: everything up to, but not
        // including, the leg leaving the last stop they settled. Captured
        // *before* this stop's own leg is added, so the drive out of that stop
        // still counts as ahead of them — they are standing at its door.
        var drivenKm = 0.0
        var drivenMinutes = 0.0

        for stop in ordered {
            // Before this stop's own leg is added, so it is the time the van
            // arrives here rather than the time it leaves.
            arrivals[stop.id] = minutes
            doorsBefore[stop.id] = doorsSoFar
            if loadingAhead { loadingBefore.insert(stop.id) }
            if stop.kind == .via, stop.isCheckpoint, !loaded { loadingAhead = true }

            if stop.kind == .customer {
                customers += 1
                numbers[stop.id] = customers
                if stop.delivered { delivered += 1 }
                if let outcome = stop.outcome {
                    settled += 1
                    if outcome == .cancelled { cancelled += 1 }
                    if outcome == .toLager { lager += 1 }
                    if outcome.needsFollowUp { followUps.append(stop) }
                }
            }
            if stop.countsAsStop {
                if stop.isSettled {
                    // Only while every stop up to here has been settled.
                    //
                    // Ticked off in order — the normal case, and the one every
                    // other test in `RouteSnapshotTests` describes — that is
                    // every settled stop in turn, and this is exactly what it
                    // always was. What it now refuses to do is let a delivery
                    // made *out* of order drag the mark forward past doors that
                    // are still owed. A customer met on the street and handed
                    // their meal twenty stops early used to move it to their
                    // position, so the screen paired "Noch 22 Stopps" with the
                    // four kilometres between stop 25 and the depot — a
                    // distance twenty-two doors cannot fit in, on the one line
                    // a driver plans the next hour from.
                    //
                    // What is left then covers the whole tour from the last
                    // point the plan was still being followed. That over-counts
                    // by however much of it the driver has already driven, and
                    // that is the deliberate direction: the real answer — "how
                    // far is it from where I am now, back to the doors I
                    // skipped, and on to the end" — is a re-routing problem
                    // this cannot solve from stored leg distances. Of the two
                    // ways to be wrong about it, telling a driver a tour is
                    // shorter than it is, at midday, with meals going cold, is
                    // the one that costs something.
                    //
                    // And never an abbestellt door. It is not driven at all —
                    // it sits in the list with no leg, after the doors that
                    // are — so it says nothing about where the van is. Taken
                    // as a position, one listed after the last delivery moved
                    // the mark past the drive home, and "Rückfahrt" vanished.
                    if next == nil && stop.outcome?.skipsDoor != true {
                        drivenKm = km
                        drivenMinutes = minutes
                        anchor = stop
                    }
                } else {
                    // Ziel waits for everything else, wherever it is listed: a
                    // tour that has not been optimized yet still shows it
                    // above the customers added after it.
                    if stop.kind == .end {
                        openEnd = stop
                    } else if next == nil {
                        next = stop
                    }
                    open += 1
                    if stop.kind == .customer {
                        let shared = previousWasCustomer && (previousLeg ?? 1) < 0.3
                        let weight = shared ? Pace.sharedDoor : 1
                        ownDoor[stop.id] = weight
                        doorsSoFar += weight
                    }
                }
            }
            // Only the legs actually driven count towards the tour's totals.
            guard stop.legIsDriven else { continue }
            km += stop.nextLegKm ?? 0
            minutes += stop.nextLegMin ?? 0
            if stop.outcome?.skipsDoor != true {
                previousLeg = stop.nextLegMin
                previousWasCustomer = stop.kind == .customer
            }
        }

        self.customerCount = customers
        self.deliveredCount = delivered
        self.settledCount = settled
        self.cancelledCount = cancelled
        self.lagerCount = lager
        // A tour with no customers yet has nothing to drive: its Lager and Ziel
        // are not a round to be started, just three points waiting for one.
        self.openCount = customers > 0 ? open : 0
        self.nextOpen = customers > 0 ? (next ?? openEnd) : nil
        self.numbers = numbers
        self.totalKm = km
        self.totalMinutes = minutes
        self.followUps = followUps
        self.arrivalMinutes = arrivals
        self.doorsBefore = doorsBefore
        self.ownDoor = ownDoor
        self.openDoorUnits = doorsSoFar
        self.loadingBefore = loadingBefore
        // Only a tick nothing was ticked after: with doors answered for out of
        // order, the last one in the list is not where the van is.
        let latest = ordered.lazy
            .filter { $0.countsAsStop && $0.isSettled && $0.outcome?.skipsDoor != true }
            .compactMap(\.settledAt).max()
        self.anchorTime = anchor?.settledAt.flatMap { $0 == latest ? $0 : nil }
        self.minutesDriven = drivenMinutes
        // Clamped: a route whose legs were written by two different
        // optimization runs can hold slightly inconsistent numbers, and a
        // negative "still to drive" is worse than a zero.
        self.remainingKm = max(0, km - drivenKm)
        self.remainingMinutes = max(0, minutes - drivenMinutes)
        // Not an abbestellt household: "2 an dieser Tür" is two meals carried
        // up, and a door owed nothing today is not one of them.
        self.doorCounts = SameDoor.counts(for: ordered.filter { $0.outcome?.skipsDoor != true })
        let samples = Self.doorSamples(ordered, arrivals: arrivals)
        self.doorSamples = samples
        self.pace = Self.measurePace(samples, learned: history.doorMinutes(forTour: route.name))
    }
}

// MARK: - When the driver gets there

extension RouteSnapshot {
    /// What each door took today: for every two doors ticked one after the
    /// other, the time between the ticks less the drive OSRM puts between
    /// them.
    ///
    /// Pair by pair rather than first tick to last, which is what this was:
    /// one lunch break, or one tick made the next morning, was then spread
    /// over every door of the day — a tour measured at 656 minutes a door,
    /// refused as implausible, and thrown back on the assumption.
    ///
    /// Left out: a pair ticked against the driving order, whose drive is not
    /// known; a gap of under half a minute, which is catching up on ticks at a
    /// red light; one of over three quarters of an hour, which is a break; and
    /// a second household at the same door, which is not a door of its own.
    ///
    /// Nor an abbestellt customer or a meal for the Lager. Nobody went to
    /// that door, and the tick is made whenever the office rings.
    static func doorSamples(_ ordered: [Stop], arrivals: [UUID: Double]) -> [Double] {
        let stamped = ordered
            .filter { $0.kind == .customer && $0.isSettled && $0.outcome?.skipsDoor != true }
            .compactMap { stop -> (at: Date, driving: Double)? in
                guard let at = stop.settledAt, let driving = arrivals[stop.id] else { return nil }
                return (at, driving)
            }
            .sorted { $0.at < $1.at }

        var samples: [Double] = []
        for (a, b) in zip(stamped, stamped.dropFirst()) {
            let gap = b.at.timeIntervalSince(a.at) / 60
            let drive = b.driving - a.driving
            guard (0.5...45).contains(gap), drive >= 0.3 else { continue }
            samples.append(max(0.5, gap - drive))
        }
        return samples
    }

    /// The minutes a door is counted at: today's own, pulled towards what the
    /// tours before it took (`learned`) — or towards the assumption, on a
    /// phone that has not driven any yet.
    ///
    /// A blend rather than a switch at three doors. The first doors of a day
    /// are a small sample of it, and a figure that jumped from the assumption
    /// to whatever they happened to take moved "fertig gegen" by an hour on
    /// the fourth tick.
    static func measurePace(_ samples: [Double], learned: Double? = nil) -> Pace {
        let prior = learned ?? Pace.assumedMinutes
        guard !samples.isEmpty else {
            return Pace(minutesPerStop: prior, measured: false, learned: learned != nil)
        }
        let today = samples.reduce(0) { $0 + min($1, Pace.cap) }
        let n = Double(samples.count)
        return Pace(
            minutesPerStop: (today + Pace.priorWeight * prior) / (n + Pace.priorWeight),
            measured: samples.count >= 3, learned: learned != nil)
    }

    /// Driving minutes from the start of the tour to this stop, as planned.
    func plannedMinutes(to stop: Stop) -> Double? { arrivalMinutes[stop.id] }

    /// Minutes from leaving where the van is to arriving at `stop`: the
    /// drive, the doors in front of it, and the loading if that is still
    /// ahead.
    private func minutesAhead(to stop: Stop) -> Double {
        let driving = max(0, (arrivalMinutes[stop.id] ?? 0) - minutesDriven)
        let doors = (doorsBefore[stop.id] ?? 0) * pace.minutesPerStop
        let loading = loadingBefore.contains(stop.id)
            ? (history.lagerMinutes ?? Pace.lagerMinutes) : 0
        return driving + doors + loading
    }

    /// When the van reaches the next stop and when it leaves it again — what
    /// every estimate behind it hangs on.
    ///
    /// Counted from the last tick rather than from now. Counted from now,
    /// which is what this did, the van was always just setting off: half way
    /// along a ten-minute drive the next door was still ten minutes away, and
    /// every estimate slid back a minute a minute until the next tick. The
    /// time since the last tick is time already spent on the way there.
    ///
    /// But never an arrival in the past. A driver who is later than the plan
    /// — a break, a queue at the Lager — is taken to be arriving now, so a
    /// morning that ran late still moves every remaining estimate with it.
    private func nextStopTimes(from now: Date) -> (stop: Stop, arrival: Date, departure: Date)? {
        guard let next = nextOpen else { return nil }
        let since = anchorTime.flatMap { tick in
            tick <= now && now.timeIntervalSince(tick) <= Pace.anchorMaxAge ? tick : nil
        } ?? now
        let planned = since.addingTimeInterval(minutesAhead(to: next) * 60)
        let door = (ownDoor[next.id] ?? 0) * pace.minutesPerStop
        // A minute at least, at a door the plan says the driver should
        // already have left: they have not ticked it yet.
        let departure = max(
            planned.addingTimeInterval(door * 60),
            now.addingTimeInterval(door > 0 ? 60 : 0))
        return (next, max(planned, now), departure)
    }

    /// The departure being asked about, while it is still ahead and the tour
    /// has not begun. Every estimate is then counted from there instead of
    /// from now — the evening before, "now" would have the van setting off at
    /// nine at night.
    ///
    /// `nil` once the first stop is ticked, when the ticks say where the van
    /// is, and once the time has passed: a driver who has not left by then is
    /// leaving now at the earliest.
    func pendingStart(from now: Date = Date()) -> Date? {
        guard !underWay, let plannedStart, plannedStart > now else { return nil }
        return plannedStart
    }

    /// How long the tour takes from setting off to the last point it drives
    /// to, in minutes — what `etaFinish` adds to the departure.
    func plannedDuration(from now: Date = Date()) -> Double? {
        guard let finish = etaFinish(from: now) else { return nil }
        return finish.timeIntervalSince(pendingStart(from: now) ?? now) / 60
    }

    /// When the van is expected at this stop.
    ///
    /// `nil` for a door already answered for — an arrival time for a delivery
    /// made an hour ago is noise — and `nil` for a route that has never been
    /// optimized, where every leg is zero and this would confidently promise
    /// all thirty customers their meal at the same minute.
    func eta(for stop: Stop, from now: Date = Date()) -> Date? {
        let now = pendingStart(from: now) ?? now
        guard totalMinutes > 0, !stop.isSettled, let arrival = arrivalMinutes[stop.id],
              let next = nextStopTimes(from: now)
        else { return nil }
        if stop.id == next.stop.id { return next.arrival }
        // Only for a point the van has not reached. Start carries no outcome
        // and so can never be "settled": without this the depot sat at
        // the top of the list all day promising an arrival of *now*. An
        // open door is always ahead, though — a second household at the door
        // the van is standing at has no drive in front of it and still has
        // an arrival time.
        guard stop.isOpenStop || arrival > minutesDriven else { return nil }
        let beyond = minutesAhead(to: stop) - minutesAhead(to: next.stop)
            - (ownDoor[next.stop.id] ?? 0) * pace.minutesPerStop
        return max(now, next.departure.addingTimeInterval(beyond * 60))
    }

    /// When the shift is expected to end: the last point the tour actually
    /// drives to, doors and all.
    func etaFinish(from now: Date = Date()) -> Date? {
        let now = pendingStart(from: now) ?? now
        guard totalMinutes > 0, openCount > 0, let next = nextStopTimes(from: now)
        else { return nil }
        // The loading too, while it is still ahead of any door.
        let loading = !loadingBefore.isEmpty && openDoorUnits > 0
            ? (history.lagerMinutes ?? Pace.lagerMinutes) : 0
        let whole = remainingMinutes + openDoorUnits * pace.minutesPerStop + loading
        let beyond = whole - minutesAhead(to: next.stop)
            - (ownDoor[next.stop.id] ?? 0) * pace.minutesPerStop
        return max(now, next.departure.addingTimeInterval(max(0, beyond) * 60))
    }
}

extension RouteSnapshot {
    /// The line under a tour's name: what is still ahead of the driver.
    ///
    /// "Noch 22 Stopps · 18,2 km" rather than "12 von 34 geliefert" — both are
    /// the same fact, but only one of them is the question anybody has at half
    /// past eleven. The progress count has its own place, over the list.
    ///
    /// Here rather than on either screen because two screens show it: the
    /// tour's own and Jetzt put the same tour under the same title, and must
    /// not describe it two ways.
    func summary(of route: Route) -> String {
        guard customerCount > 0 else { return "Noch keine Stopps" }
        // A finished tour is history, and history has no "still to drive". It
        // was answering "Noch 4 Stopps · 11,7 km" under a tour filed in
        // Erledigt — a forecast about a day that is over.
        guard route.status == .active else {
            let day = route.completedAt ?? route.createdAt
            let parts = [Format.date(day), Format.stops(customerCount), Format.km(totalKm)]
                .compactMap { $0 }
            return parts.joined(separator: " · ")
        }
        guard openCount > 0 else {
            guard let back = Format.km(remainingKm), remainingKm >= 0.05
            else { return "Alle erledigt" }
            return "Alle erledigt · Rückfahrt \(back)"
        }
        // Customers, not `openCount`: Lager and Ziel counted in made this "Noch
        // 28 Stopps" over a tour Touren lists as 26 and whose header reads
        // "0 von 26 geliefert" — three numbers for one tour on two screens.
        guard openDoors > 0 else {
            guard let back = Format.km(remainingKm), remainingKm >= 0.05
            else { return "Alle Kunden erledigt" }
            return "Alle Kunden erledigt · Rückfahrt \(back)"
        }
        let stops = "Noch \(Format.stops(openDoors))"
        guard let km = Format.km(remainingKm), remainingKm >= 0.05 else { return stops }
        return "\(stops) · \(km)"
    }
}
