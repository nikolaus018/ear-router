import SwiftUI
import SwiftData

/// Every customer the app has been told a floor for.
///
/// The floors are the one thing in this app that is *only* in this app —
/// nothing in the office's list carries them, and after a few months there is a
/// year of stairwells in here that exists nowhere else. So they get a screen:
/// somewhere to correct the one that was typed wrong, to take back a "nicht
/// mehr fragen", and — mostly — to see that they are there.
struct StockwerkListView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \StockwerkNote.kunde) private var notes: [StockwerkNote]

    @State private var search = ""
    @State private var editing: StockwerkNote?
    /// Floors swiped away, waiting to be confirmed.
    ///
    /// Staged rather than deleted outright, and staged *by value* rather than
    /// by row offset. Two reasons, and they are the two this app already knows
    /// about from `PendingRouteDeletion`: `onDelete` hands over offsets into a
    /// live `@Query`, which the save after the first deletion refreshes
    /// underneath the loop — and a floor is the one thing in here that exists
    /// nowhere else. It is not on any list the office sends; it was learned
    /// once, standing in a stairwell, and there is no second copy to restore
    /// from. Deleting a route asks first. Deleting a stop asks first. This
    /// deleted a customer's floor on the one gesture a thumb makes by accident.
    @State private var deleting: [StockwerkNote] = []
    @State private var error: AppError?

    private var visible: [StockwerkNote] {
        let needle = AddressText.matchKey(search)
        guard !needle.isEmpty else { return notes }
        // The key already holds the customer, the street and the postcode in
        // exactly this folded form, which is what makes searching "gruber",
        // "gentzgasse" or "1180" all work off one comparison.
        return notes.filter {
            $0.key.contains(needle)
                || AddressText.matchKey($0.stockwerk ?? "").contains(needle)
        }
    }

    var body: some View {
        // Filtered once per draw. Read straight off the computed property — as
        // `offsets.map { visible[$0] }` did — a two-row swipe re-ran the whole
        // filter twice, and every read of it folds a `matchKey` over every
        // customer the driver has ever been asked about.
        let visible = visible

        return List {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Stockwerke", systemImage: "stairs")
                } description: {
                    Text(
                        "Nach dem Abhaken einer Lieferung fragt die App nach dem Stockwerk. "
                            + "Ab dann steht es bei jeder Tour gleich in der Liste.")
                }
                .listRowBackground(Color.clear)
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(visible) { note in
                        row(note)
                    }
                    .onDelete { offsets in
                        deleting = offsets.compactMap {
                            visible.indices.contains($0) ? visible[$0] : nil
                        }
                    }
                } footer: {
                    Text(footer(visible))
                }
            }
        }
        .navigationTitle("Stockwerke")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Kunde, Adresse oder Stockwerk")
        .sheet(item: $editing) { StockwerkNoteSheet(note: $0) }
        .confirmationDialog(
            deleting.count == 1 ? "Stockwerk löschen?" : "\(deleting.count) Stockwerke löschen?",
            isPresented: Binding(
                get: { !deleting.isEmpty },
                set: { if !$0 { deleting = [] } }),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) { confirmDelete() }
            Button("Abbrechen", role: .cancel) { deleting = [] }
        } message: {
            Text(deletionMessage)
        }
        .errorAlert($error)
    }

    /// Counts what is on screen while the list is filtered, and everything
    /// otherwise. It said "1.243 Kunden" under two search results, which is a
    /// footer describing a list the driver is not looking at.
    private func footer(_ visible: [StockwerkNote]) -> String {
        if !search.isEmpty {
            return visible.count == 1
                ? "1 von \(notes.count) Kunden"
                : "\(visible.count) von \(notes.count) Kunden"
        }
        return notes.count == 1 ? "1 Kunde" : "\(notes.count) Kunden"
    }

    private var deletionMessage: String {
        guard let only = deleting.first, deleting.count == 1 else {
            return "Die Stockwerke werden gelöscht. Diese Kunden werden bei der "
                + "nächsten Lieferung wieder gefragt."
        }
        return "Das gespeicherte Stockwerk für „\(only.title)“ wird gelöscht. "
            + "Beim nächsten Mal fragt die App wieder danach."
    }

    private func row(_ note: StockwerkNote) -> some View {
        Button {
            editing = note
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .foregroundStyle(Color.primary)
                    if !note.subtitle.isEmpty {
                        Text(note.subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let stockwerk = note.stockwerk, !stockwerk.trimmed.isEmpty {
                    StockwerkBadge(text: stockwerk, dimmed: false)
                } else if note.dontAsk {
                    // The other thing a row can mean: not a floor, but a
                    // standing instruction not to ask for one.
                    Label("Nicht fragen", systemImage: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    /// `try?` here meant a failed delete looked exactly like a delete the
    /// driver had cancelled: the row simply stayed. Every other write in this
    /// app says so when it fails; this one now does too.
    private func confirmDelete() {
        let doomed = deleting
        deleting = []
        guard !doomed.isEmpty else { return }
        do {
            for note in doomed { context.delete(note) }
            try context.save()
        } catch {
            context.rollback()
            self.error = AppError.message(
                doomed.count == 1
                    ? "Das Stockwerk konnte nicht gelöscht werden."
                    : "Die Stockwerke konnten nicht gelöscht werden.")
        }
    }
}
