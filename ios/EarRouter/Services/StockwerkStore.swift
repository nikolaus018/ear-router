import Foundation
import SwiftData

/// What this app knows about one customer, as one value: which floor they live
/// on, and whatever else the driver wrote down.
///
/// **"Globale Infos" on screen** — global because it outlives every tour that
/// visits the customer, which is the whole distinction a driver is making when
/// they choose this over the Notiz on the stop. The type is named for what it
/// holds rather than for how long it lives, so both names are searchable from
/// the other.
///
/// A struct rather than three arguments because these are written together or
/// not at all: the sheet that asks about the floor is the same sheet that holds
/// the note, and a save that carried only the field that happened to change was
/// how a note written in March got wiped by a floor corrected in May.
struct CustomerInfo: Equatable, Sendable {
    var stockwerk: String?
    var notiz: String?
    var dontAsk = false

    init(stockwerk: String? = nil, notiz: String? = nil, dontAsk: Bool = false) {
        self.stockwerk = stockwerk.cleaned
        self.notiz = notiz.cleaned
        self.dontAsk = dontAsk
    }

    init(_ note: StockwerkNote) {
        self.init(stockwerk: note.stockwerk, notiz: note.notiz, dontAsk: note.dontAsk)
    }

    /// Nothing known and no standing instruction — which is a row's absence,
    /// not its contents. See `StockwerkStore.save`.
    var isBlank: Bool { stockwerk == nil && notiz == nil && !dontAsk }
}

extension Optional where Wrapped == String {
    /// Trimmed, with empty reading as nothing at all. The one rule every field
    /// of `CustomerInfo` is stored under, so " " and "" and `nil` cannot be
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

    /// Writes everything known about a customer, as one answer.
    ///
    /// An answer that says nothing at all — no floor, no note, no standing
    /// instruction — deletes the row instead of storing a blank one. A customer
    /// nothing is known about is one this app has never been told about, and
    /// that is a row's absence, not its contents.
    static func save(
        _ info: CustomerInfo, for stop: Stop, in context: ModelContext
    ) throws {
        guard let key = StockwerkKey.make(for: stop) else { return }
        let existing = try note(forKey: key, in: context)

        if info.isBlank {
            if let existing { context.delete(existing) }
            try context.save()
            return
        }

        if let existing {
            existing.stockwerk = info.stockwerk
            existing.notiz = info.notiz
            existing.dontAsk = info.dontAsk
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
                    stockwerk: info.stockwerk,
                    notiz: info.notiz,
                    dontAsk: info.dontAsk))
        }
        try context.save()
    }

    /// The floor alone, leaving everything else known about the customer
    /// exactly as it was.
    ///
    /// The distinction matters: a caller that has only been told a floor must
    /// not be able to throw away a note it never saw. Everything that edits the
    /// whole customer goes through `save(_:for:in:)` with a full value.
    static func save(
        stockwerk: String?, dontAsk: Bool, for stop: Stop, in context: ModelContext
    ) throws {
        var info = (try note(for: stop, in: context)).map(CustomerInfo.init)
            ?? CustomerInfo()
        info.stockwerk = stockwerk?.trimmed.nilIfEmpty
        info.dontAsk = dontAsk
        try save(info, for: stop, in: context)
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
    /// is what a screen showing the note beside the floor needs.
    func info(for stops: [Stop]) -> [UUID: StockwerkNote] {
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

    /// The stops whose floor the app will not ask about any more: the floor is
    /// known, or the driver said "Nicht mehr fragen" — the two answers
    /// `StockwerkStore.shouldAsk` says no to.
    ///
    /// What "Tour vorbereiten" counts against. Built off `floors(for:)`, which
    /// only knows floors, it listed every house and Kleingarten the driver had
    /// told the app to stop asking about as "Stockwerk unbekannt — die App
    /// fragt an der Tür danach", which it then never did.
    func floorQuestionClosed(for stops: [Stop]) -> Set<UUID> {
        Set(info(for: stops).compactMap { id, note in
            note.dontAsk || !(note.stockwerk?.trimmed.isEmpty ?? true) ? id : nil
        })
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
