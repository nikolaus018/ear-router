import Foundation
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "geocode-cache")

/// A resolved address, remembered so the same door is never looked up twice.
struct CachedGeocode: Codable, Sendable {
    var lat: Double
    var lon: Double
    var displayName: String
    var precision: Precision
    /// When this entry was (last) written. Only consulted for a non-exact
    /// precision — an exact hit stays true forever, but a street- or
    /// district-level approximation is an admitted guess that a geocoder
    /// catching up later (a new building finally getting mapped) should
    /// eventually get to override, instead of this app serving the same coarse
    /// pin to that address for good.
    var cachedAt: Date
}

/// The geocode cache and its negative twin.
///
/// Kept in a plain JSON file rather than in SwiftData: none of this is user
/// data, none of it is ever shown in a list or edited, and it is written from
/// inside an actor that has no business touching the model context. A few
/// thousand entries is a small file that loads in milliseconds.
actor GeocodeCache {
    static let shared = GeocodeCache()

    /// An exact hit never expires on its own — a confirmed door does not move.
    /// This is the ceiling for the approximate ones.
    private static let approxTTL: TimeInterval = 30 * 24 * 60 * 60
    /// A "no geocoder has this address" verdict is remembered only for a few
    /// hours, so a genuinely new building that gets registered tomorrow is not
    /// blacklisted for good.
    private static let missTTL: TimeInterval = 6 * 60 * 60

    /// Bumped whenever the resolver itself learns to place an address better
    /// than a cached answer did. Exact rows never expire on their own —
    /// correctly — but when the *resolver* improves, every one of them is a
    /// confidently-wrong answer that would otherwise outlive the fix forever.
    private static let generation = 2

    private var hits: [String: CachedGeocode] = [:]
    private var misses: [String: Date] = [:]
    private var loaded = false
    private var dirty = false

    private var fileURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "EarRouter", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "geocode-cache.json")
    }

    // MARK: - Lookup

    func lookup(_ key: String) -> CachedGeocode? {
        load()
        guard let hit = hits[key] else { return nil }
        if hit.precision != .exact,
           Date().timeIntervalSince(hit.cachedAt) > Self.approxTTL {
            hits.removeValue(forKey: key)
            dirty = true
            return nil
        }
        return hit
    }

    func store(
        _ key: String, lat: Double, lon: Double,
        displayName: String, precision: Precision
    ) {
        load()
        hits[key] = CachedGeocode(
            lat: lat, lon: lon, displayName: displayName,
            precision: precision, cachedAt: Date())
        // A successful resolution retires any standing "does not exist"
        // verdict for the same address.
        misses.removeValue(forKey: key)
        dirty = true
        scheduleSave()
    }

    /// True when this exact query was recently confirmed unresolvable. Only
    /// ever records a *definitive* negative — never an upstream outage, which
    /// is a temporary condition and must be retried.
    func isKnownMiss(_ key: String) -> Bool {
        load()
        guard let at = misses[key] else { return false }
        if Date().timeIntervalSince(at) > Self.missTTL {
            misses.removeValue(forKey: key)
            dirty = true
            return false
        }
        return true
    }

    func recordMiss(_ key: String) {
        load()
        misses[key] = Date()
        dirty = true
        scheduleSave()
    }

    /// Drops every remembered answer. Offered in Mehr → "Geocode-Cache
    /// leeren" for the case where an address really has moved.
    func clear() {
        hits.removeAll()
        misses.removeAll()
        loaded = true
        dirty = true
        save()
    }

    var count: Int {
        load()
        return hits.count
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var generation: Int
        var hits: [String: CachedGeocode]
        var misses: [String: Date]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            log.warning("geocode cache did not parse, starting empty")
            return
        }
        // The whole cache is dropped rather than the rows guessed to be
        // affected: which keys those are depends on how each address happened
        // to be typed, and re-resolving a Vienna address costs one unthrottled
        // call to the city's own register.
        guard payload.generation >= Self.generation else {
            log.info("geocode cache generation \(payload.generation) < \(Self.generation), clearing")
            return
        }
        hits = payload.hits
        // Expired negatives are dead weight — past their TTL they are skipped
        // anyway, so they only ever sit there. Pruned on load rather than on a
        // timer: this table gains a handful of rows a day, and a cold launch
        // is a more than frequent enough broom.
        let cutoff = Date().addingTimeInterval(-Self.missTTL)
        misses = payload.misses.filter { $0.value > cutoff }
    }

    private var saveTask: Task<Void, Never>?

    /// Coalesces the writes from a bulk import, which would otherwise rewrite
    /// the whole file once per address.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    func save() {
        guard dirty else { return }
        saveTask?.cancel()
        saveTask = nil
        let payload = Payload(generation: Self.generation, hits: hits, misses: misses)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
        } catch {
            log.error("could not write geocode cache: \(error.localizedDescription)")
        }
    }
}
