import Foundation

/// Shares a tour's doors out between several drivers so that nobody's day is
/// longer than it has to be — the fair split, worked out rather than drawn.
///
/// Fair is counted in what the day takes, not in doors. Twelve doors in one
/// Gemeindebau are a morning; twelve spread over Floridsdorf are a day. So a
/// driver's day here is the drive from the Lager round their own doors and
/// back to the Ziel, by OSRM's times, plus what every one of those doors
/// takes — see `SplitState.fairSplitInput` for where those come from.
///
/// For `Objective.fair`, what is made as small as it can be is the sum of everybody's day squared,
/// plus the longest day squared once more for every person. One number for
/// three wishes, in that order: the longest day as short as it can be, the
/// others as even as they can be, and no more driving than that needs. A
/// move that takes ten minutes off the longest day by giving two others a few
/// minutes more is taken; one that evens two days out by adding an hour of
/// driving between them is not.
///
/// And efficient, not only even: the split screen asks for
/// `Objective.fairAndEfficient`, which spends a minute more altogether only
/// where it takes at least a minute off the gap between the longest day and
/// the shortest — see `gapWeight`. Everybody sharing the tour drives from
/// the Lager to the Ziel whatever they are given, so that leg is part of
/// everybody's day — nobody is ever sent home with no doors to make the
/// numbers come out.
///
/// A door that already belongs to somebody — drawn round by hand before the
/// planner was asked — stays theirs, and counts towards their day: the rest
/// is shared out around it.
///
/// How: several starts, each built by handing out first the door whose
/// second-best home is the worst (regret insertion), then improved by moving
/// one door to another person and by swapping two between them, every
/// person's order kept tight with `TourPolish`'s moves. When nothing improves
/// any more, a few doors are shaken loose and the search goes on from there,
/// keeping the best split seen. Deterministic: the same tour and the same
/// doors always come back split the same way, unless `deadline` cut it short.
enum SplitPlanner {

    /// One thing to hand out: where the van parks — see `ParkingStops` —
    /// with every door and household delivered from there.
    struct Door: Sendable, Equatable {
        /// Index into the drive matrix handed to `plan`.
        let point: Int
        /// Seconds spent there, every door and household included.
        let seconds: Double
        /// Who it already belongs to. Such a door is never moved.
        let owner: Int?
    }

    /// One person's share.
    struct Day: Sendable, Equatable {
        /// Indices into the `doors` handed in, in the order they are driven.
        var doors: [Int]
        /// From the Lager round the doors to the Ziel; for somebody with no
        /// doors, the Lager to the Ziel.
        var drivingSeconds: Double
        var doorSeconds: Double
        var seconds: Double { drivingSeconds + doorSeconds }
    }

    /// How long the phone may think before it says what it found. A split is
    /// made once, in the depot, for a whole morning's work: a few seconds of
    /// search there are minutes on the road for somebody.
    static let thinkingTime: TimeInterval = 4

    /// Where every share starts and ends, in the matrix handed in.
    static let lagerPoint = 0
    static let zielPoint = 1

    /// The fairest split found that is also efficient — see `Objective`.
    ///
    /// `durations[a][b]` is the drive from point `a` to point `b` in seconds;
    /// `lagerPoint` and `zielPoint` must be in it. `rounds` is how many times
    /// the search shakes the best split loose and tries again; `deadline`
    /// stops it early on a slow phone, with the best split found so far.
    static func plan(
        doors: [Door], people: Int, durations: [[Double]],
        objective: Objective = .fairAndEfficient,
        rounds: Int = 600, deadline: Date = .distantFuture
    ) -> [Day] {
        guard people > 0 else { return [] }
        switch objective {
        case .fair, .leastTotal:
            return Engine(doors: doors, people: people, durations: durations, objective: objective)
                .solve(rounds: rounds, deadline: deadline)
        case .fairAndEfficient:
            // The most efficient split first, in part of the time, as the
            // first start of the search proper — so the answer is never
            // worse by its own measure than simply the most efficient one.
            let now = Date()
            let first = min(deadline, now.addingTimeInterval(
                max(0.2, deadline.timeIntervalSince(now) * 0.35)))
            let efficient = Engine(
                doors: doors, people: people, durations: durations, objective: .leastTotal)
                .solve(rounds: rounds, deadline: first)
            return Engine(doors: doors, people: people, durations: durations, objective: objective)
                .solve(rounds: rounds, deadline: deadline, from: efficient.map(\.doors))
        }
    }

    /// What the search makes small.
    enum Objective: Sendable, Equatable {
        /// What the split screen asks for: the time everybody spends
        /// altogether, plus `gapWeight` times the gap between the longest day
        /// and the shortest. A minute more altogether is spent only where it
        /// takes at least a minute off that gap.
        case fairAndEfficient
        /// The longest day, then the evenest days, then the least driving —
        /// see the type's own description — at whatever it costs.
        case fair
        /// Only the time everybody spends altogether, with every person
        /// given at least one door while there are enough. The most
        /// efficient split, whoever it is unfair to.
        case leastTotal
    }

    /// What a minute off the gap between the longest and the shortest day
    /// is worth in minutes altogether: one.
    ///
    /// Measured on the 25 tours of the 13.10.2026 backup. The most efficient
    /// split is never one anybody would drive — 190 minutes against 44 is
    /// typical, the van that goes far getting everything out there — and
    /// evening the days out completely cost 3.7 minutes altogether for two
    /// people and 7.2 for three, but up to 19. A fixed cap of a few minutes
    /// was tried first and was wrong exactly there: where evening out cost
    /// twelve minutes, the cap could not pay for it and handed back the 190
    /// against 44. At one to one, a gap of two hours is always worth closing
    /// and nobody is sent on a detour to shave the last minutes off one.
    static let gapWeight = 1.0

    /// What a split made by hand comes to: each person's doors in the
    /// shortest order found, and how long their day is.
    static func evaluate(
        _ shares: [[Int]], doors: [Door], durations: [[Double]]
    ) -> [Day] {
        let engine = Engine(doors: doors, people: shares.count, durations: durations)
        return shares.map { engine.day(engine.ordered($0)) }
    }

    // MARK: - The search

    /// Everything indexed locally: door `d` is matrix point `d + 2`, the Lager
    /// is 0 and the Ziel 1, in a matrix cut down to just those.
    private struct Engine {
        let m: [[Double]]
        let service: [Double]
        let owner: [Int?]
        let people: Int
        let objective: Objective
        let free: [Int]
        /// Each door's nearest others, closest first: the only partners a
        /// swap is tried with. A door in Liesing is not swapped for one in
        /// Floridsdorf.
        let neighbours: [[Int]]

        static let neighbourCount = 12

        init(doors: [Door], people: Int, durations: [[Double]], objective: Objective = .fair) {
            self.objective = objective
            let points = [SplitPlanner.lagerPoint, SplitPlanner.zielPoint] + doors.map(\.point)
            m = points.map { a in points.map { b in a == b ? 0 : max(0, durations[a][b]) } }
            service = doors.map { max(0, $0.seconds) }
            // An owner outside the people asked for — fewer people than when
            // the doors were drawn — is no owner.
            let owner = doors.map { door in door.owner.flatMap { (0..<people).contains($0) ? $0 : nil } }
            self.owner = owner
            self.people = people
            free = doors.indices.filter { owner[$0] == nil }

            let m = self.m
            neighbours = doors.indices.map { d in
                doors.indices.filter { $0 != d }
                    .sorted { (m[d + 2][$0 + 2] + m[$0 + 2][d + 2]) < (m[d + 2][$1 + 2] + m[$1 + 2][d + 2]) }
                    .prefix(Self.neighbourCount).map { $0 }
            }
        }

        // MARK: Days

        /// From the Lager round `r` to the Ziel. A person with no doors still
        /// drives the one without: everybody sharing the tour goes home, so
        /// that leg is part of everybody's day and never a saving.
        func drive(_ r: [Int]) -> Double {
            guard let first = r.first, let last = r.last else { return m[0][1] }
            var s = m[0][first + 2] + m[last + 2][1]
            for k in 1..<r.count { s += m[r[k - 1] + 2][r[k] + 2] }
            return s
        }

        func day(_ r: [Int]) -> Day {
            Day(doors: r, drivingSeconds: drive(r), doorSeconds: r.reduce(0) { $0 + service[$1] })
        }

        /// The cheapest place for `d` in `r`, and what it adds to the drive.
        func insertion(_ d: Int, into r: [Int]) -> (delta: Double, at: Int) {
            let x = d + 2
            var best = (delta: Double.infinity, at: 0)
            var prev = 0
            for k in 0...r.count {
                let next = k < r.count ? r[k] + 2 : 1
                let delta = m[prev][x] + m[x][next] - m[prev][next]
                if delta < best.delta { best = (delta, k) }
                prev = next
            }
            return best
        }

        /// What taking the door at `i` out of `r` saves on the drive.
        func removal(at i: Int, in r: [Int]) -> Double {
            let x = r[i] + 2
            let prev = i > 0 ? r[i - 1] + 2 : 0
            let next = i < r.count - 1 ? r[i + 1] + 2 : 1
            return m[prev][x] + m[x][next] - m[prev][next]
        }

        /// `r` in a tight order, by `TourPolish`'s own moves.
        func settled(_ r: [Int]) -> [Int] {
            guard r.count >= 2 else { return r }
            var o = [0] + r.map { $0 + 2 } + [1]
            _ = TourPolish.settle(&o, m, 1, o.count - 1)
            return o.dropFirst().dropLast().map { $0 - 2 }
        }

        /// Doors put in one by one at their cheapest place, then tightened.
        func ordered(_ doors: [Int]) -> [Int] {
            var r: [Int] = []
            for d in doors {
                let at = insertion(d, into: r).at
                r.insert(d, at: at)
            }
            return settled(r)
        }

        /// The finished order: `TourPolish` with its shakes, as a tour gets.
        func polished(_ r: [Int]) -> [Int] {
            guard r.count >= 3 else { return r }
            let o = [0] + r.map { $0 + 2 } + [1]
            let better = TourPolish.improve(order: o, durations: m, fixFirst: true, fixLast: true)
            return better.dropFirst().dropLast().map { $0 - 2 }
        }

        // MARK: The number being made small

        func cost(_ work: [Double]) -> Double {
            // A person with nothing is a split into fewer people: cheaper,
            // and not what was asked. Priced above anything else, while
            // there are doors enough to go round.
            let idle = free.count >= people
                ? Double(work.filter { $0 <= m[0][1] + 1e-6 }.count) * 1e15 : 0
            switch objective {
            case .fair:
                var sum = 0.0, longest = 0.0
                for w in work {
                    sum += w * w
                    longest = max(longest, w)
                }
                return sum + Double(people) * longest * longest + idle
            case .leastTotal:
                return work.reduce(0, +) + idle
            case .fairAndEfficient:
                var total = 0.0, longest = -Double.infinity, shortest = Double.infinity, squares = 0.0
                for w in work {
                    total += w
                    longest = max(longest, w)
                    shortest = min(shortest, w)
                    squares += w * w
                }
                // The squares only break ties: of two splits alike in total
                // and gap, the one whose middle days are evener.
                return total + SplitPlanner.gapWeight * (longest - shortest) + squares * 1e-9 + idle
            }
        }

        struct Split {
            var routes: [[Int]]
            var work: [Double]
            var cost: Double
        }

        func split(_ routes: [[Int]]) -> Split {
            let work = routes.map { day($0).seconds }
            return Split(routes: routes, work: work, cost: cost(work))
        }

        // MARK: Building one

        func construct(seed: UInt64) -> Split {
            var random = TourPolish.SplitMix(seed: seed)
            var routes = [[Int]](repeating: [], count: people)
            for d in owner.indices {
                if let p = owner[d] {
                    let at = insertion(d, into: routes[p]).at
                    routes[p].insert(d, at: at)
                }
            }
            routes = routes.map(settled)

            var left = Set(free)
            // Everyone with nothing yet starts from a door far from every
            // door already handed out — far from the Lager for the first —
            // so the shares begin in different corners of the tour.
            for p in 0..<people where routes[p].isEmpty && !left.isEmpty {
                let taken = routes.flatMap { $0 }
                func spread(_ d: Int) -> Double {
                    guard !taken.isEmpty else { return m[0][d + 2] + m[d + 2][1] }
                    return taken.map { m[$0 + 2][d + 2] + m[d + 2][$0 + 2] }.min() ?? 0
                }
                let ranked = left.sorted { (spread($0), $1) > (spread($1), $0) }
                // The first start always takes the farthest; the others one of
                // the three farthest, so they do not all begin alike.
                let pick = seed == 0 ? ranked[0] : ranked[Int(random.next() % UInt64(min(3, ranked.count)))]
                routes[p] = [pick]
                left.remove(pick)
            }

            var work = routes.map { day($0).seconds }
            // Regret: the door with most to lose by not going to its best
            // person goes first, while that person still has room.
            while !left.isEmpty {
                let base = cost(work)
                var chosen: (door: Int, person: Int, at: Int, regret: Double, gain: Double)?
                for d in left.sorted() {
                    var best = (cost: Double.infinity, person: 0, at: 0)
                    var second = Double.infinity
                    for p in 0..<people {
                        let ins = insertion(d, into: routes[p])
                        var w = work
                        w[p] += ins.delta + service[d]
                        let c = cost(w) - base
                        if c < best.cost {
                            second = best.cost
                            best = (c, p, ins.at)
                        } else if c < second {
                            second = c
                        }
                    }
                    let regret = second.isFinite ? second - best.cost : 0
                    if chosen == nil || regret > chosen!.regret + 1e-9
                        || (abs(regret - chosen!.regret) <= 1e-9 && best.cost < chosen!.gain)
                    {
                        chosen = (d, best.person, best.at, regret, best.cost)
                    }
                }
                guard let chosen else { break }
                routes[chosen.person].insert(chosen.door, at: chosen.at)
                routes[chosen.person] = settled(routes[chosen.person])
                work[chosen.person] = day(routes[chosen.person]).seconds
                left.remove(chosen.door)
            }
            return split(routes)
        }

        // MARK: Making it better

        /// Moves and swaps until neither helps any more.
        func improve(_ s: inout Split, deadline: Date) {
            var improved = true
            var passes = 0
            while improved, passes < 200, Date() < deadline {
                improved = false
                passes += 1
                var whose = [Int](repeating: -1, count: owner.count)
                for (p, r) in s.routes.enumerated() { for d in r { whose[d] = p } }

                // One door to somebody else.
                for d in free {
                    let a = whose[d]
                    guard a >= 0, let i = s.routes[a].firstIndex(of: d) else { continue }
                    let saved = removal(at: i, in: s.routes[a]) + service[d]
                    var best: (person: Int, at: Int, cost: Double)?
                    for b in 0..<people where b != a {
                        let ins = insertion(d, into: s.routes[b])
                        var w = s.work
                        w[a] -= saved
                        w[b] += ins.delta + service[d]
                        let c = cost(w)
                        if c < (best?.cost ?? s.cost) - 1 { best = (b, ins.at, c) }
                    }
                    guard let best else { continue }
                    s.routes[a].remove(at: i)
                    s.routes[best.person].insert(d, at: best.at)
                    apply(&s, touched: [a, best.person])
                    whose[d] = best.person
                    improved = true
                }

                // Two neighbouring doors trade places.
                for d in free {
                    let a = whose[d]
                    guard a >= 0 else { continue }
                    for e in neighbours[d] where owner[e] == nil {
                        let b = whose[e]
                        guard b >= 0, b != a,
                              let i = s.routes[a].firstIndex(of: d),
                              let j = s.routes[b].firstIndex(of: e)
                        else { continue }
                        var ra = s.routes[a], rb = s.routes[b]
                        let da = drive(ra) - removal(at: i, in: ra)
                        let db = drive(rb) - removal(at: j, in: rb)
                        ra.remove(at: i)
                        rb.remove(at: j)
                        let ia = insertion(e, into: ra), ib = insertion(d, into: rb)
                        var w = s.work
                        w[a] = da + ia.delta + ra.reduce(0) { $0 + service[$1] } + service[e]
                        w[b] = db + ib.delta + rb.reduce(0) { $0 + service[$1] } + service[d]
                        // `da` for a share emptied by the removal is its
                        // whole drive gone, which `removal` already counts.
                        let c = cost(w)
                        guard c < s.cost - 1 else { continue }
                        ra.insert(e, at: ia.at)
                        rb.insert(d, at: ib.at)
                        s.routes[a] = ra
                        s.routes[b] = rb
                        apply(&s, touched: [a, b])
                        whose[d] = b
                        whose[e] = a
                        improved = true
                        break
                    }
                }
            }
        }

        /// Tightens the shares that changed and counts the split again.
        func apply(_ s: inout Split, touched: [Int]) {
            for p in Set(touched) {
                s.routes[p] = settled(s.routes[p])
                s.work[p] = day(s.routes[p]).seconds
            }
            s.cost = cost(s.work)
        }

        /// A few doors thrown to somebody else, to get out of a split no
        /// single move or swap improves.
        func shaken(_ s: Split, _ random: inout TourPolish.SplitMix) -> Split {
            var routes = s.routes
            guard !free.isEmpty else { return s }
            let count = min(free.count, 2 + Int(random.next() % UInt64(max(1, free.count / 8))))
            var loose: [Int] = []
            // A door and its neighbours: a corner of the map changes hands,
            // which is the change one door at a time cannot make.
            let centre = free[Int(random.next() % UInt64(free.count))]
            for d in [centre] + neighbours[centre] where owner[d] == nil && loose.count < count {
                loose.append(d)
            }
            for p in routes.indices { routes[p].removeAll { loose.contains($0) } }
            let target = Int(random.next() % UInt64(people))
            for d in loose {
                // Mostly to one person together; now and then each its own way.
                let p = random.next() % 4 == 0 ? Int(random.next() % UInt64(people)) : target
                let at = insertion(d, into: routes[p]).at
                routes[p].insert(d, at: at)
            }
            return split(routes.map(settled))
        }

        func solve(rounds: Int, deadline: Date, from given: [[Int]]? = nil) -> [Day] {
            guard !free.isEmpty else {
                return (0..<people).map { p in day(ordered(owner.indices.filter { owner[$0] == p })) }
            }
            let starts = 4
            var best: Split?
            var random = TourPolish.SplitMix(seed: 0x5350_4C49_54)
            for start in 0..<starts {
                guard best == nil || Date() < deadline else { break }
                // A split handed in is the first start, as it is.
                var current = start == 0 && given?.count == people
                    ? split(given!) : construct(seed: UInt64(start))
                improve(&current, deadline: deadline)
                if best == nil || current.cost < best!.cost { best = current }
                for _ in 0..<(max(0, rounds) / starts) {
                    guard Date() < deadline else { break }
                    var trial = shaken(current, &random)
                    improve(&trial, deadline: deadline)
                    if trial.cost < best!.cost - 1 { best = trial }
                    // Carried on from even when a little worse than the best,
                    // so the search can walk across a ridge to a better one.
                    if trial.cost < best!.cost * 1.01 { current = trial }
                }
            }
            return best!.routes.map { day(polished($0)) }
        }
    }
}
