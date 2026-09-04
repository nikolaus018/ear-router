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

        var byRoot: [UUID: [UUID]] = [:]
        for id in ids { byRoot[root[id] ?? id, default: []].append(id) }

        var out: [UUID: [UUID]] = [:]
        out.reserveCapacity(ids.count)
        for id in ids { out[id] = byRoot[root[id] ?? id] ?? [id] }
        return out
    }

    /// Just how many customers share each stop's door — which is all the stop
    /// list ever asks. Counted straight off the roots rather than through
    /// `groups`, so a route's worth of one-element arrays is never built only to
    /// have `.count` taken off it.
    static func counts(for stops: [Stop]) -> [UUID: Int] {
        let (ids, root) = solve(stops)
        guard !ids.isEmpty else { return [:] }

        var perRoot: [UUID: Int] = [:]
        for id in ids { perRoot[root[id] ?? id, default: 0] += 1 }

        var out: [UUID: Int] = [:]
        out.reserveCapacity(ids.count)
        for id in ids { out[id] = perRoot[root[id] ?? id] ?? 1 }
        return out
    }

    /// The union-find itself: the customer ids, and the door each one belongs
    /// to. Both public answers above are a different reading of this one result.
    private static func solve(_ stops: [Stop]) -> (ids: [UUID], root: [UUID: UUID]) {
        let customers = stops.filter { $0.kind == .customer }
        guard !customers.isEmpty else { return ([], [:]) }

        // Union-find. A route caps out around a hundred stops so the cost is
        // irrelevant, but the correctness is not: "put each stop in the first
        // group it matches" gets the wrong answer when a third stop is the one
        // that reveals two earlier groups are the same door.
        var parent: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: customers.map { ($0.id, $0.id) })

        func find(_ id: UUID) -> UUID {
            var root = id
            while let p = parent[root], p != root { root = p }
            // Path compression, so a long chain is walked once rather than
            // once per lookup.
            var cur = id
            while let p = parent[cur], p != root {
                parent[cur] = root
                cur = p
            }
            return root
        }

        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var firstBy: [String: UUID] = [:]
        func link(_ key: String, _ id: UUID) {
            if let first = firstBy[key] { union(first, id) } else { firstBy[key] = id }
        }

        for s in customers {
            link("a:\(AddressText.matchKey(s.strasse ?? ""))|\(s.plz ?? "")", s.id)
            if s.precision == nil, s.lat.isFinite, s.lon.isFinite {
                link("p:\(pointKey(s))", s.id)
            }
        }

        var root: [UUID: UUID] = [:]
        root.reserveCapacity(customers.count)
        for s in customers { root[s.id] = find(s.id) }
        return (customers.map(\.id), root)
    }

    private static let pointFormat = "%.\(samePointDecimals)f,%.\(samePointDecimals)f"
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func pointKey(_ s: Stop) -> String {
        String(
            format: pointFormat,
            locale: posix,
            s.lat, s.lon)
    }
}
