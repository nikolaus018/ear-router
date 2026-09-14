import SwiftUI
import SwiftData

/// Every customer the app has been told anything about: which floor they live
/// on, and whatever the driver wrote down after standing at their door.
///
/// "Globale Infos" to the driver — global because they outlive every tour that
/// visits the customer, unlike the Notiz on a stop, which goes with it.
///
/// This is the one thing in the app that is *only* in the app — nothing in the
/// office's list carries any of it, and after a few months there is a year of
/// stairwells in here that exists nowhere else. So it gets a screen: somewhere
/// to correct the one that was typed wrong, to take back a "nicht mehr fragen",
/// to hand the lot to a stand-in driver, and — mostly — to see that it is
/// there.
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
    /// The door knowledge on its way to another driver's phone — see `share`.
    @State private var sharedFile: SharedFile?

    private var visible: [StockwerkNote] {
        let query = AddressText.Search(search)
        guard !query.isEmpty else { return notes }
        // The key already holds the customer, the street and the postcode in
        // exactly this folded form, which is what makes searching "gruber",
        // "gentzgasse" or "1180" all work off one comparison.
        //
        // Word by word, like every other search in the app. Matched as one
        // substring — which is what this did — "gruber gentzgasse" found
        // nothing here while finding the same household on the tour's own
        // list, because the key writes the two either side of a separator:
        // "fam gruber|gentzgasse 129 1|1180".
        return notes.filter {
            query.matches(
                $0.key,
                or: AddressText.matchKey(
                    [$0.stockwerk, $0.notiz].compactMap { $0 }.joined(separator: " ")))
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
                    Label("Noch nichts gespeichert", systemImage: "stairs")
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
        .navigationTitle("Globale Infos")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Kunde, Adresse, Stockwerk oder Notiz")
        .toolbar {
            if !notes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Teilen", systemImage: "square.and.arrow.up") { share() }
                }
            }
        }
        .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
        .sheet(item: $editing) { StockwerkNoteSheet(note: $0) }
        .confirmationDialog(
            deleting.count == 1 ? "Globale Infos löschen?" : "\(deleting.count) Einträge löschen?",
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
            return "Die globalen Infos werden gelöscht. Diese Kunden werden bei der "
                + "nächsten Lieferung wieder gefragt."
        }
        return "Alles Gespeicherte zu „\(only.title)“ wird gelöscht. "
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
                    // The floor has the right-hand column to itself, the way
                    // Settings puts a value there. The standing note goes under
                    // the address, where two lines of somebody's handwriting
                    // have room to be two lines.
                    StopFacts.customerNote(note, lineLimit: 2)
                        .font(.caption)
                }
                Spacer(minLength: 8)
                if let stockwerk = note.stockwerk, !stockwerk.trimmed.isEmpty {
                    // A plain grey value on the right, the way Settings puts
                    // one there. It used to be a tinted chip — the app's last
                    // one — which made a list *of floors* spend a colour on the
                    // one thing every single row has.
                    //
                    // `Color.secondary` rather than the hierarchical
                    // `.secondary`, which is what it was: inside this row's
                    // `Button`, a hierarchical style resolves against the
                    // button's tint, so the floor had quietly gone back to
                    // being blue — the exact thing dropping the chip was meant
                    // to stop. Its two neighbours on this row were already
                    // spelling the colour out, which is why only this one was.
                    Text(Format.floor(stockwerk))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Stockwerk \(Format.floor(stockwerk))")
                } else if note.dontAsk && (note.notiz?.trimmed.isEmpty ?? true) {
                    // The other thing a row can mean: not a floor, but a
                    // standing instruction not to ask for one.
                    Label("Nicht fragen", systemImage: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    /// Hands everything learned about these customers to another phone.
    ///
    /// The case this exists for: somebody takes over the round for a week. All
    /// of it — every floor and every "klingelt nicht, klopfen" — is on one
    /// phone, and without this the stand-in starts from nothing and rings the
    /// wrong bell at thirty buildings.
    ///
    /// A `BackupArchive` with no tours in it, so it restores through the same
    /// merge the full backup already uses: newest answer per customer wins,
    /// and the receiving phone's own tours are not touched. Nothing new to
    /// write on the reading side, which is the point of reusing the format.
    private func share() {
        do {
            var archive = BackupArchive()
            archive.app = BackupArchive.appVersion
            archive.stockwerke = notes.map(BackupArchive.StockwerkBackup.init)
            sharedFile = SharedFile(url: try archive.writeForSharing())
        } catch {
            self.error = AppError.message("Die globalen Infos konnten nicht geteilt werden.")
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
                    ? "Der Eintrag konnte nicht gelöscht werden."
                    : "Die Einträge konnten nicht gelöscht werden.")
        }
    }
}
