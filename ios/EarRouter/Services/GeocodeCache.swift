import Foundation
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "geocode-cache")

/// A resolved address, remembered so the same door is never looked up twice.
struct CachedGeocode: Codable, Sendable {
    var lat: Double
    var lon: Double
    var displayName: String
    var precision: Precision
    /// When this entry was (last) written — what the trim goes by.
    var cachedAt: Date
}

/// The geocode cache and its negative twin.
///
/// Exact answers only. A confirmed door does not move, so remembering one
/// costs nothing and saves the half-second lookup on every daily import of the
/// same customers. An approximation is the opposite: an admitted guess that a
/// better lookup — or a fix to this app's own matching — should replace the
/// next time it is asked. Cached, it was served for thirty days after the
/// lookup had learned to place it ("Pfenningeldgasse" kept its "≈", and
/// "Pfenninggeldgasse 9/2/15" its pin on the wrong house). So an "≈" address
/// is simply asked again, every time.
///
/// Kept in a plain JSON file rather than in SwiftData: none of this is user
/// data, none of it is ever shown in a list or edited, and it is written from
/// inside an actor that has no business touching the model context. A few
/// thousand entries is a small file that loads in milliseconds.
actor GeocodeCache {
    static let shared = GeocodeCache()

    /// A "no geocoder has this address" verdict is remembered only for a few
    /// hours, so a genuinely new building that gets registered tomorrow is not
    /// blacklisted for good.
    private static let missTTL: TimeInterval = 6 * 60 * 60

    /// An upper bound on the table, because nothing else is one: every address
    /// a driver ever enters is remembered forever, the whole file is read into
    /// memory on first use, and the whole of it is rewritten on every save.
    /// Well past a career's worth of distinct Viennese doors — this exists so
    /// the file has a ceiling at all, not to make anybody's cache miss.
    private static let maxHits = 5_000

    /// Bumped whenever the resolver itself learns to place an address better
    /// than a cached answer did. Exact rows never expire on their own —
    /// correctly — but when the *resolver* improves, every one of them is a
    /// confidently-wrong answer that would otherwise outlive the fix forever.
    ///
    /// 3: the register's answer is now matched to the asked-for street through
    /// `AddressText.matchKey` rather than a lowercased raw string, so every
    /// hyphenated street typed with spaces — "Dr. Karl Lueger-Platz", and most
    /// of Vienna's named squares — resolves against the city register instead
    /// of falling through to an approximate Nominatim pin.
    ///
    /// 4: and `matchKey` now folds ß/ä/ö/ü, so an address typed without
    /// umlauts — "Doeblinger Hauptstrasse", "Waehringer Guertel" — resolves
    /// against the register too. Both of those approximations are cached, and a
    /// driver who never clears the cache by hand would otherwise keep the old
    /// "≈" answer for every one of them.
    ///
    /// 5: a street one letter off the register's spelling is now accepted
    /// ("Pfenningeldgasse" for Pfenninggeldgasse), and a matching Stiege on a
    /// different house number no longer is ("9/2" answered with "6-12/2").
    /// The first left an "≈" pin, the second an "≈" pin on the wrong house.
    ///
    /// 6: lettered blocks, "Haus", Kleingarten and Obj./Pav. doors now find
    /// their own building, register answers without a postcode count, and a
    /// neighbouring number ("8B" for "8") is no longer cached as exact.
    private static let generation = 6

    private var hits: [String: CachedGeocode] = [:]
    private var misses: [String: Date] = [:]
    private var loaded = false
    private var dirty = false

    private let fileURL: URL

    /// `directory` is only for tests — the app always wants the default
    /// location, the same reason and the same shape as `AppSchema.container`'s
    /// `url`. Resolved once here rather than recomputed per access, which also
    /// stops the directory being re-created on every single read.
    init(directory: URL? = nil) {
        let dir = directory
            ?? URL.applicationSupportDirectory.appending(
                path: "EarRouter", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appending(path: "geocode-cache.json")
    }

    // MARK: - Lookup

    /// `now` is only for tests, the same way `SideloadExpiry.remaining` takes
    /// one: an exact hit that never goes stale is a promise about time, and a
    /// test that had to wait years to say so would not be written at all.
    func lookup(_ key: String, now: Date = Date()) -> CachedGeocode? {
        load(now: now)
        // A file written before only exact answers were kept can still hold
        // approximations; they are not answers any more.
        guard let hit = hits[key], hit.precision == .exact else { return nil }
        return hit
    }

    /// Remembers an exact answer. Anything less is not kept — see the type.
    func store(
        _ key: String, lat: Double, lon: Double,
        displayName: String, precision: Precision
    ) {
        guard precision == .exact else { return }
        load()
        hits[key] = CachedGeocode(
            lat: lat, lon: lon, displayName: displayName,
            precision: precision, cachedAt: Date())
        // A successful resolution retires any standing "does not exist"
        // verdict for the same address.
        misses.removeValue(forKey: key)
        if hits.count > Self.maxHits { evictOldest() }
        dirty = true
        scheduleSave()
    }

    /// Drops the least recently *written* quarter of the table when it grows
    /// past its ceiling. A quarter at a time rather than one row at a time, so
    /// the sort this costs is paid once every thousand-odd new addresses
    /// instead of on every single one past the limit.
    private func evictOldest() {
        let keep = Self.maxHits - Self.maxHits / 4
        let survivors = hits
            .sorted { $0.value.cachedAt > $1.value.cachedAt }
            .prefix(keep)
        hits = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        log.info("geocode cache trimmed to \(self.hits.count) entries")
    }

    /// True when this exact query was recently confirmed unresolvable. Only
    /// ever records a *definitive* negative — never an upstream outage, which
    /// is a temporary condition and must be retried.
    func isKnownMiss(_ key: String, now: Date = Date()) -> Bool {
        load(now: now)
        guard let at = misses[key] else { return false }
        if now.timeIntervalSince(at) > Self.missTTL {
            misses.removeValue(forKey: key)
            dirty = true
            scheduleSave()
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

    private func load(now: Date = Date()) {
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
            // Marked dirty so the superseded file is actually rewritten. Left
            // clean, the tables are empty in memory but the old rows stay on
            // disk — which is harmless right up until the driver opens
            // Erweitert, is told they have 0 saved addresses, and finds "Cache
            // leeren" greyed out over a file that is not empty at all.
            dirty = true
            save()
            return
        }
        // Exact answers only, the same rule `store` keeps. A file written
        // before that rule still holds approximations, which `lookup` has
        // never served since — but they stayed in the table, counted in
        // Erweitert's "Gespeicherte Adressen" and rewritten on every save.
        hits = payload.hits.filter { $0.value.precision == .exact }
        if hits.count != payload.hits.count { dirty = true }
        // Expired negatives are dead weight — past their TTL they are skipped
        // anyway, so they only ever sit there. Pruned on load rather than on a
        // timer: this table gains a handful of rows a day, and a cold launch
        // is a more than frequent enough broom.
        //
        // And marked dirty when the broom actually swept something, or the
        // pruning only ever happened in memory: the rows came back off disk on
        // the next launch, and were dropped again, for the life of the install.
        let cutoff = now.addingTimeInterval(-Self.missTTL)
        let live = payload.misses.filter { $0.value > cutoff }
        if live.count != payload.misses.count { dirty = true }
        misses = live
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
