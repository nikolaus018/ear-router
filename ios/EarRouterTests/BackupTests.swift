import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// A backup is only worth what comes back out of it.
///
/// Every case here goes through the real file bytes — encode, decode, restore
/// — rather than handing the in-memory struct straight back, because the whole
/// point of the feature is a file that survives a new phone, and the encoder is
/// exactly where a `Date` or a raw enum quietly stops round-tripping.
@MainActor
struct BackupTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// A day's work: one tour, half of it delivered, and two doors learned.
    @discardableResult
    private func seed(_ context: ModelContext) throws -> Route {
        let route = try RouteStore.createRoute(name: "Tour 05.09.2026", in: context)
        route.status = .completed
        route.completedAt = Date(timeIntervalSince1970: 1_757_000_000)

        let delivered = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", paket: "2 Menü", notiz: "Bitte laut klingeln",
            lat: 48.2301, lon: 16.3201, orderIndex: 3,
            precision: .street, pinned: true)
        delivered.delivered = true
        delivered.nextLegKm = 3.2
        delivered.nextLegMin = 8
        let open = Stop(
            kind: .customer, kunde: "Fam. Novak", strasse: "Währinger Straße 4",
            plz: "1180", lat: 48.2312, lon: 16.3222, orderIndex: 4)
        for s in [delivered, open] {
            s.route = route
            context.insert(s)
        }

        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: delivered, in: context)
        try StockwerkStore.save(stockwerk: nil, dontAsk: true, for: open, in: context)
        try context.save()
        return route
    }

    /// Encode and decode, exactly as the file does it.
    private func roundTrip(_ archive: BackupArchive) throws -> BackupArchive {
        try BackupArchive.decode(archive.encoded())
    }

    // MARK: - Round trip

    @Test func aRestoredTourIsTheTourThatWasBackedUp() throws {
        let source = try makeContext()
        try seed(source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let routes = try fresh.fetch(FetchDescriptor<Route>())
        #expect(routes.count == 1)
        let route = try #require(routes.first)
        #expect(route.name == "Tour 05.09.2026")
        #expect(route.status == .completed)
        #expect(route.stops.count == 5)

        // The delivered tick above all: it is the one thing on a tour that
        // cannot be reconstructed from anywhere else.
        let gruber = try #require(route.customerStops.first { $0.kunde == "Fam. Gruber" })
        #expect(gruber.delivered)
        #expect(gruber.paket == "2 Menü")
        #expect(gruber.notiz == "Bitte laut klingeln")
        #expect(gruber.precision == .street)
        #expect(gruber.pinned)
        #expect(gruber.lat == 48.2301)
        #expect(gruber.nextLegKm == 3.2)
        #expect(route.customerStops.first { $0.kunde == "Fam. Novak" }?.delivered == false)

        // And the fixed points keep being fixed points rather than becoming
        // three unlabelled customers.
        #expect(route.stops.contains { $0.kind == .start })
        #expect(route.stops.contains { $0.kind == .via })
        #expect(route.stops.contains { $0.kind == .end })
    }

    @Test func everyDoorComesBackWithIt() throws {
        let source = try makeContext()
        try seed(source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let notes = try StockwerkStore.all(in: fresh)
        #expect(notes.count == 2)
        #expect(notes.contains { $0.stockwerk == "3" })
        #expect(notes.contains { $0.dontAsk && $0.stockwerk == nil })
    }

    /// The restored route's floor must land on the restored stop — which only
    /// happens if the key survived the file.
    @Test func aRestoredStopStillKnowsItsFloor() throws {
        let source = try makeContext()
        try seed(source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let route = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        let gruber = try #require(route.customerStops.first { $0.kunde == "Fam. Gruber" })
        #expect(!StockwerkStore.shouldAsk(gruber, in: fresh))

        let floors = try StockwerkStore.all(in: fresh).floors(for: route.orderedStops)
        #expect(floors[gruber.id] == "3")
    }

    // MARK: - Replace

    @Test func replacingLeavesNothingOfWhatWasThere() throws {
        let source = try makeContext()
        try seed(source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        let target = try makeContext()
        let doomed = try RouteStore.createRoute(name: "Alte Tour", in: target)
        let doomedID = doomed.id
        let strayStop = Stop(
            kind: .customer, kunde: "Alt", strasse: "Alte Gasse 1", plz: "1010",
            lat: 48.2, lon: 16.3)
        strayStop.route = doomed
        target.insert(strayStop)
        try StockwerkStore.save(stockwerk: "9", dontAsk: false, for: strayStop, in: target)

        try BackupRestore.apply(archive, mode: .replace, in: target)

        let routes = try target.fetch(FetchDescriptor<Route>())
        #expect(routes.count == 1)
        #expect(!routes.contains { $0.id == doomedID })
        // The stops of a deleted route go with it rather than being left
        // behind unattached.
        let stops = try target.fetch(FetchDescriptor<Stop>())
        #expect(!stops.contains { $0.kunde == "Alt" })
        #expect(try StockwerkStore.all(in: target).count == 2)
    }

    /// The ordinary restore: a backup of this phone, loaded back onto this
    /// phone. Every route in the file is already here, under the same id.
    ///
    /// `apply` deletes the routes and then reads back which ids still exist to
    /// decide what to insert. If that read ever stopped seeing the deletions as
    /// pending, every route would look like one already present, all of them
    /// would be skipped, and a replace would empty the store and put nothing
    /// back. That is the worst thing this feature could do, so it is pinned.
    @Test func replacingWithABackupOfItselfKeepsEverything() throws {
        let context = try makeContext()
        let route = try seed(context)
        let routeID = route.id
        let archive = try roundTrip(BackupArchive.make(from: context))

        let outcome = try BackupRestore.apply(archive, mode: .replace, in: context)

        #expect(outcome.routesAdded == 1)
        #expect(outcome.routesSkipped == 0)

        let routes = try context.fetch(FetchDescriptor<Route>())
        #expect(routes.count == 1)
        #expect(routes.first?.id == routeID)
        let restored = try #require(routes.first)
        #expect(restored.stops.count == 5)
        #expect(restored.customerStops.first { $0.kunde == "Fam. Gruber" }?.delivered == true)
        #expect(try StockwerkStore.all(in: context).count == 2)
    }

    // MARK: - Merge

    @Test func mergingKeepsWhatIsAlreadyThere() throws {
        let source = try makeContext()
        try seed(source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        let target = try makeContext()
        let mine = try RouteStore.createRoute(name: "Eigene Tour", in: target)
        let mineID = mine.id

        let outcome = try BackupRestore.apply(archive, mode: .merge, in: target)

        #expect(outcome.routesAdded == 1)
        let routes = try target.fetch(FetchDescriptor<Route>())
        #expect(routes.count == 2)
        #expect(routes.contains { $0.id == mineID })
    }

    /// Loading the same backup twice must not double the tours — the id is
    /// what says "this is that tour", and a driver who taps the wrong button
    /// twice should get nothing the second time.
    @Test func mergingTheSameBackupTwiceChangesNothingTheSecondTime() throws {
        let source = try makeContext()
        try seed(source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        let target = try makeContext()
        try BackupRestore.apply(archive, mode: .merge, in: target)
        let second = try BackupRestore.apply(archive, mode: .merge, in: target)

        #expect(second.routesAdded == 0)
        #expect(second.routesSkipped == 1)
        #expect(try target.fetch(FetchDescriptor<Route>()).count == 1)
        #expect(try StockwerkStore.all(in: target).count == 2)
    }

    @Test func aMergedFloorOnlyWinsWhenItIsTheNewerAnswer() throws {
        let source = try makeContext()
        let stop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", lat: 48.23, lon: 16.32)
        source.insert(stop)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        // The phone already knows this door, and was told more recently.
        let target = try makeContext()
        let sameStop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129 / 1",
            plz: "1180", lat: 48.23, lon: 16.32)
        target.insert(sameStop)
        try StockwerkStore.save(stockwerk: "5", dontAsk: false, for: sameStop, in: target)
        let newer = try #require(try StockwerkStore.all(in: target).first)
        newer.updatedAt = Date().addingTimeInterval(60)
        try target.save()

        try BackupRestore.apply(archive, mode: .merge, in: target)

        let notes = try StockwerkStore.all(in: target)
        #expect(notes.count == 1)
        #expect(notes.first?.stockwerk == "5")
    }

    @Test func anOlderStoredAnswerGivesWayToTheBackup() throws {
        let source = try makeContext()
        let stop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", lat: 48.23, lon: 16.32)
        source.insert(stop)
        try StockwerkStore.save(stockwerk: "3", dontAsk: false, for: stop, in: source)
        let archive = try roundTrip(BackupArchive.make(from: source))

        let target = try makeContext()
        let sameStop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", lat: 48.23, lon: 16.32)
        target.insert(sameStop)
        try StockwerkStore.save(stockwerk: "5", dontAsk: false, for: sameStop, in: target)
        let older = try #require(try StockwerkStore.all(in: target).first)
        older.updatedAt = Date(timeIntervalSince1970: 1)
        try target.save()

        try BackupRestore.apply(archive, mode: .merge, in: target)
        #expect(try StockwerkStore.all(in: target).first?.stockwerk == "3")
    }

    // MARK: - The file that gets shared

    /// What the share sheet hands on is a real file with a real name, and its
    /// bytes have to be the backup — this is the path every restore starts
    /// from.
    @Test func writesAShareableFileThatReadsBackAsTheBackup() throws {
        let source = try makeContext()
        try seed(source)
        let archive = try BackupArchive.make(from: source)

        // Midday UTC on 6 September 2026, so the day cannot slide either way
        // when the name is formatted in the device's own timezone.
        let url = try archive.writeForSharing(
            now: Date(timeIntervalSince1970: 1_788_696_000))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent == "EAR-Router-Sicherung-2026-09-06.json")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reread = try BackupArchive.decode(try Data(contentsOf: url))
        #expect(reread.routeCount == archive.routeCount)
        #expect(reread.stockwerkCount == archive.stockwerkCount)
    }

    /// Each export replaces the last. These files are a full copy of every
    /// customer's name and address, and one per tap would pile up in the
    /// temporary folder for the life of the install.
    @Test func eachExportReplacesTheOneBeforeIt() throws {
        let context = try makeContext()
        try seed(context)
        let archive = try BackupArchive.make(from: context)

        _ = try archive.writeForSharing(now: Date(timeIntervalSince1970: 1_788_609_600))
        let second = try archive.writeForSharing(now: Date(timeIntervalSince1970: 1_788_696_000))

        let folder = second.deletingLastPathComponent()
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left == [second.lastPathComponent])
    }

    // MARK: - Settings

    /// A replace is "this file is now the phone", so the settings in it apply.
    @Test func replacingTakesTheSettingsFromTheFile() throws {
        let context = try makeContext()
        var archive = try roundTrip(BackupArchive.make(from: context))
        archive.settings = [Kilometerstand.lastKey: "132000"]

        let defaults = UserDefaults.standard
        defaults.set(99.0, forKey: Kilometerstand.lastKey)
        defer { defaults.removeObject(forKey: Kilometerstand.lastKey) }

        try BackupRestore.apply(archive, mode: .replace, in: context)
        Settings.restore(archive.settings)

        #expect(defaults.double(forKey: Kilometerstand.lastKey) == 132_000)
    }

    /// A merge is "add this to what I have". Reaching for an old backup to get
    /// a few Stockwerke back must not wind the odometer reading in the
    /// Kilometerstand tool back to whatever it was that month — that number
    /// gets written into the vehicle log.
    @Test func mergingLeavesTheSettingsOnThisPhoneAlone() throws {
        let context = try makeContext()
        var archive = try roundTrip(BackupArchive.make(from: context))
        archive.settings = [Kilometerstand.lastKey: "132000"]

        let defaults = UserDefaults.standard
        defaults.set(145_000.0, forKey: Kilometerstand.lastKey)
        defer { defaults.removeObject(forKey: Kilometerstand.lastKey) }

        // The merge path in `BackupView` deliberately does not call
        // `Settings.restore`; the restore itself must not touch them either.
        try BackupRestore.apply(archive, mode: .merge, in: context)

        #expect(defaults.double(forKey: Kilometerstand.lastKey) == 145_000)
    }

    // MARK: - Refusing what is not a backup

    @Test func refusesAFileThatIsNotABackup() throws {
        // The other JSON this app deals in: a pasted list of customer stops.
        let stops = #"[{"kunde":"Fam. Gruber","strasse":"Gentzgasse 129","plz":"1180"}]"#
        #expect(throws: AppError.self) {
            try BackupArchive.decode(Data(stops.utf8))
        }
        #expect(throws: AppError.self) {
            try BackupArchive.decode(Data("nonsense".utf8))
        }
    }

    @Test func refusesABackupFromANewerApp() throws {
        var archive = BackupArchive()
        archive.version = BackupArchive.currentVersion + 1
        let data = try archive.encoded()
        #expect(throws: AppError.self) { try BackupArchive.decode(data) }
    }

    // MARK: - What is deliberately not in the file

    /// The driven line is the biggest thing in the store and the only part of
    /// it the app can rebuild, so it is left out — and a restored tour says so
    /// rather than drawing a line that is quietly out of date.
    @Test func restoredToursAreFlaggedForReoptimizing() throws {
        let source = try makeContext()
        let route = try seed(source)
        route.geometryFlat = [48.2, 16.3, 48.21, 16.31]
        route.needsOptimize = false
        try source.save()

        let archive = try roundTrip(BackupArchive.make(from: source))
        #expect(try !archive.encoded().isEmpty)

        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)
        let restored = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        #expect(restored.geometryFlat.isEmpty)
        #expect(restored.needsOptimize)
    }
}
