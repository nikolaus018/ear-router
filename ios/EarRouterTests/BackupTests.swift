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

    /// A lost phone is a lost year of tours, and since outcomes exist it is
    /// also a lost record of who did not get their food. All of it has to make
    /// the trip through the file.
    @Test func whatHappenedAtEachDoorSurvivesTheFile() throws {
        let source = try makeContext()
        let context = source
        let route = Route(name: "Tour 14.09.2026")
        context.insert(route)

        let when = Date(timeIntervalSince1970: 1_757_000_000)
        let missed = Stop(
            kind: .customer, kunde: "Fr. Novak", strasse: "Gentzgasse 4", plz: "1180",
            lat: 48.2301, lon: 16.3201, orderIndex: 1)
        missed.record(.notHome, at: when)
        let urgent = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 9", plz: "1180",
            lat: 48.2302, lon: 16.3202, orderIndex: 2)
        urgent.prioritaet = true
        urgent.record(.neighbour, at: when)
        for s in [missed, urgent] {
            s.route = route
            context.insert(s)
        }
        try context.save()

        let archive = try roundTrip(BackupArchive.make(from: source))
        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let restored = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        let novak = try #require(restored.customerStops.first { $0.kunde == "Fr. Novak" })
        #expect(novak.outcome == .notHome)
        #expect(!novak.delivered)
        #expect(novak.settledAt == when)

        let gruber = try #require(restored.customerStops.first { $0.kunde == "Fam. Gruber" })
        #expect(gruber.outcome == .neighbour)
        #expect(gruber.delivered)
        #expect(gruber.prioritaet)
    }

    /// A file written before any of this existed restores as it always did: a
    /// ticked stop is a delivery, and nothing else is claimed about it.
    @Test func anOlderBackupStillRestoresItsDeliveredTicks() throws {
        let source = try makeContext()
        try seed(source)
        var archive = try roundTrip(BackupArchive.make(from: source))

        // Strip the fields an older writer would not have written.
        for i in archive.routes.indices {
            for j in archive.routes[i].stops.indices {
                archive.routes[i].stops[j].outcome = nil
                archive.routes[i].stops[j].settledAt = nil
                archive.routes[i].stops[j].prioritaet = nil
            }
        }

        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let restored = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        let delivered = try #require(restored.customerStops.first { $0.delivered })
        #expect(delivered.outcome == .delivered)
        #expect(delivered.settledAt == nil)
        #expect(!delivered.prioritaet)
        #expect(restored.customerStops.contains { $0.outcome == nil })
    }


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

    /// Globale Infos shared with a stand-in go out under a name of their own.
    /// Named like a backup, the file read as a whole phone's worth — and a
    /// full replace from it leaves no tours at all.
    @Test func sharedGlobaleInfosAreNotNamedLikeABackup() throws {
        var archive = BackupArchive()
        archive.stockwerke = [
            BackupArchive.StockwerkBackup(
                key: "fam gruber|gentzgasse 129|1180", kunde: "Fam. Gruber",
                strasse: "Gentzgasse 129", plz: "1180", stockwerk: "3", dontAsk: false,
                updatedAt: Date())
        ]
        let url = try archive.writeForSharing(
            named: BackupArchive.customerInfoPrefix,
            now: Date(timeIntervalSince1970: 1_788_696_000))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.lastPathComponent == "EAR-Router-Globale-Infos-2026-09-06.json")
        #expect(try BackupArchive.decode(try Data(contentsOf: url)).stockwerkCount == 1)
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

    // MARK: - What a tour keeps outside the store

    /// A replace lets go of it for the tours that are gone, and leaves it with
    /// a tour the file brings back under its own id.
    @Test func replacingForgetsWhatTheGoneToursKeptOutsideTheStore() throws {
        let context = try makeContext()
        let kept = try RouteStore.createRoute(name: "Bleibt", in: context)
        let archive = try roundTrip(BackupArchive.make(from: context))
        let gone = try RouteStore.createRoute(name: "Weg", in: context)
        let (keptID, goneID) = (kept.id, gone.id)
        let link = PortalTourLink(tourID: 7, tourName: "VM 4", date: Date())
        let left = Date(timeIntervalSince1970: 1_757_000_000)
        for id in [keptID, goneID] {
            link.save(for: id)
            UserDefaults.standard.set(left, forKey: "tour.departure.\(id.uuidString)")
        }
        defer {
            for id in [keptID, goneID] {
                PortalTourLink.forget(id)
                TourDeparture.forget(id)
            }
        }

        try BackupRestore.apply(archive, mode: .replace, in: context)

        #expect(PortalTourLink.load(for: goneID) == nil)
        #expect(TourDeparture.load(for: goneID) == nil)
        #expect(PortalTourLink.load(for: keptID) == link)
        #expect(TourDeparture.load(for: keptID) == left)
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

    /// The case the format name actually exists for.
    ///
    /// Both files above are refused before the name is ever looked at — one is
    /// an array and one is not JSON, so neither decodes. But this reader is
    /// deliberately lenient about missing keys, so a JSON *object* that is not
    /// a backup decodes perfectly happily into an empty one, and the only thing
    /// standing between that and "0 Touren wiederhergestellt" is the name.
    @Test func refusesAJSONObjectThatDecodesButIsNotABackup() throws {
        for notABackup in [
            #"{"hello":"world"}"#,
            #"{"routes":[],"stockwerke":[]}"#,            // the right shape, no name
            #"{"format":"ear-router-export","version":1}"#, // a name, the wrong one
            #"{}"#,
        ] {
            #expect(throws: AppError.self) {
                try BackupArchive.decode(Data(notABackup.utf8))
            }
        }

        // And the name on its own is enough to be read, however little else
        // the file carries — a backup is read on the day something has already
        // gone wrong.
        let bare = #"{"format":"ear-router-backup","version":1}"#
        let archive = try BackupArchive.decode(Data(bare.utf8))
        #expect(archive.routeCount == 0)
        #expect(archive.stockwerkCount == 0)
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

    /// A file listing one tour twice restores it once.
    ///
    /// Nothing this app writes can produce that, but a backup is read on the
    /// day something has already gone wrong — two files concatenated by hand,
    /// an edit in a text editor — and "is this tour already here?" used to be
    /// asked only of the store, never of the rest of the same file. Two Route
    /// rows then carried one id, which is one too few for everything that looks
    /// a tour up by it: deleting one would take out both.
    @Test func aTourListedTwiceInOneFileIsRestoredOnce() throws {
        let source = try makeContext()
        try seed(source)

        var archive = try roundTrip(BackupArchive.make(from: source))
        let only = try #require(archive.routes.first)
        archive.routes.append(only)

        let fresh = try makeContext()
        let outcome = try BackupRestore.apply(archive, mode: .replace, in: fresh)
        #expect(outcome.routesAdded == 1)
        #expect(outcome.routesSkipped == 1)

        let restored = try fresh.fetch(FetchDescriptor<Route>())
        #expect(restored.count == 1)
        #expect(Set(restored.map(\.id)).count == restored.count)
    }

    /// A file that names one *stop* twice keeps both customers, under ids of
    /// their own.
    ///
    /// The tour above is skipped on a clashing id because a tour already here
    /// is that tour. A stop cannot be skipped on those grounds: the file is
    /// being read by somebody who wants their customers back, and a silently
    /// dropped one is not something they can see. Two rows under one id is the
    /// worse outcome anyway — the list numbers them as one, the door grouping
    /// counts them as one, and the optimizer writes a leg to only one.
    @Test func aStopListedTwiceInOneFileKeepsBothUnderTheirOwnIDs() throws {
        let source = try makeContext()
        try seed(source)

        var archive = try roundTrip(BackupArchive.make(from: source))
        var route = try #require(archive.routes.first)
        let duplicated = try #require(route.stops.first { $0.kunde == "Fam. Gruber" })
        route.stops.append(duplicated)
        archive.routes = [route]

        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let stops = try fresh.fetch(FetchDescriptor<Stop>())
        #expect(Set(stops.map(\.id)).count == stops.count)
        // Both are on the tour, and both are still Fam. Gruber.
        #expect(stops.count { $0.kunde == "Fam. Gruber" } == 2)
        // One of them kept the file's own id — a duplicate is not a reason to
        // renumber the stop that was there first.
        #expect(stops.contains { $0.id == duplicated.id })
    }

    /// The floor still lands, because nothing persistent is keyed by a stop's
    /// id — `StockwerkKey` is the customer and their address. This is what
    /// makes handing a duplicate a fresh id cost nothing.
    @Test func aReIDedStopStillFindsItsFloor() throws {
        let source = try makeContext()
        try seed(source)

        var archive = try roundTrip(BackupArchive.make(from: source))
        var route = try #require(archive.routes.first)
        let duplicated = try #require(route.stops.first { $0.kunde == "Fam. Gruber" })
        route.stops.append(duplicated)
        archive.routes = [route]

        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let restored = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        let notes = try StockwerkStore.all(in: fresh)
        let floors = notes.floors(for: restored.orderedStops)
        // Both copies of the household read the same floor.
        for gruber in restored.customerStops where gruber.kunde == "Fam. Gruber" {
            #expect(floors[gruber.id] == "3")
        }
    }

    // MARK: - The settings that travel with the file

    /// Captured and restored through the same list of keys, so the two halves
    /// cannot drift. Only `restore` had a test; this is the other direction.
    @Test func theSettingsSurviveBeingCapturedAndRestored() throws {
        let defaults = UserDefaults.standard
        let keys = [
            Kilometerstand.lastKey, Kilometerstand.hasLastKey,
            Kilometerstand.savedAtKey, NavigationHandoff.providerKey,
            CarPlayNavigation.enabledKey, Upstreams.Keys.osrmURL,
        ]
        let before = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in before {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set(132_000.5, forKey: Kilometerstand.lastKey)
        defaults.set(true, forKey: Kilometerstand.hasLastKey)
        defaults.set(1_757_000_000.0, forKey: Kilometerstand.savedAtKey)
        defaults.set("waze", forKey: NavigationHandoff.providerKey)
        defaults.set(true, forKey: CarPlayNavigation.enabledKey)
        defaults.set("https://osrm.example.com", forKey: Upstreams.Keys.osrmURL)

        let captured = Settings.capture()

        for key in keys { defaults.removeObject(forKey: key) }
        Settings.restore(captured)

        #expect(defaults.double(forKey: Kilometerstand.lastKey) == 132_000.5)
        #expect(defaults.bool(forKey: Kilometerstand.hasLastKey))
        #expect(defaults.double(forKey: Kilometerstand.savedAtKey) == 1_757_000_000.0)
        #expect(NavigationHandoff.provider == .waze)
        // A Bool, and one that has to come back as a Bool rather than as the
        // string "1": `@AppStorage` reads it with `bool(forKey:)`, and the
        // switch in Mehr would sit there off with the value right beside it.
        #expect(CarPlayNavigation.isEnabled())
        #expect(Upstreams.current.osrm.absoluteString == "https://osrm.example.com")
    }

    /// The home address comes back as one `HomeAddress.load` can read: the
    /// position as a `Double`, not the string it travelled as, or the switch
    /// on the tour would find no home on a phone that plainly has one.
    @Test func theHomeAddressSurvivesBeingCapturedAndRestored() throws {
        let defaults = UserDefaults.standard
        let keys = [
            HomeAddress.Keys.strasse, HomeAddress.Keys.plz,
            HomeAddress.Keys.lat, HomeAddress.Keys.lon,
        ]
        let before = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in before {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let home = HomeAddress(
            strasse: "Gentzgasse 129", plz: "1180", lat: 48.2283, lon: 16.3389)
        home.save(to: defaults)

        let captured = Settings.capture()
        #expect(captured[HomeAddress.Keys.strasse] == "Gentzgasse 129")

        HomeAddress.clear(in: defaults)
        Settings.restore(captured)

        #expect(HomeAddress.load(from: defaults) == home)
    }

    /// A trip meter that has just been reset really does read 0, and that is a
    /// value worth carrying like any other — which is the whole reason
    /// `hasLastReading` is stored separately from the reading.
    @Test func aRememberedZeroIsCarriedRatherThanTreatedAsNothing() throws {
        let defaults = UserDefaults.standard
        let keys = [Kilometerstand.lastKey, Kilometerstand.hasLastKey]
        let before = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in before {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        defaults.set(0.0, forKey: Kilometerstand.lastKey)
        defaults.set(true, forKey: Kilometerstand.hasLastKey)

        let captured = Settings.capture()
        #expect(captured[Kilometerstand.hasLastKey] == "1")

        for key in keys { defaults.removeObject(forKey: key) }
        Settings.restore(captured)

        #expect(defaults.double(forKey: Kilometerstand.lastKey) == 0)
        #expect(defaults.bool(forKey: Kilometerstand.hasLastKey))
    }

    /// Merging is idempotent, and the rule that makes it so is that the
    /// *newer* answer wins — not an equally old one. Two phones asked about
    /// the same stairwell disagree only about when.
    @Test func mergingAnEquallyOldAnswerWritesNothing() throws {
        let context = try makeContext()
        try seed(context)
        // Whole seconds on purpose. The file encodes dates as ISO-8601, which
        // drops anything finer — so a note written at a real instant comes back
        // *older* than itself, and a test built on that would be exercising
        // "older wins", not "equal does not". (It was, until this line.)
        for note in try StockwerkStore.all(in: context) {
            note.updatedAt = Date(timeIntervalSince1970: 1_757_000_000)
        }
        try context.save()
        let archive = try roundTrip(BackupArchive.make(from: context))

        // Same file, same timestamps, straight back onto the phone it came
        // from. Nothing in it is newer than what is already stored.
        let outcome = try BackupRestore.apply(archive, mode: .merge, in: context)
        #expect(outcome.stockwerkeWritten == 0)
        #expect(outcome.routesAdded == 0)
        #expect(outcome.routesSkipped == 1)
    }

    // MARK: - Every field, and every field that is ever added

    /// The bug this file exists to stop happening twice.
    ///
    /// `StopBackup` once had no `telefon`, so every backup written omitted the
    /// number the Anrufen button runs on and every restore lost it for good.
    /// That shipped, and nothing in this suite noticed — the round-trip test
    /// above spot-checks a handful of fields, and a field nobody thought to
    /// name is exactly the field that goes missing.
    ///
    /// So this names all of them, with a distinct value each, so a field that
    /// is dropped *or* wired to the wrong neighbour fails here.
    @Test func everyFieldOfAStopSurvivesTheFile() throws {
        let source = try makeContext()
        let route = try RouteStore.createRoute(name: "Tour", in: source)
        let stop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", paket: "2x Menü", notiz: "Bitte laut klingeln",
            telefon: "+4369910842229",
            lat: 48.2301, lon: 16.3201, orderIndex: 7,
            precision: .street, pinned: true, excluded: false)
        stop.delivered = true
        stop.nextLegKm = 3.25
        stop.nextLegMin = 8.5
        stop.createdAt = Date(timeIntervalSince1970: 1_757_000_123)
        stop.route = route
        source.insert(stop)
        try source.save()

        let archive = try roundTrip(BackupArchive.make(from: source))
        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let restoredRoute = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        let back = try #require(restoredRoute.customerStops.first { $0.kunde == "Fam. Gruber" })

        #expect(back.id == stop.id)
        #expect(back.kind == .customer)
        #expect(back.kunde == "Fam. Gruber")
        #expect(back.strasse == "Gentzgasse 129/1")
        #expect(back.plz == "1180")
        #expect(back.paket == "2x Menü")
        #expect(back.notiz == "Bitte laut klingeln")
        #expect(back.telefon == "+4369910842229")
        #expect(back.lat == 48.2301)
        #expect(back.lon == 16.3201)
        #expect(back.orderIndex == 7)
        #expect(back.delivered)
        #expect(back.nextLegKm == 3.25)
        #expect(back.nextLegMin == 8.5)
        #expect(back.createdAt == Date(timeIntervalSince1970: 1_757_000_123))
        #expect(back.excluded == false)
        #expect(back.pinned)
        #expect(back.precision == .street)
        // The relationship is the nesting itself, so it is not a field in the
        // file — but it has to come back, or the stop belongs to no tour.
        #expect(back.route?.id == route.id)
    }

    /// The same, for a switched-off fixed point, which is the one place
    /// `excluded` is ever true.
    @Test func aSwitchedOffFixedPointComesBackSwitchedOff() throws {
        let source = try makeContext()
        let route = try RouteStore.createRoute(name: "Tour", in: source)
        let via = try #require(route.stops.first { $0.kind == .via })
        via.excluded = true
        try source.save()

        let archive = try roundTrip(BackupArchive.make(from: source))
        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let back = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        #expect(back.stops.first { $0.kind == .via }?.excluded == true)
        #expect(back.stops.first { $0.kind == .start }?.excluded == false)
    }

    @Test func everyFieldOfARouteSurvivesTheFile() throws {
        let source = try makeContext()
        let route = try RouteStore.createRoute(name: "VM 4 DO Vormittag", in: source)
        route.status = .completed
        route.completedAt = Date(timeIntervalSince1970: 1_757_000_456)
        route.createdAt = Date(timeIntervalSince1970: 1_756_000_000)
        try source.save()

        let archive = try roundTrip(BackupArchive.make(from: source))
        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let back = try #require(try fresh.fetch(FetchDescriptor<Route>()).first)
        #expect(back.id == route.id)
        #expect(back.name == "VM 4 DO Vormittag")
        #expect(back.status == .completed)
        #expect(back.createdAt == Date(timeIntervalSince1970: 1_756_000_000))
        #expect(back.completedAt == Date(timeIntervalSince1970: 1_757_000_456))
        // The two deliberate deviations, both documented in `make`: the driven
        // line is derived and is left out, and what comes back is therefore
        // flagged for reoptimising however it was flagged when it was written.
        #expect(back.geometryFlat.isEmpty)
        #expect(back.needsOptimize)
    }

    @Test func everyFieldOfAFloorSurvivesTheFile() throws {
        let source = try makeContext()
        let route = try RouteStore.createRoute(name: "Tour", in: source)
        let stop = Stop(
            kind: .customer, kunde: "Fam. Gruber", strasse: "Gentzgasse 129/1",
            plz: "1180", lat: 48.2301, lon: 16.3201)
        stop.route = route
        source.insert(stop)
        try StockwerkStore.save(stockwerk: "2/Tür 14", dontAsk: true, for: stop, in: source)
        let written = try #require(try StockwerkStore.note(for: stop, in: source))
        written.updatedAt = Date(timeIntervalSince1970: 1_757_000_789)
        try source.save()

        let archive = try roundTrip(BackupArchive.make(from: source))
        let fresh = try makeContext()
        try BackupRestore.apply(archive, mode: .replace, in: fresh)

        let back = try #require(try StockwerkStore.all(in: fresh).first)
        #expect(back.key == written.key)
        #expect(back.kunde == "Fam. Gruber")
        #expect(back.strasse == "Gentzgasse 129/1")
        #expect(back.plz == "1180")
        #expect(back.stockwerk == "2/Tür 14")
        #expect(back.dontAsk)
        #expect(back.updatedAt == Date(timeIntervalSince1970: 1_757_000_789))
    }

    /// And the guard for the *next* field somebody adds.
    ///
    /// The tests above pin the fields that exist today; this one fails the
    /// moment a new one appears on a model, whether or not anybody thought
    /// about the backup. Every stored property has to be listed here as either
    /// carried by the file or deliberately left out — and choosing between
    /// those two is the decision that was missed last time.
    @Test func everyStoredPropertyIsEitherCarriedOrDeliberatelyLeftOut() throws {
        let live = Schema(versionedSchema: EarRouterSchemaV4.self)
        func properties(_ entity: String) -> Set<String> {
            Set((live.entities.first { $0.name == entity }?.properties ?? []).map(\.name))
        }

        #expect(properties("Stop") == [
            // Carried, field for field — see `everyFieldOfAStopSurvivesTheFile`.
            "id", "kindRaw", "kunde", "strasse", "plz", "paket", "notiz", "telefon",
            "lat", "lon", "orderIndex", "delivered", "nextLegKm", "nextLegMin",
            "createdAt", "excluded", "pinned", "precisionRaw",
            // Left out on purpose: the tour a stop belongs to is the nesting.
            "route",
        ])

        #expect(properties("Route") == [
            "id", "name", "statusRaw", "createdAt", "completedAt",
            // Left out on purpose: derived, several thousand doubles per route,
            // and one "Neu optimieren" rebuilds it. See `BackupArchive.make`.
            "geometryFlat",
            // Written as true regardless, for the same reason.
            "needsOptimize",
            // The nesting again, in the other direction.
            "stops",
        ])

        #expect(properties("StockwerkNote") == [
            "key", "kunde", "strasse", "plz", "stockwerk", "dontAsk", "updatedAt",
            // Left out on purpose: a floor is identified by its key across
            // phones, and a restore makes a fresh row for it.
            "id",
        ])
    }

    /// A setting the driver never touched is not carried at all, rather than
    /// carried as a zero that would then overwrite the new phone's own.
    @Test func anUnsetSettingIsNotCaptured() throws {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: Upstreams.Keys.osrmURL)
        defaults.removeObject(forKey: Upstreams.Keys.osrmURL)
        defer { if let before { defaults.set(before, forKey: Upstreams.Keys.osrmURL) } }

        #expect(Settings.capture()[Upstreams.Keys.osrmURL] == nil)
    }
}
