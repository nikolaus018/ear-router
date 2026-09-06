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
        List {
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
                        delete(offsets.map { visible[$0] })
                    }
                } footer: {
                    Text(
                        notes.count == 1
                            ? "1 Kunde" : "\(notes.count) Kunden")
                }
            }
        }
        .navigationTitle("Stockwerke")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Kunde, Adresse oder Stockwerk")
        .sheet(item: $editing) { StockwerkNoteSheet(note: $0) }
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

    private func delete(_ notes: [StockwerkNote]) {
        for note in notes { context.delete(note) }
        try? context.save()
    }
}
