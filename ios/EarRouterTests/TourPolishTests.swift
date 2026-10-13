import Testing
import Foundation
@testable import EarRouter

/// The second look at OSRM's stop order.
struct TourPolishTests {

    /// Driving times that differ by direction, like a city of one-way streets.
    private func city(_ n: Int, seed: UInt64) -> [[Double]] {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 31)
        }
        let points = (0..<n).map { _ in (next(), next()) }
        return points.map { a in
            points.map { b in
                (abs(a.0 - b.0) + abs(a.1 - b.1)) * 1_800 * (0.8 + 0.4 * next())
            }
        }
    }

    /// Every order of the doors between two fixed ends, the slow way.
    private func cheapest(_ n: Int, _ m: [[Double]]) -> Double {
        var best = Double.infinity
        func walk(_ order: [Int], _ left: [Int]) {
            if left.isEmpty {
                best = min(best, TourPolish.cost(order + [n - 1], m))
                return
            }
            for (i, door) in left.enumerated() {
                var rest = left
                rest.remove(at: i)
                walk(order + [door], rest)
            }
        }
        walk([0], Array(1..<(n - 1)))
        return best
    }

    @Test func findsTheBestOrderOfASmallTour() {
        for seed in 1...12 as ClosedRange<UInt64> {
            let n = 9
            let m = city(n, seed: seed)
            let out = TourPolish.improve(
                order: Array(0..<n), durations: m, fixFirst: true, fixLast: true)
            // Within the gain it declines to reorder for.
            #expect(TourPolish.cost(out, m) - cheapest(n, m) < TourPolish.worthwhile + 0.001)
        }
    }

    @Test func keepsEveryDoorAndBothEnds() {
        let n = 40
        let m = city(n, seed: 7)
        let given = Array(0..<n)
        let out = TourPolish.improve(order: given, durations: m, fixFirst: true, fixLast: true)
        #expect(out.sorted() == given)
        #expect(out.first == 0)
        #expect(out.last == n - 1)
        #expect(TourPolish.cost(out, m) < TourPolish.cost(given, m))
    }

    @Test func anOpenEndMayMove() {
        // Four doors on a line, listed so the tour doubles back.
        let at: [Double] = [0, 3, 1, 2]
        let m = at.map { a in at.map { b in abs(a - b) * 600 } }
        let out = TourPolish.improve(
            order: [0, 1, 2, 3], durations: m, fixFirst: true, fixLast: false)
        #expect(out == [0, 2, 3, 1])
    }

    @Test func leavesAnOrderAloneForSeconds() {
        // Doors on a line, seconds apart: putting the middle two the other
        // way round would save twenty.
        let at: [Double] = [0, 20, 10, 30, 40]
        let m5: [[Double]] = at.map { a in at.map { b in abs(a - b) } }
        let given = [0, 1, 2, 3, 4]
        #expect(
            TourPolish.improve(order: given, durations: m5, fixFirst: true, fixLast: true)
                == given)
    }

    @Test func isTheSameEveryTime() {
        let m = city(30, seed: 3)
        let given = Array(0..<30)
        let a = TourPolish.improve(order: given, durations: m, fixFirst: true, fixLast: true)
        let b = TourPolish.improve(order: given, durations: m, fixFirst: true, fixLast: true)
        #expect(a == b)
    }

    @Test func refusesATableThatDoesNotFit() {
        let given = [0, 1, 2, 3, 4]
        #expect(
            TourPolish.improve(
                order: given, durations: city(4, seed: 1), fixFirst: true, fixLast: true)
                == given)
    }
}
