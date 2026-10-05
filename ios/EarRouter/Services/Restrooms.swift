import CoreLocation
import Foundation
import Observation

/// A public toilet, the city's or one of öKlo's — a row of `Restrooms.json`,
/// which `Tools/MakeRestrooms.py` builds from both lists.
struct Restroom: Codable, Sendable, Hashable {
    let name: String
    let lat: Double
    let lon: Double
    /// Metres from the nearest road a car may use to the toilet itself.
    let walk: Int
    /// Opening and closing time in minutes, per weekday, Monday first; `nil`
    /// on a closed day. No table at all is a toilet that never closes.
    var hours: [[Int]?]?
    /// Shut from November to March.
    var winterClosed: Bool?
    /// One of öKlo's compost toilets rather than the city's.
    var oeklo: Bool?

    var label: String { oeklo == true ? "öKlo" : "WC" }

    /// What a toilet is remembered by across updates of the file: its name
    /// and where it stands, and not the hours or the walk, which a refresh
    /// may correct without it becoming a different toilet.
    var key: String {
        String(format: "%@|%.5f|%.5f", locale: Locale(identifier: "en_US_POSIX"), name, lat, lon)
    }

    /// There and back on foot, at an unhurried 75 m a minute.
    var walkMinutes: Double { Double(walk) * 2 / 75 }

    /// Whether the door is open at `date` — and still is twenty minutes on,
    /// because that is nearer to when the driver gets there.
    func isOpen(at date: Date) -> Bool {
        isOpenExactly(at: date) && isOpenExactly(at: date.addingTimeInterval(20 * 60))
    }

    private func isOpenExactly(at date: Date) -> Bool {
        let parts = Self.vienna.dateComponents([.month, .weekday, .hour, .minute], from: date)
        if winterClosed == true, let month = parts.month, month >= 11 || month <= 3 {
            return false
        }
        guard let hours else { return true }
        // `weekday` counts from Sunday = 1; the table from Monday = 0.
        let day = ((parts.weekday ?? 2) + 5) % 7
        guard hours.indices.contains(day), let span = hours[day], span.count == 2 else {
            return false
        }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= span[0] && minute < span[1]
    }

    private static let vienna: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna") ?? .current
        return c
    }()

    /// Every toilet there is: the list the app shipped with, or the newer one
    /// fetched from Mehr → Erweitert. See `RestroomCatalog`.
    static var all: [Restroom] { RestroomCatalog.shared.current.all }

    /// Every toilet with an id the map can select it by. The ids are made
    /// when the list is loaded and mean nothing outside this launch.
    static var pins: [RestroomPin] { RestroomCatalog.shared.current.pins }
    static var pinsByID: [UUID: RestroomPin] { RestroomCatalog.shared.current.pinsByID }

    /// This toilet's own pin — the same one whether it is on the map as the
    /// planned stop or as one of all of them. `nil` for a toilet the list no
    /// longer has. By `key`, so a stop planned before an update that only
    /// corrected its hours is still the same toilet.
    var pin: RestroomPin? { Self.pins.first { $0.key == key } }
}

/// A toilet as the map draws and selects it.
struct RestroomPin: Identifiable, Equatable, Sendable {
    let id: UUID
    let restroom: Restroom
    /// `restroom.key`, built once: the map asks every pin whether it is
    /// banned on every frame of a pan, and the key is a formatted string.
    let key: String
}

/// The WC stop the driver asked for: which toilet, and when on the tour.
///
/// Not a `Stop`. It is not on the tour's list, in its counts, its report or
/// its route — it sits beside the tour, between two of its stops, and is gone
/// once it is done.
struct RestroomBreak: Codable, Equatable, Sendable {
    let routeID: UUID
    let restroom: Restroom
    /// The stop it comes after. `nil` is straight away.
    let afterStopID: UUID?
    /// Extra driving and walking against not going at all.
    let detourMinutes: Double
    var createdAt = Date()

    /// Whether it is the next thing to drive to: asked for straight away, or
    /// the stop it follows has been ticked off — or has left the tour.
    func isDue(on route: Route) -> Bool {
        guard let afterStopID else { return true }
        guard let stop = route.stops.first(where: { $0.id == afterStopID }) else { return true }
        return stop.isSettled
    }
}

/// Holds the one planned WC stop, across a relaunch: the navigation app has
/// the screen on the way there, and iOS may end this one in the meantime.
@MainActor
@Observable
final class RestroomPlan {
    static let shared = RestroomPlan()

    var current: RestroomBreak? {
        didSet {
            let data = current.flatMap { try? JSONEncoder().encode($0) }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Toilets the driver never wants suggested again — shut, filthy, out of
    /// order — by `Restroom.key`. Kept for good, until the driver takes one
    /// back from its card on the map.
    private(set) var banned: Set<String> {
        didSet { UserDefaults.standard.set(banned.sorted(), forKey: Self.bannedKey) }
    }

    private init() {
        current = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(RestroomBreak.self, from: $0) }
        banned = Set(UserDefaults.standard.stringArray(forKey: Self.bannedKey) ?? [])
    }

    /// The driver stood in front of it and it was no use. The file says it is
    /// there and open; the driver outranks the file.
    func ban(_ restroom: Restroom) {
        banned.insert(restroom.key)
        if current?.restroom == restroom { current = nil }
    }

    func unban(_ restroom: Restroom) { banned.remove(restroom.key) }

    func isBanned(_ restroom: Restroom) -> Bool { banned.contains(restroom.key) }

    /// The planned stop, if it belongs to `route` and is from this shift.
    func planned(for route: Route) -> RestroomBreak? {
        // And still in the file: a stop planned before an update that dropped
        // its toilet is not one to send anybody to.
        guard let current, current.routeID == route.id,
              Date().timeIntervalSince(current.createdAt) < Self.keptFor,
              current.restroom.pin != nil
        else { return nil }
        return current
    }

    private static let key = "restroom.break"
    private static let bannedKey = "restroom.banned"
    private static let keptFor: TimeInterval = 3 * 60 * 60
}

// MARK: - Choosing

/// Picks the toilet, and the gap between two stops it goes into.
///
/// The tour's order is never touched. The driver is at `anchors[0]` and drives
/// the rest in order; a toilet goes between two neighbours, and what it costs
/// there is the drive in and out less the drive it replaces, plus the walk.
/// What is added to that is the wait — a toilet with no detour at all four
/// stops on is no use to somebody who pressed the button now.
enum RestroomPicker {
    struct Point: Sendable, Equatable {
        let lat: Double
        let lon: Double
    }

    struct Choice: Equatable {
        let restroom: Restroom
        /// Goes after `anchors[gap]`.
        let gap: Int
        let detourMinutes: Double
    }

    /// What a minute of waiting weighs against a minute of detour.
    static let urgency = 0.3
    /// Toilets kept per gap for the real driving times.
    static let perGap = 3
    /// Further from the road than this is a toilet in the middle of a park.
    static let maxWalk = 250

    /// The few toilets worth asking OSRM about: the best per gap as the crow
    /// flies. Asking about all of them would be a 180-point matrix.
    static func shortlist(anchors: [Point], restrooms: [Restroom]) -> [Restroom] {
        let usable = restrooms.filter { $0.walk <= maxWalk }
        var kept: [Restroom] = []
        for (a, b) in gaps(anchors) {
            let best = usable
                .map { r in
                    let p = Point(lat: r.lat, lon: r.lon)
                    return (r, crowMinutes(a, p) + crowMinutes(p, b) + r.walkMinutes)
                }
                .sorted { $0.1 < $1.1 }
                .prefix(perGap)
            for (r, _) in best where !kept.contains(r) { kept.append(r) }
        }
        return kept
    }

    /// The best candidate and its gap, or `nil` with nothing to choose from.
    ///
    /// `minutes(i, j)` is the drive between two points of `anchors +
    /// candidates`, indexed in that order. `firstIsStop` says the driver's own
    /// position is unknown and `anchors[0]` is the next door instead, which
    /// still has to be driven to and delivered.
    static func choose(
        anchors: [Point], candidates: [Restroom], doorMinutes: Double, firstIsStop: Bool,
        minutes: (Int, Int) -> Double?
    ) -> Choice? {
        guard !anchors.isEmpty else { return nil }
        // One anchor is a tour with nothing after it: there and back.
        let last = max(anchors.count - 1, 1)
        var best: (choice: Choice, score: Double)?
        var wait = firstIsStop ? doorMinutes : 0
        for gap in 0..<last {
            let from = gap, to = min(gap + 1, anchors.count - 1)
            let direct = from == to ? 0 : minutes(from, to)
            for (offset, restroom) in candidates.enumerated() {
                let c = anchors.count + offset
                guard let direct, let there = minutes(from, c), let back = minutes(c, to) else {
                    continue
                }
                let detour = max(0, there + back - direct) + restroom.walkMinutes
                let score = detour + urgency * wait
                if best == nil || score < best!.score {
                    best = (Choice(restroom: restroom, gap: gap, detourMinutes: detour), score)
                }
            }
            wait += (direct ?? 0) + doorMinutes
        }
        return best?.choice
    }

    private static func gaps(_ anchors: [Point]) -> [(Point, Point)] {
        guard let first = anchors.first else { return [] }
        if anchors.count == 1 { return [(first, first)] }
        return Array(zip(anchors, anchors.dropFirst()))
    }

    /// A drive guessed from the straight line: 1.4 times as far by road, at
    /// 25 km/h. Good enough to rank by, and all there is without a network.
    static func crowMinutes(_ a: Point, _ b: Point) -> Double {
        let metres = CLLocation(latitude: a.lat, longitude: a.lon)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lon))
        return metres / 1000 * 1.4 / 25 * 60
    }
}

/// The search behind the WC button: where the driver is, the next few stops,
/// one request to OSRM, one answer.
@MainActor
enum RestroomFinder {
    /// How many stops ahead a toilet may be put.
    static let stopsAhead = 4

    /// `only` is a toilet the driver picked off the map: it is taken as it is —
    /// shut, far from the road, struck off earlier — and only the place on
    /// the tour is chosen for it.
    static func find(
        for route: Route, only: Restroom? = nil, now: Date = Date()
    ) async -> RestroomBreak? {
        let snapshot = RouteSnapshot(route)
        let open = snapshot.ordered.filter(\.isOpenStop)
        // Ziel last, wherever it is listed — the order `nextOpen` gives.
        let upcoming = (open.filter { $0.kind != .end } + open.filter { $0.kind == .end })
            .prefix(stopsAhead)
        guard !upcoming.isEmpty else { return nil }

        let location = LocationAuthorization.shared
        var fix = location.recentFix(within: 60)
        if fix == nil { fix = await location.currentFix(timeout: .seconds(4)) }
        let here = fix.flatMap { c in
            Coordinates.isPlausible(lat: c.latitude, lon: c.longitude)
                ? RestroomPicker.Point(lat: c.latitude, lon: c.longitude) : nil
        }

        let stops = upcoming.map(\.planningSnapshot)
        let anchors = (here.map { [$0] } ?? [])
            + stops.map { RestroomPicker.Point(lat: $0.lat, lon: $0.lon) }
        let plan = RestroomPlan.shared
        let candidates = only.map { [$0] } ?? RestroomPicker.shortlist(
            anchors: anchors,
            restrooms: Restroom.all.filter { $0.isOpen(at: now) && !plan.isBanned($0) })
        guard !candidates.isEmpty else { return nil }

        let points = anchors + candidates.map { RestroomPicker.Point(lat: $0.lat, lon: $0.lon) }
        // Without a network the straight-line guess still finds the near one.
        let table = try? await OSRMClient.shared.table(points.map { (lat: $0.lat, lon: $0.lon) })
        let choice = RestroomPicker.choose(
            anchors: anchors, candidates: candidates,
            doorMinutes: snapshot.pace.minutesPerStop, firstIsStop: here == nil
        ) { i, j in
            if let table { return table[i][j] }
            return RestroomPicker.crowMinutes(points[i], points[j])
        }
        guard let choice else { return nil }

        // Gap 0 starts at the driver when there is a fix, and at the first
        // stop when there is none.
        let after = here == nil ? choice.gap : choice.gap - 1
        return RestroomBreak(
            routeID: route.id, restroom: choice.restroom,
            afterStopID: after >= 0 ? stops[after].id : nil,
            detourMinutes: choice.detourMinutes, createdAt: now)
    }
}
