import Foundation
import SwiftData

/// The whole store, as one file.
///
/// Everything in this app lives on one phone and nowhere else — that is the
/// point of it, and it is also the risk: a lost phone is a lost year of tours
/// and, now, of everything learned about the doors on them. This is the way
/// out. One JSON file, readable, restorable onto a new phone or a reinstall.
///
/// Deliberately not the SwiftData store file itself. A copied `.store` is
/// opaque, tied to a schema version, and unopenable the moment the model
/// changes; this describes the data instead, so a backup written today is still
/// readable by a build that has moved on.
struct BackupArchive: Codable, Sendable {
    /// Named so a file picked out of a folder of JSON can be recognised — and
    /// so a route paste (a bare array of stops) is refused with a sentence
    /// rather than a decoding error.
    static let formatName = "ear-router-backup"
    /// The archive's *own* version, not the store's. Bumped only when this
    /// shape changes in a way an older reader would get wrong.
    static let currentVersion = 1

    var format: String = BackupArchive.formatName
    var version: Int = BackupArchive.currentVersion
    var createdAt: Date = Date()
    /// Which build wrote it. Never read by the importer — it is here for the
    /// morning someone has to work out why one file restores differently.
    var app: String?

    var routes: [RouteBackup] = []
    var stockwerke: [StockwerkBackup] = []
    var settings: [String: String] = [:]

    init() {}

    /// Hand-written so that a key this reader does not find is a key the file
    /// did not have, rather than a decode that fails outright. A backup is read
    /// on the day something has already gone wrong; it is the last thing that
    /// should be brittle about a missing field.
    ///
    /// `doors` is the name `stockwerke` had while the floor was keyed by front
    /// door. Those rows carry no customer, so they cannot be matched to anyone
    /// under the current key and are deliberately not read back — but the tours
    /// in the same file are, which is what that file is really holding.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        app = try c.decodeIfPresent(String.self, forKey: .app)
        routes = try c.decodeIfPresent([RouteBackup].self, forKey: .routes) ?? []
        stockwerke = try c.decodeIfPresent([StockwerkBackup].self, forKey: .stockwerke) ?? []
        settings = try c.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
    }

    struct RouteBackup: Codable, Sendable {
        var id: UUID
        var name: String
        var status: String
        var createdAt: Date
        var completedAt: Date?
        var needsOptimize: Bool
        /// Dropped from the file on purpose — see `BackupArchive.make`.
        var geometryFlat: [Double]?
        var stops: [StopBackup]
    }

    struct StopBackup: Codable, Sendable {
        var id: UUID
        var kind: String
        var kunde: String?
        var strasse: String?
        var plz: String?
        var paket: String?
        var notiz: String?
        var lat: Double
        var lon: Double
        var orderIndex: Int
        var delivered: Bool
        var nextLegKm: Double?
        var nextLegMin: Double?
        var createdAt: Date
        var excluded: Bool
        var pinned: Bool
        var precision: String?
    }

    struct StockwerkBackup: Codable, Sendable {
        var key: String
        var kunde: String
        var strasse: String
        var plz: String
        var stockwerk: String?
        var dontAsk: Bool
        var updatedAt: Date

        init(
            key: String, kunde: String, strasse: String, plz: String,
            stockwerk: String?, dontAsk: Bool, updatedAt: Date
        ) {
            self.key = key
            self.kunde = kunde
            self.strasse = strasse
            self.plz = plz
            self.stockwerk = stockwerk
            self.dontAsk = dontAsk
            self.updatedAt = updatedAt
        }

        /// Same reason as the archive's own: a row missing a field is a row,
        /// not a corrupt file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
            kunde = try c.decodeIfPresent(String.self, forKey: .kunde) ?? ""
            strasse = try c.decodeIfPresent(String.self, forKey: .strasse) ?? ""
            plz = try c.decodeIfPresent(String.self, forKey: .plz) ?? ""
            stockwerk = try c.decodeIfPresent(String.self, forKey: .stockwerk)
            dontAsk = try c.decodeIfPresent(Bool.self, forKey: .dontAsk) ?? false
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        }
    }
}

// MARK: - Writing

extension BackupArchive {
    /// Everything in the store, in one pass.
    ///
    /// The driven geometry is left out. It is several thousand doubles per
    /// route — by far the largest thing in the store and the only part of it
    /// that is *derived*: one "Neu optimieren" rebuilds it from OSRM. Keeping
    /// it would multiply the size of a year's backup by a large number to
    /// preserve a line the app can redraw. Restored routes are flagged
    /// `needsOptimize` instead, which is the app's own way of saying "this line
    /// is not current" and comes with the button that fixes it.
    @MainActor
    static func make(from context: ModelContext, settings: [String: String] = [:]) throws -> BackupArchive {
        let routes = try context.fetch(
            FetchDescriptor<Route>(sortBy: [SortDescriptor(\.createdAt)]))
        let notes = try context.fetch(FetchDescriptor<StockwerkNote>())

        var archive = BackupArchive()
        archive.app = Self.appVersion
        archive.settings = settings
        archive.routes = routes.map { route in
            RouteBackup(
                id: route.id,
                name: route.name,
                status: route.statusRaw,
                createdAt: route.createdAt,
                completedAt: route.completedAt,
                needsOptimize: true,
                geometryFlat: nil,
                stops: route.stops.sorted(by: Stop.displayBefore).map(StopBackup.init))
        }
        archive.stockwerke = notes.map(StockwerkBackup.init)
        return archive
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "EAR Router \(v) (\(b))"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Writes the backup to a file and hands back its URL, ready to share.
    ///
    /// A real file with a real name, not raw bytes: what the share sheet passes
    /// on is a document called "EAR-Router-Sicherung-2026-09-06.json", which is
    /// what makes it recognisable in Dateien, in a mail attachment, or a year
    /// later in a folder of them.
    ///
    /// The directory is emptied first. Every tap writes a fresh file, and
    /// without this the temporary folder would keep one per tap for the life of
    /// the install — each of them a full copy of every customer's name and
    /// address.
    func writeForSharing(now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = URL.temporaryDirectory.appending(path: "Sicherung", directoryHint: .isDirectory)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appending(path: Self.filename(now: now))
        try encoded().write(to: url, options: .atomic)
        return url
    }

    /// "EAR-Router-Sicherung-2026-09-06.json".
    static func filename(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "EAR-Router-Sicherung-\(f.string(from: now)).json"
    }
}

extension BackupArchive.StopBackup {
    init(_ stop: Stop) {
        self.init(
            id: stop.id, kind: stop.kindRaw, kunde: stop.kunde, strasse: stop.strasse,
            plz: stop.plz, paket: stop.paket, notiz: stop.notiz,
            lat: stop.lat, lon: stop.lon, orderIndex: stop.orderIndex,
            delivered: stop.delivered, nextLegKm: stop.nextLegKm,
            nextLegMin: stop.nextLegMin, createdAt: stop.createdAt,
            excluded: stop.excluded, pinned: stop.pinned, precision: stop.precisionRaw)
    }
}

extension BackupArchive.StockwerkBackup {
    init(_ note: StockwerkNote) {
        self.init(
            key: note.key, kunde: note.kunde, strasse: note.strasse, plz: note.plz,
            stockwerk: note.stockwerk, dontAsk: note.dontAsk, updatedAt: note.updatedAt)
    }
}

// MARK: - Reading

extension BackupArchive {
    /// `nonisolated` for the same reason `RouteStore.parseImport` is: this is a
    /// pure decode of a file that may be megabytes, and nothing in it touches
    /// the store.
    nonisolated static func decode(_ data: Data) throws -> BackupArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(BackupArchive.self, from: data) else {
            throw AppError.message(
                "Diese Datei ist keine EAR-Router-Sicherung.")
        }
        guard archive.format == Self.formatName else {
            throw AppError.message(
                "Diese Datei ist keine EAR-Router-Sicherung.")
        }
        // Written by a *newer* build than this one. Refused rather than
        // half-read: a shape this reader does not know is a shape it cannot
        // decide it understood.
        guard archive.version <= Self.currentVersion else {
            throw AppError.message(
                "Diese Sicherung stammt aus einer neueren Version der App. "
                    + "Bitte zuerst die App aktualisieren.")
        }
        return archive
    }

    var routeCount: Int { routes.count }
    var stopCount: Int { routes.reduce(0) { $0 + $1.stops.count } }
    var stockwerkCount: Int { stockwerke.count }
}

/// What a restore did.
struct RestoreResult: Sendable {
    var routesAdded = 0
    var routesSkipped = 0
    var stockwerkeWritten = 0

    var summary: String {
        var parts: [String] = []
        parts.append(routesAdded == 1 ? "1 Tour" : "\(routesAdded) Touren")
        if routesSkipped > 0 {
            parts.append(
                routesSkipped == 1
                    ? "1 bereits vorhandene übersprungen"
                    : "\(routesSkipped) bereits vorhandene übersprungen")
        }
        parts.append(stockwerkeWritten == 1 ? "1 Stockwerk" : "\(stockwerkeWritten) Stockwerke")
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum BackupRestore {
    /// How an archive meets the data already on the phone.
    enum Mode: Sendable {
        /// Everything on the phone goes, and the file takes its place. What
        /// "restore onto a new phone" means.
        case replace
        /// The file is added to what is here: a route whose id is already on
        /// the phone is left alone, and a door is taken only when the file's
        /// answer is newer than the one stored. What "I have two phones" and
        /// "I only want my floors back" mean.
        case merge
    }

    @discardableResult
    static func apply(
        _ archive: BackupArchive, mode: Mode, in context: ModelContext
    ) throws -> RestoreResult {
        var result = RestoreResult()

        if mode == .replace {
            for route in try context.fetch(FetchDescriptor<Route>()) {
                // Stops go with the route — the relationship's delete rule is
                // cascade — so deleting the routes empties both tables.
                //
                // The packing checklist is the exception, and it is the same
                // exception `RouteStore.delete` documents: it lives in
                // `UserDefaults`, outside the store, so nothing cascades it
                // away. This path deleted routes directly and did not say so,
                // which meant a restore-and-replace left one set of ticks
                // behind per tour, in the app's preferences, for good. It also
                // has to happen here rather than after the insert below: a
                // replace re-inserts the file's tours under the *same* ids, and
                // forgetting afterwards would clear the checklist of a tour
                // that had just been restored.
                LadelisteState.forget(route.id)
                context.delete(route)
            }
            for note in try context.fetch(FetchDescriptor<StockwerkNote>()) {
                context.delete(note)
            }
        }

        let existingRouteIDs = Set(
            try context.fetch(FetchDescriptor<Route>()).map(\.id))

        for backup in archive.routes {
            guard !existingRouteIDs.contains(backup.id) else {
                result.routesSkipped += 1
                continue
            }
            insert(backup, in: context)
            result.routesAdded += 1
        }

        var existing: [String: StockwerkNote] = [:]
        for note in try context.fetch(FetchDescriptor<StockwerkNote>()) {
            existing[note.key] = note
        }

        for backup in archive.stockwerke {
            guard !backup.key.isEmpty else { continue }
            if let note = existing[backup.key] {
                // The newer answer wins. Two phones that were both asked about
                // the same stairwell disagree only about when — and the later
                // one is the one that saw the building most recently.
                guard backup.updatedAt > note.updatedAt else { continue }
                note.stockwerk = backup.stockwerk
                note.dontAsk = backup.dontAsk
                note.kunde = backup.kunde
                note.strasse = backup.strasse
                note.plz = backup.plz
                note.updatedAt = backup.updatedAt
            } else {
                let note = StockwerkNote(
                    key: backup.key, kunde: backup.kunde, strasse: backup.strasse,
                    plz: backup.plz, stockwerk: backup.stockwerk, dontAsk: backup.dontAsk)
                note.updatedAt = backup.updatedAt
                context.insert(note)
                existing[backup.key] = note
            }
            result.stockwerkeWritten += 1
        }

        try context.save()
        return result
    }

    private static func insert(_ backup: BackupArchive.RouteBackup, in context: ModelContext) {
        let route = Route(name: backup.name)
        route.id = backup.id
        route.statusRaw = backup.status
        route.createdAt = backup.createdAt
        route.completedAt = backup.completedAt
        // Always true on a restore: the geometry is not in the file, so the
        // line on the map is genuinely not current until the tour is optimized
        // again — and this is the flag that says so, with the button attached.
        route.needsOptimize = true
        route.geometryFlat = []
        context.insert(route)

        for s in backup.stops {
            let stop = Stop(
                kind: StopKind(rawValue: s.kind) ?? .customer,
                kunde: s.kunde, strasse: s.strasse, plz: s.plz,
                paket: s.paket, notiz: s.notiz,
                lat: s.lat, lon: s.lon, orderIndex: s.orderIndex,
                precision: s.precision.flatMap(Precision.init(rawValue:)),
                pinned: s.pinned, excluded: s.excluded)
            stop.id = s.id
            stop.delivered = s.delivered
            stop.nextLegKm = s.nextLegKm
            stop.nextLegMin = s.nextLegMin
            stop.createdAt = s.createdAt
            stop.route = route
            context.insert(stop)
        }
    }
}
