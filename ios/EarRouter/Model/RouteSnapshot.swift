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
    let deliveredCount: Int
    let nextOpen: Stop?
    let totalKm: Double
    let totalMinutes: Double
    /// What is still to drive: every leg from the last stop the driver has
    /// actually ticked off to the end of the tour.
    ///
    /// Not the same number as the total, and the total is not the one a driver
    /// halfway through a shift is asking for — "27,3 km" stops meaning
    /// anything the moment the first meal is delivered. A leg belongs to the
    /// stop it leaves from, so everything before the last delivered stop has
    /// been driven and everything from it onwards has not. With nothing
    /// delivered yet this is the whole tour; with everything delivered it is
    /// the drive back to the depot, which is real and still has to be made.
    let remainingKm: Double
    let remainingMinutes: Double

    /// Each customer's position in driving order, so the list badge and the map
    /// pin show the same number.
    private let numbers: [UUID: Int]
    /// How many customers share each stop's front door — two households in one
    /// Gemeindebau is one ring of the bell and two meals carried up.
    private let doorCounts: [UUID: Int]

    var isComplete: Bool { customerCount > 0 && deliveredCount == customerCount }

    /// Customers still waiting for their meal.
    var openCount: Int { customerCount - deliveredCount }

    func number(_ stop: Stop) -> Int? { numbers[stop.id] }
    func doorCount(_ stop: Stop) -> Int { doorCounts[stop.id] ?? 1 }

    init(_ route: Route) {
        let ordered = route.orderedStops
        self.ordered = ordered

        var numbers: [UUID: Int] = [:]
        var customers = 0
        var delivered = 0
        var next: Stop?
        var km = 0.0
        var minutes = 0.0
        // The legs already behind the driver: everything up to, but not
        // including, the leg leaving the last stop they ticked off. Captured
        // *before* this stop's own leg is added, so the drive out of that stop
        // still counts as ahead of them — they are standing at its door.
        var drivenKm = 0.0
        var drivenMinutes = 0.0

        for stop in ordered {
            if stop.kind == .customer {
                customers += 1
                numbers[stop.id] = customers
                if stop.delivered {
                    delivered += 1
                    // Only while every customer up to here has been delivered.
                    //
                    // Ticked off in order — the normal case, and the one every
                    // other test in `RouteSnapshotTests` describes — that is
                    // every delivered stop in turn, and this is exactly what it
                    // always was. What it now refuses to do is let a delivery
                    // made *out* of order drag the mark forward past doors that
                    // are still owed. A customer met on the street and handed
                    // their meal twenty stops early used to move it to their
                    // position, so the card paired "Noch 22 Stopps" with the
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
                } else if next == nil {
                    next = stop
                }
            }
            // Only the legs actually driven count towards the tour's totals.
            guard !stop.excluded else { continue }
            km += stop.nextLegKm ?? 0
            minutes += stop.nextLegMin ?? 0
        }

        self.customerCount = customers
        self.deliveredCount = delivered
        self.nextOpen = next
        self.numbers = numbers
        self.totalKm = km
        self.totalMinutes = minutes
        // Clamped: a route whose legs were written by two different
        // optimization runs can hold slightly inconsistent numbers, and a
        // negative "still to drive" is worse than a zero.
        self.remainingKm = max(0, km - drivenKm)
        self.remainingMinutes = max(0, minutes - drivenMinutes)
        self.doorCounts = SameDoor.counts(for: ordered)
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
            else { return "Alle geliefert" }
            return "Alle geliefert · Rückfahrt \(back)"
        }
        let stops = "Noch \(Format.stops(openCount))"
        guard let km = Format.km(remainingKm), remainingKm >= 0.05 else { return stops }
        return "\(stops) · \(km)"
    }
}
