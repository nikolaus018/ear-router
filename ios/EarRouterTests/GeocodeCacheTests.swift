import Testing
import Foundation
@testable import EarRouter

/// What the app remembers about an address, and for how long.
///
/// Every rule in here is a decision a driver eventually feels. An exact hit
/// that expired would cost a throttled round trip at the next door; an
/// approximate one that never did would serve the same "≈" pin for a building
/// the register has since learned about. A negative verdict kept too long
/// blacklists an address that got registered yesterday. And the table has the
/// only ceiling anything in this app has, because the whole file is read into
/// memory and rewritten on every save.
///
/// Each case gets its own directory, so nothing here touches the cache the
/// simulator or the developer's own machine is using.
struct GeocodeCacheTests {

    private func makeCache() throws -> (GeocodeCache, URL) {
        let dir = URL.temporaryDirectory
            .appending(path: "geocode-cache-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (GeocodeCache(directory: dir), dir)
    }

    private func store(
        _ cache: GeocodeCache, _ key: String, precision: Precision
    ) async {
        await cache.store(
            key, lat: 48.2301, lon: 16.3201,
            displayName: "Gentzgasse 129, 1180 Wien", precision: precision)
    }

    // MARK: - How long an answer is worth

    /// A confirmed door does not move.
    @Test func anExactHitNeverGoesStale() async throws {
        let (cache, _) = try makeCache()
        await store(cache, "gentzgasse 129, 1180 wien", precision: .exact)

        let inTenYears = Date().addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let hit = await cache.lookup("gentzgasse 129, 1180 wien", now: inTenYears)
        #expect(hit?.precision == .exact)
        #expect(hit?.lat == 48.2301)
    }

    /// An approximation is an admitted guess, asked again every time rather
    /// than remembered — so a better lookup replaces it at once.
    @Test func anApproximationIsNotKept() async throws {
        let (cache, _) = try makeCache()
        await store(cache, "neubaugasse 1, 1070 wien", precision: .street)
        await store(cache, "irgendwo, 1210 wien", precision: .district)
        #expect(await cache.lookup("neubaugasse 1, 1070 wien") == nil)
        #expect(await cache.lookup("irgendwo, 1210 wien") == nil)
    }

    @Test func anAddressNobodyAskedAboutIsNotAHit() async throws {
        let (cache, _) = try makeCache()
        #expect(await cache.lookup("nie gefragt, 1010 wien") == nil)
    }

    // MARK: - The negative twin

    /// A definitive "no geocoder has this address" saves four throttled round
    /// trips — but only for a few hours, because a genuinely new building gets
    /// registered eventually.
    @Test func aMissIsRememberedForHoursAndNotForGood() async throws {
        let (cache, _) = try makeCache()
        await cache.recordMiss("gibtsnicht 1, 1010 wien")

        #expect(await cache.isKnownMiss("gibtsnicht 1, 1010 wien"))

        let inAnHour = Date().addingTimeInterval(60 * 60)
        #expect(await cache.isKnownMiss("gibtsnicht 1, 1010 wien", now: inAnHour))

        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        #expect(!(await cache.isKnownMiss("gibtsnicht 1, 1010 wien", now: tomorrow)))
    }

    /// The address was found after all. The standing verdict has to go, or the
    /// next lookup would skip straight to "not found" over an answer the cache
    /// is holding.
    @Test func aSuccessfulResolutionRetiresTheStandingMiss() async throws {
        let (cache, _) = try makeCache()
        await cache.recordMiss("neubau 1, 1070 wien")
        #expect(await cache.isKnownMiss("neubau 1, 1070 wien"))

        await store(cache, "neubau 1, 1070 wien", precision: .exact)

        #expect(!(await cache.isKnownMiss("neubau 1, 1070 wien")))
        #expect(await cache.lookup("neubau 1, 1070 wien") != nil)
    }

    @Test func anAddressNeverMissedIsNotAKnownMiss() async throws {
        let (cache, _) = try makeCache()
        #expect(!(await cache.isKnownMiss("nie gefragt, 1010 wien")))
    }

    // MARK: - The file

    /// The point of the table: the same door is not looked up twice, across
    /// launches. Read back through a second instance on the same directory,
    /// which is what a relaunch is.
    @Test func whatWasStoredComesBackFromTheFile() async throws {
        let (cache, dir) = try makeCache()
        await store(cache, "gentzgasse 129, 1180 wien", precision: .exact)
        await cache.save()

        let reopened = GeocodeCache(directory: dir)
        let hit = await reopened.lookup("gentzgasse 129, 1180 wien")
        #expect(hit?.lat == 48.2301)
        #expect(hit?.displayName == "Gentzgasse 129, 1180 Wien")
        #expect(await reopened.count == 1)
    }

    @Test func aMissSurvivesARelaunchToo() async throws {
        let (cache, dir) = try makeCache()
        await cache.recordMiss("gibtsnicht 1, 1010 wien")
        await cache.save()

        let reopened = GeocodeCache(directory: dir)
        #expect(await reopened.isKnownMiss("gibtsnicht 1, 1010 wien"))
    }

    /// "Geocode-Cache leeren" in Erweitert, and the count the screen shows
    /// beside it.
    @Test func clearingEmptiesBothTablesAndTheFile() async throws {
        let (cache, dir) = try makeCache()
        await store(cache, "a, 1010 wien", precision: .exact)
        await cache.recordMiss("b, 1010 wien")
        await cache.clear()

        #expect(await cache.count == 0)
        #expect(!(await cache.isKnownMiss("b, 1010 wien")))

        // And the file, not just the tables — the bug the generation check
        // already documents is a cache that reads empty over a file that is
        // not.
        let reopened = GeocodeCache(directory: dir)
        #expect(await reopened.count == 0)
        #expect(await reopened.lookup("a, 1010 wien") == nil)
    }

    /// A file this reader cannot parse is a file to start over from, not a
    /// reason to fail. It is a cache; the worst case is looking an address up
    /// again.
    @Test func agarbledFileStartsEmptyRatherThanFailing() async throws {
        let (_, dir) = try makeCache()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all".utf8)
            .write(to: dir.appending(path: "geocode-cache.json"))

        let cache = GeocodeCache(directory: dir)
        #expect(await cache.count == 0)
        #expect(await cache.lookup("a, 1010 wien") == nil)
    }

    /// Written by an older resolver. Every row in it is an answer this build
    /// knows how to do better, so the whole table goes — and, crucially, the
    /// superseded file is rewritten rather than left on disk, which is what
    /// left Erweitert reporting 0 saved addresses over a file full of them.
    @Test func aFileFromAnOlderResolverIsDroppedAndRewritten() async throws {
        let (_, dir) = try makeCache()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = """
            {"generation":1,\
            "hits":{"gentzgasse 129, 1180 wien":{"lat":48.2,"lon":16.3,\
            "displayName":"alt","precision":"street","cachedAt":0}},\
            "misses":{}}
            """
        let file = dir.appending(path: "geocode-cache.json")
        try Data(stale.utf8).write(to: file)

        let cache = GeocodeCache(directory: dir)
        #expect(await cache.count == 0)
        #expect(await cache.lookup("gentzgasse 129, 1180 wien") == nil)

        // The old rows are gone from the file as well, so a second launch does
        // not find them sitting there again.
        let onDisk = try Data(contentsOf: file)
        #expect(!String(decoding: onDisk, as: UTF8.self).contains("gentzgasse"))
    }

    /// A file of this generation written before only exact answers were kept.
    /// Its approximations have not been served since, and must not go on
    /// being counted as saved addresses or rewritten on every save either.
    @Test func approximationsInAnOlderFileAreDroppedOnLoad() async throws {
        let (_, dir) = try makeCache()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = """
            {"generation":6,"misses":{},"hits":{\
            "exakt, 1180 wien":{"lat":48.2,"lon":16.3,"displayName":"a","precision":"exact","cachedAt":0},\
            "ungefähr, 1180 wien":{"lat":48.2,"lon":16.3,"displayName":"b","precision":"street","cachedAt":0}}}
            """
        try Data(file.utf8).write(to: dir.appending(path: "geocode-cache.json"))

        let cache = GeocodeCache(directory: dir)
        #expect(await cache.count == 1)
        #expect(await cache.lookup("exakt, 1180 wien") != nil)
    }

    // MARK: - The ceiling

    /// The only bound anything in this app has. Past it the table is trimmed a
    /// quarter at a time, so the sort is paid once every thousand-odd new
    /// addresses rather than on every one.
    @Test func thetableIsTrimmedOnceItGrowsPastItsCeiling() async throws {
        let (cache, _) = try makeCache()
        for i in 0...5_000 {
            await store(cache, "strasse \(i), 1100 wien", precision: .exact)
        }
        let count = await cache.count
        #expect(count == 3_750)
        #expect(count < 5_000)
    }
}
