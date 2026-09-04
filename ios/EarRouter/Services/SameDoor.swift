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
        let customers = stops.filter { $0.kind == .customer }
        guard !customers.isEmpty else { return [:] }

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

        var byRoot: [UUID: [UUID]] = [:]
        for s in customers { byRoot[find(s.id), default: []].append(s.id) }

        var out: [UUID: [UUID]] = [:]
        for s in customers { out[s.id] = byRoot[find(s.id)] ?? [s.id] }
        return out
    }

    private static func pointKey(_ s: Stop) -> String {
        String(
            format: "%.\(samePointDecimals)f,%.\(samePointDecimals)f",
            locale: Locale(identifier: "en_US_POSIX"),
            s.lat, s.lon)
    }
}
