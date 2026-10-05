import Foundation
import Observation

/// A public toilet, the city's or one of öKlo's — a row of `Restrooms.json`,
/// which `Tools/MakeRestrooms.py` builds from both lists.
struct Restroom: Codable, Sendable, Hashable {
    let name: String
    let lat: Double
    let lon: Double
    /// Metres from the nearest road a car may use to the toilet itself.
    let walk: Int
    /// Opening and closing time in minutes, per weekday, Monday first; `nil`
    /// on a closed day. No table at all is a toilet that never closes.
    var hours: [[Int]?]?
    /// Shut from November to March.
    var winterClosed: Bool?
    /// One of öKlo's compost toilets rather than the city's.
    var oeklo: Bool?

    var label: String { oeklo == true ? "öKlo" : "WC" }

    /// What a toilet is remembered by across updates of the file: its name
    /// and where it stands, and not the hours or the walk, which a refresh
    /// may correct without it becoming a different toilet.
    var key: String {
        String(format: "%@|%.5f|%.5f", locale: Locale(identifier: "en_US_POSIX"), name, lat, lon)
    }

    /// Whether the door is open at `date` — and still is twenty minutes on,
    /// because that is nearer to when the driver gets there.
    func isOpen(at date: Date) -> Bool {
        isOpenExactly(at: date) && isOpenExactly(at: date.addingTimeInterval(20 * 60))
    }

    private func isOpenExactly(at date: Date) -> Bool {
        let parts = Self.vienna.dateComponents([.month, .weekday, .hour, .minute], from: date)
        if winterClosed == true, let month = parts.month, month >= 11 || month <= 3 {
            return false
        }
        guard let hours else { return true }
        // `weekday` counts from Sunday = 1; the table from Monday = 0.
        let day = ((parts.weekday ?? 2) + 5) % 7
        guard hours.indices.contains(day), let span = hours[day], span.count == 2 else {
            return false
        }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= span[0] && minute < span[1]
    }

    private static let vienna: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna") ?? .current
        return c
    }()

    /// Every toilet there is: the list the app shipped with, or the newer one
    /// fetched from Mehr → Erweitert. See `RestroomCatalog`.
    static var all: [Restroom] { RestroomCatalog.shared.current.all }

    /// Every toilet with an id the map can select it by. The ids are made
    /// when the list is loaded and mean nothing outside this launch.
    static var pins: [RestroomPin] { RestroomCatalog.shared.current.pins }
    static var pinsByID: [UUID: RestroomPin] { RestroomCatalog.shared.current.pinsByID }

}

/// A toilet as the map draws and selects it.
struct RestroomPin: Identifiable, Equatable, Sendable {
    let id: UUID
    let restroom: Restroom
    /// `restroom.key`, built once: the map asks every pin whether it is
    /// marked on every frame of a pan, and the key is a formatted string.
    let key: String
}

/// What the driver has said about the toilets: which are no good, and a note
/// on any of them. By `Restroom.key`, on this phone, for good.
@MainActor
@Observable
final class RestroomMarks {
    static let shared = RestroomMarks()

    /// Toilets marked as no good — shut, filthy, out of order. Red on the map.
    private(set) var bad: Set<String> {
        didSet { UserDefaults.standard.set(bad.sorted(), forKey: Self.badKey) }
    }

    /// The driver's own words on a toilet: "Code 1234", "nur bis 15 Uhr".
    private(set) var notes: [String: String] {
        didSet { UserDefaults.standard.set(notes, forKey: Self.notesKey) }
    }

    private init() {
        bad = Set(UserDefaults.standard.stringArray(forKey: Self.badKey) ?? [])
        notes = UserDefaults.standard.dictionary(forKey: Self.notesKey) as? [String: String] ?? [:]
    }

    func isBad(_ restroom: Restroom) -> Bool { bad.contains(restroom.key) }

    func setBad(_ isBad: Bool, _ restroom: Restroom) {
        if isBad { bad.insert(restroom.key) } else { bad.remove(restroom.key) }
    }

    func note(for restroom: Restroom) -> String? { notes[restroom.key] }

    /// An empty note is no note.
    func setNote(_ text: String, for restroom: Restroom) {
        let text = String(text.trimmed.prefix(Self.maxNoteLength))
        notes[restroom.key] = text.isEmpty ? nil : text
    }

    /// Every toilet with a mark or a note, for the backup file.
    func backup() -> [BackupArchive.RestroomBackup] {
        bad.union(notes.keys).sorted().map {
            BackupArchive.RestroomBackup(key: $0, bad: bad.contains($0), note: notes[$0])
        }
    }

    /// Takes the marks and notes out of a backup. Replacing, the file is the
    /// phone. Merging, a toilet marked on either stays marked, and a note
    /// already here is kept over the file's — it is the one being read now.
    func restore(_ rows: [BackupArchive.RestroomBackup], replacing: Bool) {
        var bad = replacing ? [] : self.bad
        var notes = replacing ? [:] : self.notes
        for row in rows where !row.key.isEmpty {
            if row.bad { bad.insert(row.key) }
            if let note = row.note?.trimmed.nilIfEmpty, notes[row.key] == nil {
                notes[row.key] = String(note.prefix(Self.maxNoteLength))
            }
        }
        self.bad = bad
        self.notes = notes
    }

    static let maxNoteLength = 300
    /// The key the marks were first kept under, so those made then are kept.
    private static let badKey = "restroom.banned"
    private static let notesKey = "restroom.notes"
}
