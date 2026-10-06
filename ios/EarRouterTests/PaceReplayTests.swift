import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// Replays the finished tours of a backup file against the arrival estimates:
/// each tour is wound back to after its first tick, its second, and so on,
/// and what the app would have said then is held against when each door was
/// really ticked.
///
/// Off unless `PACE_BACKUP` names a backup file (pass it with a
/// `TEST_RUNNER_` prefix). It asserts nothing: it prints how far off the
/// estimates are, for judging a change to them against real days.
@MainActor
struct PaceReplayTests {
    nonisolated static var backupPath: String? { ProcessInfo.processInfo.environment["PACE_BACKUP"] }

    @Test(.enabled(if: PaceReplayTests.backupPath != nil))
    func replay() throws {
        let path = try #require(Self.backupPath)
        let archive = try BackupArchive.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        let context = ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        try BackupRestore.apply(archive, mode: .replace, in: context)

        let routes = try context.fetch(FetchDescriptor<Route>(sortBy: [SortDescriptor(\.createdAt)]))
        var stopErrors: [Double] = [], finishErrors: [Double] = [], startErrors: [Double] = []

        for (index, route) in routes.enumerated() {
            let driven = route.stops
                .filter { $0.passesLager && $0.settledAt != nil }
                .sorted { ($0.settledAt ?? .distantPast) < ($1.settledAt ?? .distantPast) }
            // One sitting: what was ticked after a two-hour gap is another day.
            var session: [Stop] = []
            for stop in driven {
                if let last = session.last?.settledAt, let at = stop.settledAt,
                   at.timeIntervalSince(last) > 2 * 3600 { break }
                session.append(stop)
            }
            guard session.count >= 10, let end = session.last?.settledAt else { continue }
            let truth = Dictionary(
                uniqueKeysWithValues: session.compactMap { s in s.settledAt.map { (s.id, $0) } })
            let outcomes = Dictionary(
                uniqueKeysWithValues: session.map { ($0.id, $0.outcome ?? .delivered) })
            let history = PaceHistory.learn(from: Array(routes[..<index]))

            // Leave only the sitting on the tour, and wind it back door by door.
            for stop in driven where truth[stop.id] == nil { stop.record(.toLager, at: .distantPast) }
            route.status = .active
            for settled in stride(from: session.count - 1, through: 1, by: -1) {
                for stop in session[settled...] { stop.record(nil) }
                guard let now = session[settled - 1].settledAt else { continue }
                let snapshot = RouteSnapshot(route, history: history)
                for stop in session[settled...] {
                    guard let eta = snapshot.eta(for: stop, from: now), let real = truth[stop.id]
                    else { continue }
                    stopErrors.append(eta.timeIntervalSince(real) / 60)
                }
                // Held against the last door's tick, so the drive home — which
                // no tick marks the end of — is taken off the estimate.
                if let finish = snapshot.etaFinish(from: now),
                   let lastDoor = session.last, let lastETA = snapshot.eta(for: lastDoor, from: now) {
                    let error = lastETA.timeIntervalSince(end) / 60
                    _ = finish
                    finishErrors.append(error)
                    if settled == 1 { startErrors.append(error) }
                }
            }
            for stop in session {
                stop.record(outcomes[stop.id], at: truth[stop.id] ?? Date())
            }
            route.status = .completed
        }

        func line(_ name: String, _ errors: [Double]) -> String {
            guard !errors.isEmpty else { return "\(name): no data" }
            let size = errors.map(abs).sorted()
            let mean = size.reduce(0, +) / Double(size.count)
            let bias = errors.reduce(0, +) / Double(errors.count)
            return String(
                format: "%@: n=%d  mean |error| %.1f min  median %.1f  90%% within %.1f  bias %+.1f",
                name, size.count, mean, size[size.count / 2], size[Int(0.9 * Double(size.count))], bias)
        }
        print("PACE REPLAY", line("arrival at a door", stopErrors))
        print("PACE REPLAY", line("arrival at the last door", finishErrors))
        print("PACE REPLAY", line("  … as said after the first tick", startErrors))
    }
}
