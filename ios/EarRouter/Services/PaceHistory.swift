import CoreLocation
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
    /// Minutes from leaving for the Lager to ticking it: the drive there and
    /// whatever the morning holds before the tick. `nil` until two finished
    /// tours carry a departure — see `TourDeparture`.
    var leadMinutes: Double?
    /// The same figure for each tour driven before, by `tourKey`: that tour's
    /// own doors, pulled towards `doorMinutes` by `tourWeight`.
    ///
    /// A round is the same customers every week, and the rounds are not
    /// alike: across fifteen tours of autumn 2026 the Monday frozen round
    /// took nine minutes a door where the Friday one took under six. Counted
    /// at the average of all of them, the Monday round was promised finished
    /// forty minutes before it was.
    var doorByTour: [String: Double] = [:]
    /// What each customer's own door took, by `StockwerkKey`: the fourth floor
    /// without a lift, the Haustür nobody opens, the lady who wants to talk.
    /// Kept raw — the mean and how many doors it is of — because what it is
    /// pulled towards is the tour it is driven on, and that is only known when
    /// it is asked for. See `doorMinutes(forCustomer:onTour:)`.
    var doorByCustomer: [String: CustomerDoor] = [:]

    struct CustomerDoor: Equatable, Sendable {
        var minutes: Double
        var samples: Int
    }

    /// How many doors' worth the figure for all tours weighs against one
    /// tour's own: a round driven once has said little yet.
    static let tourWeight = 8.0
    /// The same for one customer against their tour: a door is driven once
    /// a week, and one slow morning there is not who they are.
    static let customerWeight = 3.0

    /// What a tour is recognised by from one week to the next: its name,
    /// whatever the capitals and the spacing.
    static func tourKey(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The door time to start a tour of this name from.
    func doorMinutes(forTour name: String) -> Double? {
        doorByTour[Self.tourKey(name)] ?? doorMinutes
    }

    /// The door time to count one customer at: their own doors, pulled
    /// towards the tour's figure — or the assumption, on a phone with none.
    func doorMinutes(forCustomer key: String?, onTour name: String) -> Double {
        let tour = doorMinutes(forTour: name) ?? RouteSnapshot.Pace.assumedMinutes
        guard let key, let own = doorByCustomer[key], own.samples > 0 else { return tour }
        let n = Double(own.samples)
        return (own.minutes * n + Self.customerWeight * tour) / (n + Self.customerWeight)
    }

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
    ///
    /// `departure` is where each tour's departure is read from; the tests
    /// hand in their own.
    @MainActor
    static func learn(
        from routes: [Route], departure: (UUID) -> Date? = TourDeparture.load
    ) -> PaceHistory {
        var doors: [Double] = []
        var waits: [Double] = []
        var leads: [Double] = []
        var byTour: [String: [Double]] = [:]
        var byCustomer: [String: [Double]] = [:]

        for route in routes where route.status == .completed {
            let snapshot = RouteSnapshot(route, history: .none)
            doors.append(contentsOf: snapshot.doorSamples)
            byTour[tourKey(route.name), default: []].append(contentsOf: snapshot.doorSamples)
            let arrivals = Dictionary(
                snapshot.ordered.compactMap { stop in
                    snapshot.plannedMinutes(to: stop).map { (stop.id, $0) }
                }, uniquingKeysWith: { a, _ in a })
            for sample in RouteSnapshot.doorSamplesByStop(snapshot.ordered, arrivals: arrivals) {
                // Only a door driven to: one a walk from the last is the
                // shorter time `ParkingStops.walkOnShare` already gives it,
                // and learning it here would count that saving twice.
                let walked = WalkOn.metres(
                    from: [CLLocationCoordinate2D(latitude: sample.from.lat, longitude: sample.from.lon)],
                    to: [CLLocationCoordinate2D(latitude: sample.stop.lat, longitude: sample.stop.lon)])
                    .map { $0 <= WalkOn.reach } ?? false
                guard !walked, let key = StockwerkKey.make(for: sample.stop) else { continue }
                byCustomer[key, default: []].append(sample.minutes)
            }
            if let wait = lagerWait(in: snapshot) { waits.append(wait) }
            if let lead = lead(in: snapshot, departedAt: departure(route.id)) { leads.append(lead) }
        }

        var learned = PaceHistory()
        guard doors.count >= fewestSamples else { return learned }
        let door = doors.reduce(0) { $0 + min($1, RouteSnapshot.Pace.cap) } / Double(doors.count)
        learned.doorMinutes = min(max(door, 2), RouteSnapshot.Pace.cap)
        for (key, samples) in byTour where !samples.isEmpty {
            let own = samples.reduce(0) { $0 + min($1, RouteSnapshot.Pace.cap) }
            let blended = (own + tourWeight * door) / (Double(samples.count) + tourWeight)
            learned.doorByTour[key] = min(max(blended, 2), RouteSnapshot.Pace.cap)
        }
        for (key, samples) in byCustomer where !samples.isEmpty {
            let own = samples.reduce(0) { $0 + min($1, RouteSnapshot.Pace.cap) }
            learned.doorByCustomer[key] = CustomerDoor(
                minutes: own / Double(samples.count), samples: samples.count)
        }

        // What is left of the wait once the first door's own time is taken
        // off it. The median, because one morning spent waiting for the
        // kitchen is not what the next one will be.
        let loading = waits.map { $0 - door }.filter { (-5...90).contains($0) }
            .map { max(0, $0) }.sorted()
        if loading.count >= 2 { learned.lagerMinutes = loading[loading.count / 2] }
        // The median again: one morning in a traffic jam is not the next.
        leads.sort()
        if leads.count >= 2 { learned.leadMinutes = leads[leads.count / 2] }
        return learned
    }

    /// Minutes from the departure to the Lager's tick. `nil` where the Lager
    /// was ticked by the first door rather than by hand — that is no
    /// measurement of when the van got there — and where the two are further
    /// apart than a morning: a stamp from another day.
    @MainActor
    private static func lead(in snapshot: RouteSnapshot, departedAt: Date?) -> Double? {
        guard let departedAt,
              let lager = snapshot.ordered.first(where: { $0.kind == .via && $0.isCheckpoint }),
              let loadedAt = lager.settledAt
        else { return nil }
        let firstDoor = snapshot.ordered
            .filter { $0.passesLager }.compactMap(\.settledAt).min()
        if let firstDoor, firstDoor <= loadedAt { return nil }
        let minutes = loadedAt.timeIntervalSince(departedAt) / 60
        return (1...180).contains(minutes) ? minutes : nil
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
