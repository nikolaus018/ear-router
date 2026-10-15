import Foundation

/// Tightens the stop order OSRM's `/trip` hands back.
///
/// `/trip` is a quick heuristic: it builds one tour by inserting the farthest
/// point next and stops there. Measured on 23 real tours (13.10.2026) that
/// left 2.7 % of the driving time on the table — three minutes on an ordinary
/// tour, twelve on the worst — because of doors visited on the way out that
/// are passed again on the way back.
///
/// This starts from OSRM's order and only ever moves to one that is shorter
/// by the server's own driving times, so the result is never worse than what
/// the app drove before. The moves are the two a person would make looking at
/// the map: pick up one to three neighbouring doors and drop them somewhere
/// else in the tour (either way round), and turn a stretch of the tour
/// around. When neither helps any more, a few doors are thrown somewhere
/// random and the same is tried again from there, keeping whichever tour is
/// shortest. On those 23 tours that lands within seconds of the best order a
/// search fifteen times as long could find.
///
/// Pure and deterministic: the same tour always comes back in the same order,
/// and nothing here touches the network or the store.
enum TourPolish {

    /// A shorter order has to save at least this much to be taken. Below it
    /// the difference is noise in the server's times, and rows trading places
    /// for nothing is its own cost.
    static let worthwhile: Double = 30

    /// The total driving time of `order`.
    static func cost(_ order: [Int], _ m: [[Double]]) -> Double {
        var sum = 0.0
        for i in 0..<max(0, order.count - 1) { sum += m[order[i]][order[i + 1]] }
        return sum
    }

    /// The best order found, or `order` itself when nothing is `worthwhile`.
    ///
    /// `order` holds indices into `durations`, where `durations[a][b]` is the
    /// drive from `a` to `b` — not the same as from `b` to `a`, in a city of
    /// one-way streets. `fixFirst` and `fixLast` keep the ends where they are,
    /// as they do for `/trip`.
    static func improve(
        order: [Int], durations m: [[Double]], fixFirst: Bool, fixLast: Bool
    ) -> [Int] {
        let n = order.count
        let lo = fixFirst ? 1 : 0
        let hi = fixLast ? n - 1 : n
        // Fewer than three movable doors and at least one fixed end: OSRM has
        // already tried every order there is.
        guard hi - lo >= 3, m.count >= n, m.allSatisfy({ $0.count >= n }),
              Set(order).count == n, order.allSatisfy({ $0 >= 0 && $0 < m.count })
        else { return order }

        let given = cost(order, m)
        var best = order
        var bestCost = settle(&best, m, lo, hi)

        // Kicks grow with the tour, capped so a hundred doors still answer in
        // well under a second.
        var random = SplitMix(seed: 0x45_41_52)
        let kicks = min(60, max(20, 4_000 / n))
        for _ in 0..<kicks {
            var trial = best
            for _ in 0..<3 {
                let len = Int(random.next() % 3) + 1
                guard hi - lo > len else { break }
                let from = lo + Int(random.next() % UInt64(hi - lo - len + 1))
                let segment = Array(trial[from..<from + len])
                trial.removeSubrange(from..<from + len)
                let to = lo + Int(random.next() % UInt64(hi - len - lo + 1))
                trial.insert(contentsOf: segment, at: to)
            }
            let trialCost = settle(&trial, m, lo, hi)
            if trialCost < bestCost - 1e-6 {
                best = trial
                bestCost = trialCost
            }
        }

        return given - bestCost >= worthwhile ? best : order
    }

    /// Makes improving moves on `o[lo..<hi]` until there are none, and returns
    /// what the tour then costs. `SplitPlanner` uses it on every share it
    /// tries; it needs `hi - lo >= 1`.
    static func settle(_ o: inout [Int], _ m: [[Double]], _ lo: Int, _ hi: Int) -> Double {
        let n = o.count
        // The drive between two neighbours, where an end of the tour has no
        // neighbour and costs nothing.
        func e(_ a: Int?, _ b: Int?) -> Double {
            guard let a, let b else { return 0 }
            return m[a][b]
        }
        func at(_ i: Int) -> Int? { i >= 0 && i < n ? o[i] : nil }

        var improved = true
        while improved {
            improved = false

            // Move one to three neighbouring doors somewhere else.
            relocate: for len in 1...3 where hi - lo > len {
                for i in lo...(hi - len) {
                    let first = o[i], last = o[i + len - 1]
                    var inside = 0.0, insideBack = 0.0
                    for k in i..<(i + len - 1) {
                        inside += m[o[k]][o[k + 1]]
                        insideBack += m[o[k + 1]][o[k]]
                    }
                    let before = at(i - 1), after = at(i + len)
                    let freed = e(before, first) + inside + e(last, after) - e(before, after)
                    guard freed > 1e-6 else { continue }

                    // `j` is the gap in the tour without the segment: between
                    // its `j - 1` and its `j`.
                    func without(_ k: Int) -> Int? {
                        let index = k < i ? k : k + len
                        return index >= 0 && index < n ? o[index] : nil
                    }
                    for j in lo...(hi - len) where j != i {
                        let p = without(j - 1), q = without(j)
                        let gap = e(p, q)
                        let forward = e(p, first) + inside + e(last, q) - gap
                        let backward = e(p, last) + insideBack + e(first, q) - gap
                        let added = min(forward, backward)
                        guard added < freed - 1e-6 else { continue }
                        var segment = Array(o[i..<i + len])
                        if backward < forward { segment.reverse() }
                        o.removeSubrange(i..<i + len)
                        o.insert(contentsOf: segment, at: j)
                        improved = true
                        break relocate
                    }
                }
            }
            if improved { continue }

            // Turn a stretch of the tour around. Driving times are per
            // direction, so the stretch itself costs something else backwards:
            // running sums both ways make that one subtraction.
            var forward = [Double](repeating: 0, count: n)
            var backward = [Double](repeating: 0, count: n)
            for k in 1..<n {
                forward[k] = forward[k - 1] + m[o[k - 1]][o[k]]
                backward[k] = backward[k - 1] + m[o[k]][o[k - 1]]
            }
            turn: for i in lo..<(hi - 1) {
                for j in (i + 1)..<hi {
                    let before = at(i - 1), after = at(j + 1)
                    let now = e(before, o[i]) + (forward[j] - forward[i]) + e(o[j], after)
                    let then = e(before, o[j]) + (backward[j] - backward[i]) + e(o[i], after)
                    guard then < now - 1e-6 else { continue }
                    o[i...j].reverse()
                    improved = true
                    break turn
                }
            }
        }
        return cost(o, m)
    }

    /// A fixed-seed generator, so one tour never comes back in two orders.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
