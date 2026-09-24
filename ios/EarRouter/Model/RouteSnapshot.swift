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
    /// How many doors are still to be answered before each stop — the stairs
    /// between here and there, which driving time alone knows nothing about.
    private let openDoorsBefore: [UUID: Int]

    /// Stops still to be ticked off: the open doors, plus Lager and Ziel while
    /// they are still ahead.
    let openCount: Int

    /// Whether the tour is finished — every stop ticked off, Lager and Ziel
    /// included, not every meal delivered.
    var isComplete: Bool { customerCount > 0 && openCount == 0 }

    /// Doors the driver has not reached yet — the customers alone, which is
    /// what the pace per door multiplies.
    var openDoors: Int { customerCount - settledCount }

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
        /// `false` while this is still the assumption rather than today's
        /// measurement — which is the difference between "ca. 12:40" and a
        /// number worth putting on screen without a hedge.
        let measured: Bool

        /// Four minutes a door. Not a guess pulled out of the air: a tour of
        /// about thirty stops that takes a little over three hours, of which
        /// OSRM accounts for something over an hour of driving.
        static let assumed = Pace(minutesPerStop: 4, measured: false)

        /// The bounds anything measured is held inside. A tour where the first
        /// three stops were settled in one minute — a driver catching up on
        /// ticks at a red light — would otherwise promise the whole round by
        /// half past ten.
        static let plausible = 0.5...20.0
    }

    init(_ route: Route, now: Date = Date()) {
        let ordered = route.orderedStops
        self.ordered = ordered

        var numbers: [UUID: Int] = [:]
        var customers = 0
        var delivered = 0
        var settled = 0
        var open = 0
        var next: Stop?
        var openEnd: Stop?
        var km = 0.0
        var minutes = 0.0
        var followUps: [Stop] = []
        var arrivals: [UUID: Double] = [:]
        var openBefore: [UUID: Int] = [:]
        var openSoFar = 0
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
            openBefore[stop.id] = openSoFar

            if stop.kind == .customer {
                customers += 1
                numbers[stop.id] = customers
                if stop.delivered { delivered += 1 }
                if let outcome = stop.outcome {
                    settled += 1
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
                    if next == nil {
                        drivenKm = km
                        drivenMinutes = minutes
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
                    if stop.kind == .customer { openSoFar += 1 }
                }
            }
            // Only the legs actually driven count towards the tour's totals.
            guard !stop.excluded else { continue }
            km += stop.nextLegKm ?? 0
            minutes += stop.nextLegMin ?? 0
        }

        self.customerCount = customers
        self.deliveredCount = delivered
        self.settledCount = settled
        // A tour with no customers yet has nothing to drive: its Lager and Ziel
        // are not a round to be started, just three points waiting for one.
        self.openCount = customers > 0 ? open : 0
        self.nextOpen = customers > 0 ? (next ?? openEnd) : nil
        self.numbers = numbers
        self.totalKm = km
        self.totalMinutes = minutes
        self.followUps = followUps
        self.arrivalMinutes = arrivals
        self.openDoorsBefore = openBefore
        self.minutesDriven = drivenMinutes
        // Clamped: a route whose legs were written by two different
        // optimization runs can hold slightly inconsistent numbers, and a
        // negative "still to drive" is worse than a zero.
        self.remainingKm = max(0, km - drivenKm)
        self.remainingMinutes = max(0, minutes - drivenMinutes)
        // Not an abbestellt household: "2 an dieser Tür" is two meals carried
        // up, and a door owed nothing today is not one of them.
        self.doorCounts = SameDoor.counts(for: ordered.filter { $0.outcome != .cancelled })
        self.pace = Self.measurePace(ordered, arrivals: arrivals)
    }
}

// MARK: - When the driver gets there

extension RouteSnapshot {
    /// Today's own minutes-per-door, or the assumption while there is not yet
    /// enough of today to measure.
    ///
    /// Measured from the stops the driver has actually settled: the wall-clock
    /// time between the first and the last of them, less the driving OSRM says
    /// lies between the two, spread over the doors in between. Three settled
    /// stops is the floor — two gives one interval, and one interval is a
    /// coincidence rather than a pace.
    ///
    /// Stops carrying no `settledAt` are simply not in it. Every tour settled
    /// before that field existed is one of those, which is why the assumption
    /// has to be good enough to stand on its own.
    ///
    /// Nor is an abbestellt customer. Nobody went to that door, and the tick
    /// is made whenever the office rings — in the yard at half past seven, as
    /// often as not. Counted, it was a door with no time at it that also moved
    /// the start of the clock back to the yard: four deliveries two minutes
    /// apart at the door measured as twelve, and "fertig gegen" slid by hours.
    static func measurePace(_ ordered: [Stop], arrivals: [UUID: Double]) -> Pace {
        let stamped = ordered
            .filter { $0.kind == .customer && $0.isSettled && $0.outcome != .cancelled }
            .compactMap { stop -> (Date, Double)? in
                guard let at = stop.settledAt, let driving = arrivals[stop.id] else { return nil }
                return (at, driving)
            }
            .sorted { $0.0 < $1.0 }

        guard stamped.count >= 3, let first = stamped.first, let last = stamped.last
        else { return .assumed }

        let doors = Double(stamped.count - 1)
        let elapsed = last.0.timeIntervalSince(first.0) / 60
        // Negative when the ticks were made out of driving order, which happens
        // and is not worth refusing the whole measurement over.
        let driving = max(0, last.1 - first.1)
        let perStop = (elapsed - driving) / doors

        guard perStop.isFinite, Pace.plausible.contains(perStop) else { return .assumed }
        return Pace(minutesPerStop: perStop, measured: true)
    }

    /// When the van is expected at this stop.
    ///
    /// `nil` for a door already answered for — an arrival time for a delivery
    /// made an hour ago is noise — and `nil` for a route that has never been
    /// optimized, where every leg is zero and this would confidently promise
    /// all thirty customers their meal at the same minute.
    ///
    /// Counted from where the driver is now rather than from the start of the
    /// tour, so a morning that ran late moves every remaining estimate with it
    /// instead of quietly staying wrong all day.
    func eta(for stop: Stop, from now: Date = Date()) -> Date? {
        guard totalMinutes > 0, !stop.isSettled, let arrival = arrivalMinutes[stop.id]
        else { return nil }
        // Only for a point the van has not reached. Start carries no outcome
        // and so can never be "settled": without this the depot sat at
        // the top of the list all day promising an arrival of *now*, first
        // because the driver was standing in it and then, after four
        // deliveries, because the clamp below had nothing left to subtract.
        // An arrival time that is always the current time is not an estimate.
        guard arrival > minutesDriven || stop.id == nextOpen?.id else { return nil }
        let driving = max(0, arrival - minutesDriven)
        let doors = Double(openDoorsBefore[stop.id] ?? 0)
        return now.addingTimeInterval((driving + doors * pace.minutesPerStop) * 60)
    }

    /// When the shift is expected to end: the last point the tour actually
    /// drives to, doors and all.
    func etaFinish(from now: Date = Date()) -> Date? {
        guard totalMinutes > 0, openCount > 0 else { return nil }
        let doors = Double(openDoors) * pace.minutesPerStop
        return now.addingTimeInterval((remainingMinutes + doors) * 60)
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
