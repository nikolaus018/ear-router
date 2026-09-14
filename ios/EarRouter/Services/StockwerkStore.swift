import Foundation
import SwiftData

/// Everything this app knows about one customer's door, as one value.
///
/// A struct rather than five arguments because these are written together or
/// not at all: the sheet that asks about the floor is the same sheet that holds
/// the Türcode and the "lange läuten" switch, and a save that carried only the
/// field that happened to change was how a Türcode learned in March got wiped
/// by a floor corrected in May.
struct DoorKnowledge: Equatable, Sendable {
    var stockwerk: String?
    var tuerNotiz: String?
    var tuercode: String?
    var langeLaeuten = false
    var dontAsk = false

    init(
        stockwerk: String? = nil, tuerNotiz: String? = nil, tuercode: String? = nil,
        langeLaeuten: Bool = false, dontAsk: Bool = false
    ) {
        self.stockwerk = stockwerk.cleaned
        self.tuerNotiz = tuerNotiz.cleaned
        self.tuercode = tuercode.cleaned
        self.langeLaeuten = langeLaeuten
        self.dontAsk = dontAsk
    }

    init(_ note: StockwerkNote) {
        self.init(
            stockwerk: note.stockwerk, tuerNotiz: note.tuerNotiz, tuercode: note.tuercode,
            langeLaeuten: note.langeLaeuten, dontAsk: note.dontAsk)
    }

    /// Nothing known and no standing instruction — which is a row's absence,
    /// not its contents. See `StockwerkStore.save`.
    var isBlank: Bool {
        stockwerk == nil && tuerNotiz == nil && tuercode == nil && !langeLaeuten && !dontAsk
    }
}

extension Optional where Wrapped == String {
    /// Trimmed, with empty reading as nothing at all. The one rule every field
    /// of `DoorKnowledge` is stored under, so " " and "" and `nil` cannot be
    /// three different states of the same answer.
    fileprivate var cleaned: String? {
        guard let value = self?.trimmed, !value.isEmpty else { return nil }
        return value
    }
}

/// Every read and write of what is known about a customer's door.
///
/// The rule this exists to keep: one row per customer. `StockwerkNote.key`
/// carries no unique constraint, so the read-before-write lives here and every
/// path — the prompt after a delivery, an edit from the stop list, a merged
/// backup — goes through it.
@MainActor
enum StockwerkStore {

    // MARK: - Reading

    static func note(forKey key: String, in context: ModelContext) throws -> StockwerkNote? {
        var descriptor = FetchDescriptor<StockwerkNote>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func note(for stop: Stop, in context: ModelContext) throws -> StockwerkNote? {
        guard let key = StockwerkKey.make(for: stop) else { return nil }
        return try note(forKey: key, in: context)
    }

    /// Whether to put the question to the driver at all.
    ///
    /// Three ways to answer no, and each is a different kind of no: this is not
    /// a delivery (a depot has no floor), the floor is already known, or the
    /// driver has said not to ask about this customer again.
    static func shouldAsk(_ stop: Stop, in context: ModelContext) -> Bool {
        guard stop.kind == .customer, StockwerkKey.make(for: stop) != nil else { return false }
        // A failed fetch reads as "nothing known", which asks — the same
        // outcome as an empty table, and the only one that cannot lose an
        // answer the driver has already given.
        guard let existing = (try? note(for: stop, in: context)) ?? nil else { return true }
        if existing.dontAsk { return false }
        return (existing.stockwerk?.trimmed.isEmpty ?? true)
    }

    // MARK: - Writing

    /// Writes everything known about a door, as one answer.
    ///
    /// An answer that says nothing at all — no floor, no note, no code, no
    /// standing instruction — deletes the row instead of storing a blank one. A
    /// customer nothing is known about is one this app has never been told
    /// about, and that is a row's absence, not its contents.
    static func save(
        _ knowledge: DoorKnowledge, for stop: Stop, in context: ModelContext
    ) throws {
        guard let key = StockwerkKey.make(for: stop) else { return }
        let existing = try note(forKey: key, in: context)

        if knowledge.isBlank {
            if let existing { context.delete(existing) }
            try context.save()
            return
        }

        if let existing {
            existing.stockwerk = knowledge.stockwerk
            existing.tuerNotiz = knowledge.tuerNotiz
            existing.tuercode = knowledge.tuercode
            existing.langeLaeuten = knowledge.langeLaeuten
            existing.dontAsk = knowledge.dontAsk
            existing.updatedAt = Date()
            // The name and address as this stop spells them, so the entries
            // list shows a customer the way the most recent list wrote them
            // rather than however they happened to be written the first time.
            existing.kunde = stop.kunde?.trimmed ?? existing.kunde
            existing.strasse = stop.strasse?.trimmed ?? existing.strasse
            existing.plz = stop.plz?.trimmed ?? existing.plz
        } else {
            context.insert(
                StockwerkNote(
                    key: key,
                    kunde: stop.kunde?.trimmed ?? "",
                    strasse: stop.strasse?.trimmed ?? "",
                    plz: stop.plz?.trimmed ?? "",
                    stockwerk: knowledge.stockwerk,
                    tuerNotiz: knowledge.tuerNotiz,
                    tuercode: knowledge.tuercode,
                    langeLaeuten: knowledge.langeLaeuten,
                    dontAsk: knowledge.dontAsk))
        }
        try context.save()
    }

    /// The floor alone, leaving everything else known about the door exactly as
    /// it was.
    ///
    /// The distinction matters: a caller that has only been told a floor must
    /// not be able to throw away a Türcode it never saw. Everything that edits
    /// the whole door goes through `save(_:for:in:)` with a full value.
    static func save(
        stockwerk: String?, dontAsk: Bool, for stop: Stop, in context: ModelContext
    ) throws {
        var knowledge = (try note(for: stop, in: context)).map(DoorKnowledge.init)
            ?? DoorKnowledge()
        knowledge.stockwerk = stockwerk?.trimmed.nilIfEmpty
        knowledge.dontAsk = dontAsk
        try save(knowledge, for: stop, in: context)
    }

    static func delete(_ note: StockwerkNote, in context: ModelContext) throws {
        context.delete(note)
        try context.save()
    }

    /// Everything known, newest first — what the entries list shows.
    static func all(in context: ModelContext) throws -> [StockwerkNote] {
        try context.fetch(
            FetchDescriptor<StockwerkNote>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }
}

extension Collection where Element == StockwerkNote {
    /// Everything known about each of `stops`, by stop id.
    ///
    /// The same one-pass indexing as `floors(for:)` below and for the same
    /// reasons — it is simply the whole row rather than one field of it, which
    /// is what a screen showing the Türcode beside the floor needs.
    func knowledge(for stops: [Stop]) -> [UUID: StockwerkNote] {
        var wanted: [String: [UUID]] = [:]
        for stop in stops where stop.kind == .customer {
            guard let key = StockwerkKey.make(for: stop) else { continue }
            wanted[key, default: []].append(stop.id)
        }
        guard !wanted.isEmpty else { return [:] }

        var out: [UUID: StockwerkNote] = [:]
        for note in self {
            guard let ids = wanted[note.key] else { continue }
            for id in ids { out[id] = note }
        }
        return out
    }

    /// The floor for each of `stops`, by stop id.
    ///
    /// Built from a list of notes that is already in memory — the stop list has
    /// them from a `@Query` — rather than by fetching per row. A tour is a
    /// hundred stops and a career is a few thousand customers; this is one pass
    /// over each, once per draw of the list, instead of a hundred fetches.
    ///
    /// Indexed from the *stops* rather than from the notes. Both directions are
    /// one pass over each, but a table built from the notes is a table of every
    /// customer the driver has ever been asked about — thousands of entries
    /// allocated to answer for the hundred on today's tour, on every redraw of
    /// the list, including every keystroke typed into its search field. This
    /// way the only table built is the answer itself.
    ///
    /// A key maps to a list of stops, because one customer can be on a tour
    /// twice — two meals ordered under one name — and both rows want the floor.
    func floors(for stops: [Stop]) -> [UUID: String] {
        var wanted: [String: [UUID]] = [:]
        for stop in stops where stop.kind == .customer {
            guard let key = StockwerkKey.make(for: stop) else { continue }
            wanted[key, default: []].append(stop.id)
        }
        guard !wanted.isEmpty else { return [:] }

        var out: [UUID: String] = [:]
        for note in self {
            guard let ids = wanted[note.key],
                  let value = note.stockwerk?.trimmed, !value.isEmpty
            else { continue }
            for id in ids { out[id] = value }
        }
        return out
    }
}
