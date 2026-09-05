import Foundation

/// Which customer stops share a front door.
///
/// Two households in one Gemeindebau, two meals at one address, is a case this
/// app goes out of its way to support — the driver rings once and carries two.
/// So the list and the map both need to know which stops belong together
/// rather than drawing them as two unrelated pins a metre apart.
///
/// Stops are linked two ways: by normalized address, and — for stops whose
/// location is exactly known — by coordinate. The second catches the pair that
/// is written two different ways ("Gentzgasse 129/1" and "Gentzgasse 129 Stg 1")
/// but resolved to the same registered point. Approximate stops are
/// deliberately *not* linked by point: a whole district's worth of them share
/// one centroid, and grouping those would claim thirty unrelated customers all
/// live at the same door.
///
/// Written to be cheap, because it is not called once. `RouteSnapshot` builds
/// this on every body evaluation of the stop list — which includes every
/// keystroke typed into the search field — so a route's worth of doors has to
/// be worked out well inside a frame.
enum SameDoor {

    /// How precisely two coordinates must agree to count as one door. Five
    /// decimal places is about a metre — tight enough that neighbouring
    /// buildings stay separate, loose enough to survive float round-tripping.
    private static let samePointDecimals = 5

    /// Maps each customer stop's id to every stop id sharing its door,
    /// itself included. A stop with no neighbours maps to a single-element
    /// group, so callers never have to special-case the common answer.
    static func groups(for stops: [Stop]) -> [UUID: [UUID]] {
        let (ids, root) = solve(stops)
        guard !ids.isEmpty else { return [:] }

        var byRoot = [[UUID]](repeating: [], count: ids.count)
        for (i, id) in ids.enumerated() { byRoot[root[i]].append(id) }

        var out: [UUID: [UUID]] = [:]
        out.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { out[id] = byRoot[root[i]] }
        return out
    }

    /// Just how many customers share each stop's door — which is all the stop
    /// list ever asks. Counted straight off the roots rather than through
    /// `groups`, so a route's worth of one-element arrays is never built only to
    /// have `.count` taken off it.
    static func counts(for stops: [Stop]) -> [UUID: Int] {
        let (ids, root) = solve(stops)
        guard !ids.isEmpty else { return [:] }

        var perRoot = [Int](repeating: 0, count: ids.count)
        for r in root { perRoot[r] += 1 }

        var out: [UUID: Int] = [:]
        out.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { out[id] = perRoot[root[i]] }
        return out
    }

    /// The union-find itself: the customer ids in route order, and — as an
    /// index into that same array — the door each one belongs to. Both public
    /// answers above are a different reading of this one result.
    ///
    /// Over *indices*, not over `UUID`s. The sets being merged are positions in
    /// one array, so the parent links are an `[Int]` that is walked and
    /// rewritten in place; keyed by `UUID` they were four dictionaries' worth of
    /// hashing a 16-byte value to answer what an array subscript answers.
    private static func solve(_ stops: [Stop]) -> (ids: [UUID], root: [Int]) {
        var customers: [Stop] = []
        customers.reserveCapacity(stops.count)
        for s in stops where s.kind == .customer { customers.append(s) }
        guard !customers.isEmpty else { return ([], []) }

        // Union-find. A route caps out around a hundred stops so the cost is
        // irrelevant, but the correctness is not: "put each stop in the first
        // group it matches" gets the wrong answer when a third stop is the one
        // that reveals two earlier groups are the same door.
        var parent = Array(customers.indices)

        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            // Path compression, so a long chain is walked once rather than
            // once per lookup.
            var cur = i
            while parent[cur] != root {
                let next = parent[cur]
                parent[cur] = root
                cur = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // One map per kind of link rather than one map with a "a:"/"p:" prefix
        // interpolated into every key: the prefixes only ever existed to keep
        // two namespaces out of each other's way, which two dictionaries do for
        // free and without building a string per stop to do it.
        var firstByAddress: [AddressDoor: Int] = [:]
        var firstByPoint: [PointDoor: Int] = [:]
        firstByAddress.reserveCapacity(customers.count)
        firstByPoint.reserveCapacity(customers.count)

        for (i, s) in customers.enumerated() {
            let address = AddressDoor(
                street: AddressText.matchKey(s.strasse ?? ""), plz: s.plz ?? "")
            if let first = firstByAddress[address] {
                union(first, i)
            } else {
                firstByAddress[address] = i
            }

            if s.precision == nil, let point = PointDoor(lat: s.lat, lon: s.lon) {
                if let first = firstByPoint[point] {
                    union(first, i)
                } else {
                    firstByPoint[point] = i
                }
            }
        }

        var root = [Int](repeating: 0, count: customers.count)
        for i in customers.indices { root[i] = find(i) }
        return (customers.map(\.id), root)
    }

    /// One door as the paste-and-re-export pipeline spells it.
    private struct AddressDoor: Hashable {
        let street: String
        let plz: String
    }

    /// One door as a position, quantized to about a metre.
    ///
    /// A pair of integers rather than a formatted string. This value is only
    /// ever a dictionary key, and `String(format:)` building it was over half
    /// the cost of working out a whole route's doors — ~1.9 ms of the 3.3 ms a
    /// 97-stop tour took, paid again on every redraw of the stop list. It also
    /// puts `-0.0` and `0.0` in the same bucket, which `"%.5f"` did not.
    private struct PointDoor: Hashable {
        let lat: Int64
        let lon: Int64

        private static let scale = pow(10.0, Double(samePointDecimals))

        /// `nil` for a coordinate outside the Vienna box. A stop there has no
        /// usable point to share with anything — `Stop.coordinate` already
        /// replaces it with the city centre everywhere it is drawn or driven to
        /// — and bounding the value is also what keeps the conversion below
        /// from trapping on an absurd one.
        init?(lat: Double, lon: Double) {
            guard Coordinates.isPlausible(lat: lat, lon: lon) else { return nil }
            self.lat = Int64((lat * Self.scale).rounded())
            self.lon = Int64((lon * Self.scale).rounded())
        }
    }
}
