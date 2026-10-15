import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import EarRouter

/// Splits the finished tours of a backup file both ways — fair, and only as
/// efficient as possible — and prints what the fairness costs in time
/// altogether, on real doors and OSRM's real drive between them.
///
/// Off unless `SPLIT_BACKUP` names a backup file (pass it with a
/// `TEST_RUNNER_` prefix). It asserts nothing; it is for judging the planner
/// against real tours.
@MainActor
struct SplitReplayTests {
    nonisolated static var backupPath: String? { ProcessInfo.processInfo.environment["SPLIT_BACKUP"] }

    /// What the ticks say a door takes, by how far it is from the one
    /// before: a second household at the same door, a door a short walk
    /// away, and one driven to. Gap between two ticks in a row, raw and less
    /// OSRM's planned drive between them.
    @Test(.enabled(if: SplitReplayTests.backupPath != nil))
    func doorTimes() throws {
        let path = try #require(Self.backupPath)
        let archive = try BackupArchive.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        let context = ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        try BackupRestore.apply(archive, mode: .replace, in: context)
        let routes = try context.fetch(FetchDescriptor<Route>())

        var gaps: [String: [Double]] = [:], net: [String: [Double]] = [:]
        var byMetres: [Int: [Double]] = [:]
        for route in routes where route.status == .completed {
            let snapshot = RouteSnapshot(route, history: .none)
            let groups = SameDoor.groups(for: snapshot.ordered)
            let ticked = snapshot.ordered
                .filter { $0.kind == .customer && $0.settledAt != nil && $0.outcome?.skipsDoor != true }
                .sorted { $0.settledAt! < $1.settledAt! }
            for (a, b) in zip(ticked, ticked.dropFirst()) {
                let gap = b.settledAt!.timeIntervalSince(a.settledAt!) / 60
                guard (0.1...45).contains(gap),
                      let ta = snapshot.plannedMinutes(to: a), let tb = snapshot.plannedMinutes(to: b)
                else { continue }
                let drive = tb - ta
                guard drive >= -0.01 else { continue }
                let metres = WalkOn.metres(
                    from: [CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)],
                    to: [CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)]) ?? .infinity
                let kind: String
                if groups[a.id]?.contains(b.id) == true || metres < 5 {
                    kind = "1 gleiche Tür"
                } else if metres <= WalkOn.reach {
                    kind = "2 zu Fuß ≤100 m"
                } else if metres <= 250 {
                    kind = "3 100–250 m"
                } else {
                    kind = "4 gefahren"
                }
                gaps[kind, default: []].append(gap)
                net[kind, default: []].append(gap - drive)
                if metres <= 500 { byMetres[Int(metres / 50) * 50, default: []].append(gap) }
            }
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.map { min($0, 15) }.reduce(0, +) / Double(v.count) }
        for kind in gaps.keys.sorted() {
            let g = gaps[kind]!, n = net[kind]!
            print(String(
                format: "DOOR %@: n=%d  Abstand Median %.1f / Mittel %.1f min  ohne Fahrt Median %.1f / Mittel %.1f min",
                kind, g.count, median(g), mean(g), median(n), mean(n)))
        }
        for metres in byMetres.keys.sorted() {
            let g = byMetres[metres]!
            print(String(format: "DOORM %3d–%3d m: n=%d  Median %.1f min", metres, metres + 50, g.count, median(g)))
        }
    }

    @Test(.enabled(if: SplitReplayTests.backupPath != nil))
    func replay() async throws {
        let path = try #require(Self.backupPath)
        let archive = try BackupArchive.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        let context = ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        try BackupRestore.apply(archive, mode: .replace, in: context)
        let routes = try context.fetch(FetchDescriptor<Route>(sortBy: [SortDescriptor(\.createdAt)]))

        var extra: [Int: [Double]] = [:]
        var share: [Int: [Double]] = [:]
        var spread: [Int: [Double]] = [:]
        for route in routes {
            let customers = route.orderedStops.filter {
                $0.kind == .customer && Coordinates.isPlausible(lat: $0.lat, lon: $0.lon)
            }
            guard customers.count >= 12 else { continue }

            // Grouped exactly as the split screen groups them.
            var coordinates: [(lat: Double, lon: Double)] = [
                (Coordinates.via.lat, Coordinates.via.lon), (Coordinates.start.lat, Coordinates.start.lon),
            ]
            var pointOf: [String: Int] = [:]
            var split: [ParkingStops.Customer] = []
            for (index, stop) in customers.enumerated() {
                let key = String(format: "%.5f,%.5f", stop.lat, stop.lon)
                if pointOf[key] == nil {
                    pointOf[key] = coordinates.count
                    coordinates.append((stop.lat, stop.lon))
                }
                split.append(ParkingStops.Customer(
                    id: index, address: ParkingStops.addressKey(stop.strasse ?? "", plz: stop.plz ?? ""),
                    point: pointOf[key]!, coordinate: CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon),
                    exact: stop.precision == nil, owner: nil, minutes: RouteSnapshot.Pace.assumedMinutes))
            }
            let doors = ParkingStops.build(split).doors
            let osrm = try? await OSRMClient.shared.durations(between: coordinates)
            let m = osrm ?? SplitDurations.straightLine(coordinates)

            for people in [2, 3] {
                let fair = SplitPlanner.plan(
                    doors: doors, people: people, durations: m,
                    deadline: Date().addingTimeInterval(SplitPlanner.thinkingTime))
                let unbounded = SplitPlanner.plan(
                    doors: doors, people: people, durations: m, objective: .fair,
                    deadline: Date().addingTimeInterval(SplitPlanner.thinkingTime))
                let efficient = SplitPlanner.plan(
                    doors: doors, people: people, durations: m, objective: .leastTotal,
                    deadline: Date().addingTimeInterval(SplitPlanner.thinkingTime))
                func minutes(_ days: [SplitPlanner.Day]) -> [Int] { days.map { Int(($0.seconds / 60).rounded()) } }
                let fairTotal = fair.reduce(0) { $0 + $1.seconds } / 60
                let bestTotal = efficient.reduce(0) { $0 + $1.seconds } / 60
                extra[people, default: []].append(fairTotal - bestTotal)
                let longest = fair.map(\.seconds).max()! / 60, shortest = fair.map(\.seconds).min()! / 60
                spread[people, default: []].append(longest - shortest)
                share[people, default: []].append((fairTotal - bestTotal) / bestTotal)
                print(
                    "SPLIT \(route.name) · \(customers.count) Stopps/\(doors.count) Halte · \(people) P"
                        + "\(osrm == nil ? " (Luftlinie)" : ""): "
                        + "fair \(minutes(fair)) = \(Int(fairTotal.rounded())) min, "
                        + "effizient \(minutes(efficient)) = \(Int(bestTotal.rounded())) min, "
                        + "nur gleich \(minutes(unbounded)), "
                        + "Aufpreis \(String(format: "%.1f", fairTotal - bestTotal)) min")
            }
        }
        for people in [2, 3] {
            let e = extra[people] ?? [], s = share[people] ?? []
            guard !e.isEmpty else { continue }
            print(
                "SPLIT SUMME \(people) P über \(e.count) Touren: Aufpreis im Mittel "
                    + String(format: "%.1f min (%.1f %%), höchstens %.1f min (%.1f %%)",
                        e.reduce(0, +) / Double(e.count), 100 * s.reduce(0, +) / Double(s.count),
                        e.max() ?? 0, 100 * (s.max() ?? 0))
                    + String(format: "; längster minus kürzester Tag im Mittel %.1f, höchstens %.1f min",
                        (spread[people] ?? []).reduce(0, +) / Double(e.count), (spread[people] ?? []).max() ?? 0))
        }
    }
}
