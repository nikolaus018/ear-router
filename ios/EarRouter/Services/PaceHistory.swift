import Foundation
import SwiftData

/// What the tours already driven say about the next one: how long a door
/// takes, and how long the loading at the Lager does.
///
/// Every finished tour on the phone carries the time of each tick, and until
/// this existed none of it was used: each morning started again from one
/// assumed figure, on a round whose doors take the same driver much the same
/// time every week. Measured against twelve of those tours, starting from
/// their own history instead of the assumption brought "fertig gegen", as
/// read in the yard, from an hour early on average to within a few minutes of
/// even — though any single day still lands half an hour either side.
///
/// Nothing is stored for it. It is worked out from the tours themselves when
/// the app starts and when one is finished, so deleting a tour takes what it
/// taught along with it.
struct PaceHistory: Equatable, Sendable {
    /// Minutes a door took, across the tours learned from. `nil` until there
    /// are enough ticks to say.
    var doorMinutes: Double?
    /// Minutes between ticking the Lager and driving off from it.
    var lagerMinutes: Double?

    static let none = PaceHistory()

    /// The tours it is learned from: the most recent, so a change of round or
    /// of season is caught up with inside a few weeks.
    static let tours = 30
    /// The fewest door times worth calling a history.
    static let fewestSamples = 10

    // MARK: - What is in use

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = PaceHistory()

    /// A lock rather than an actor: `RouteSnapshot` reads this from a view
    /// body and cannot wait for it.
    static var current: PaceHistory {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Learns again from the store and puts the result in use.
    @MainActor
    static func refresh(in context: ModelContext) {
        var finished = FetchDescriptor<Route>(
            predicate: #Predicate { $0.statusRaw == "completed" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        finished.fetchLimit = tours
        guard let routes = try? context.fetch(finished) else { return }
        current = learn(from: routes)
    }

    // MARK: - Learning

    /// Only finished tours: one still being driven is its own measurement —
    /// see `RouteSnapshot.measurePace` — and must not be counted twice.
    @MainActor
    static func learn(from routes: [Route]) -> PaceHistory {
        var doors: [Double] = []
        var waits: [Double] = []

        for route in routes where route.status == .completed {
            let snapshot = RouteSnapshot(route, history: .none)
            doors.append(contentsOf: snapshot.doorSamples)
            if let wait = lagerWait(in: snapshot) { waits.append(wait) }
        }

        var learned = PaceHistory()
        guard doors.count >= fewestSamples else { return learned }
        let door = doors.reduce(0) { $0 + min($1, RouteSnapshot.Pace.cap) } / Double(doors.count)
        learned.doorMinutes = min(max(door, 2), RouteSnapshot.Pace.cap)

        // What is left of the wait once the first door's own time is taken
        // off it. The median, because one morning spent waiting for the
        // kitchen is not what the next one will be.
        let loading = waits.map { $0 - door }.filter { (-5...90).contains($0) }
            .map { max(0, $0) }.sorted()
        if loading.count >= 2 { learned.lagerMinutes = loading[loading.count / 2] }
        return learned
    }

    /// Minutes from the Lager's tick to the first door's, less the drive
    /// between them. `nil` where the Lager was ticked by that first door — see
    /// `RouteStore.tickLagerIfPassed` — which is no measurement of anything.
    @MainActor
    private static func lagerWait(in snapshot: RouteSnapshot) -> Double? {
        guard let lager = snapshot.ordered.first(where: { $0.kind == .via && $0.isCheckpoint }),
              let loadedAt = lager.settledAt,
              let first = snapshot.ordered
                .filter({ $0.passesLager && $0.settledAt != nil })
                .min(by: { ($0.settledAt ?? .distantFuture) < ($1.settledAt ?? .distantFuture) }),
              let firstAt = first.settledAt, firstAt > loadedAt,
              let from = snapshot.plannedMinutes(to: lager),
              let to = snapshot.plannedMinutes(to: first), to >= from
        else { return nil }
        return firstAt.timeIntervalSince(loadedAt) / 60 - (to - from)
    }
}
