import SwiftUI
import SwiftData

/// The day's list, as understood, before any of it touches the tour.
///
/// Every way stops arrive in bulk goes through here — a pasted JSON list and
/// the Zusteller-Portal import both end up on this screen — and nothing is written,
/// looked up or reordered until the driver says so. That ordering is the whole
/// point of the screen.
///
/// Before it, the sequence was: paste, wait out thirty throttled address
/// lookups, and *then* read a report saying three entries were rejected and two
/// resolved somewhere approximate. The corrections had to be made by editing
/// raw JSON — and the thirty
/// lookups paid for again. Everything that report could say about an entry is
/// knowable here, before a single request goes out: a missing name, an address
/// with no street, a postcode that is not a Vienna district. So it is said
/// here, on the row it belongs to, while it still costs one tap to fix.
///
/// It is also the answer to the plainer problem, which is that a list from
/// somebody else is not always right. A customer who cancelled this morning, a
/// name spelled two ways, a Hinweis that belongs on the stop below — this is
/// where a driver fixes those, on their own list.
struct ImportReviewView: View {
    let route: Route
    /// What the import was understood to say. Owned from here on:
    /// the driver's edits are theirs, and nothing writes back to the source.
    @State var entries: [Entry]
    /// The list arrived in the driver's own driving order — see
    /// `GourmetStopSelectionView` — and the tour is to keep it rather than be
    /// optimized. See `RouteStore.importJSON`.
    var keepOrder = false
    /// Fired once the entries have actually been written to `route` — after
    /// that, `route` is no longer the empty shell a caller may have created
    /// just to hand to this screen. Nil for every caller that had a real
    /// route already, which is why this stays an afterthought parameter
    /// rather than a required one.
    var onImported: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Entry?
    @State private var busy = false
    @State private var progress: String?
    @State private var importTask: Task<Void, Never>?
    @State private var pendingDeletions: PendingDeletions?
    @State private var result: ImportReport?
    @State private var error: AppError?
    /// Set by the first correction or removal. From then on the list on this
    /// screen is the driver's own work, and closing it asks first.
    @State private var edited = false
    /// Set once an import has actually written to the tour.
    ///
    /// The screen stays open after a run that had anything to report — an
    /// address that would not resolve, a stop that came back approximate, a
    /// run the driver stopped part-way — because the list is still worth
    /// something: fix the failures, press Übernehmen again, and it carries on.
    /// But by then part of it is already on the tour, and the discard question
    /// was still saying "Die Liste wird nicht übernommen", which had stopped
    /// being true the moment the first stop was written.
    @State private var applied = false
    @State private var confirmingDiscard = false

    /// One row. A `UUID` of its own rather than the entry's contents, because
    /// the contents are not unique: a real list carries five consecutive meals
    /// for "Caritas der Erzdiözese Wien gem." at one address, and identified by
    /// value those five are one row that cannot be edited or deleted apart.
    struct Entry: Identifiable, Hashable {
        let id = UUID()
        var kunde: String
        var strasse: String
        var plz: String
        var paket: String
        var notiz: String
        var telefon: String

        init(_ json: CustomerJSON) {
            kunde = json.kunde.trimmed
            strasse = json.strasse.trimmed
            plz = json.plz.trimmed
            paket = json.paket?.trimmed ?? ""
            notiz = json.notiz?.trimmed ?? ""
            telefon = json.telefon?.trimmed ?? ""
        }

        var json: CustomerJSON {
            CustomerJSON(
                kunde: kunde, strasse: strasse, plz: plz,
                paket: paket.nilIfEmpty, notiz: notiz.nilIfEmpty, telefon: telefon.nilIfEmpty)
        }

        /// What the import would refuse this entry for, said now rather than
        /// after thirty round trips. Exactly the checks `RouteStore` runs, so
        /// a row without a warning here cannot be rejected there.
        var problem: String? {
            if kunde.isEmpty { return "Kein Kunde" }
            if strasse.isEmpty { return "Keine Straße" }
            if plz.isEmpty { return "Keine PLZ" }
            if !Postcodes.isValid(plz) { return "\(plz) ist keine gültige PLZ" }
            do {
                try RouteStore.validateCustomerFields(
                    kunde: kunde, strasse: strasse, paket: paket.nilIfEmpty,
                    notiz: notiz.nilIfEmpty, telefon: telefon.nilIfEmpty)
            } catch let e as AppError {
                return e.message
            } catch {
                return "Ungültiger Eintrag"
            }
            return nil
        }
    }

    init(
        route: Route, entries: [CustomerJSON], keepOrder: Bool = false,
        onImported: (() -> Void)? = nil
    ) {
        self.route = route
        _entries = State(initialValue: entries.map(Entry.init))
        self.keepOrder = keepOrder
        self.onImported = onImported
    }

    private var problems: Int { entries.count { $0.problem != nil } }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("Nichts mehr übrig", systemImage: "tray")
                    } description: {
                        Text(
                            "Alle Einträge wurden entfernt. „Übernehmen“ würde damit jeden "
                                + "offenen Kundenstopp dieser Tour löschen.")
                    }
                } else {
                    list
                }
            }
            // One word. "Liste prüfen" truncated to "Liste prüf…" between the
            // two glass toolbar buttons, and the section header underneath
            // already says how many entries there are and how many need
            // looking at.
            .navigationTitle("Prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if let progress {
                    BusyBanner(text: progress)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: progress)
            .sheet(item: $editing) { entry in
                ImportEntryEditor(entry: entry) { updated in
                    if let index = entries.firstIndex(where: { $0.id == updated.id }),
                       entries[index] != updated {
                        entries[index] = updated
                        edited = true
                    }
                }
            }
            .confirmationDialog(
                pendingDeletions?.title ?? "",
                isPresented: Binding(
                    get: { pendingDeletions != nil },
                    set: { if !$0 { pendingDeletions = nil } }),
                titleVisibility: .visible,
                presenting: pendingDeletions
            ) { pending in
                Button("Übernehmen und entfernen", role: .destructive) {
                    pendingDeletions = nil
                    importTask = Task { await apply(pending.entries) }
                }
                Button("Abbrechen", role: .cancel) { pendingDeletions = nil }
            } message: { pending in
                Text(pending.message)
            }
            .sheet(item: $result) { report in
                ImportSummary(result: report.result)
                    .presentationDetents([.medium, .large])
            }
            .errorAlert($error)
            .interactiveDismissDisabled(busy || edited)
        }
    }

    // MARK: - The list

    private var list: some View {
        List {
            Section {
                ForEach($entries) { $entry in
                    row(entry)
                }
                .onDelete {
                    entries.remove(atOffsets: $0)
                    edited = true
                }
            } header: {
                Text(header)
            } footer: {
                Text(
                    problems > 0
                        ? "Einträge mit Warnung werden nicht übernommen. Tippen zum "
                            + "Korrigieren, oder nach links wischen zum Entfernen."
                        : "Tippen zum Bearbeiten, nach links wischen zum Entfernen. "
                            + "Erst „Übernehmen“ sucht die Adressen und ändert die Tour.")
            }
        }
        .listStyle(.insetGrouped)
        .disabled(busy)
    }

    private var header: String {
        let count = entries.count == 1 ? "1 Eintrag" : "\(entries.count) Einträge"
        guard problems > 0 else { return count }
        return "\(count) · \(problems == 1 ? "1 Warnung" : "\(problems) Warnungen")"
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            editing = entry
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.kunde.isEmpty ? "Ohne Namen" : entry.kunde)
                    .font(.body.weight(.medium))
                    .foregroundStyle(entry.kunde.isEmpty ? Color.secondary : Color.primary)

                Text(address(entry))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // The same lines the stop row draws, because this is the same
                // customer one step before they become a stop — a Paket should
                // look like a Paket before it is on a tour, too.
                if let paket = StopFacts.paket(entry.paket) {
                    paket
                        .font(.subheadline)
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.notiz.isEmpty {
                    StopFacts.note(entry.notiz, lineLimit: 2)
                        .font(.subheadline)
                        .padding(.top, 2)
                }

                if let problem = entry.problem {
                    Label {
                        Text(problem).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .labelStyle(TintedIconLabelStyle(tint: .attention))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 2)
            .symbolRenderingMode(.monochrome)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func address(_ entry: Entry) -> String {
        let parts = [entry.strasse, entry.plz].filter { !$0.isEmpty }
        return parts.isEmpty ? "Keine Adresse" : parts.joined(separator: ", ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            // Stays live and calls the import off, the same as every other long
            // job in this app. What has already resolved is kept.
            //
            // Asks before walking away from corrections. Fixing a postcode or
            // deleting a cancelled customer here is work on a list nothing
            // else has saved, and one tap on the button nearest the thumb
            // threw all of it away.
            Button(busy ? "Stoppen" : "Abbrechen") {
                if busy {
                    importTask?.cancel()
                } else if edited {
                    confirmingDiscard = true
                } else {
                    dismiss()
                }
            }
            .confirmationDialog(
                applied ? "Prüfen beenden?" : "Korrekturen verwerfen?",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(applied ? "Beenden" : "Verwerfen", role: .destructive) { dismiss() }
                Button("Weiter prüfen", role: .cancel) {}
            } message: {
                Text(
                    applied
                        ? "Was schon übernommen wurde, bleibt auf der Tour. Der Rest der "
                            + "Liste und deine Änderungen daran gehen verloren."
                        : "Die Liste wird nicht übernommen, und deine Änderungen daran "
                            + "gehen verloren.")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if busy {
                ProgressView()
            } else {
                Button("Übernehmen") { submit() }
            }
        }
    }

    // MARK: - Applying

    /// Everything the import will actually be given: the entries the driver
    /// left, minus the ones it would refuse anyway.
    ///
    /// Dropping the broken ones here rather than sending them is what lets the
    /// import delete. A round carrying any failure deletes nothing at all —
    /// deliberately, because a failed address and a genuinely removed customer
    /// are indistinguishable to it — so a single unfixable row would otherwise
    /// silently turn every "Übernehmen" into an update-only round for the rest
    /// of the day. The driver has already seen those rows flagged, and has
    /// already been given the chance to fix or remove them.
    private var submittable: [CustomerJSON] {
        entries.filter { $0.problem == nil }.map(\.json)
    }

    private func submit() {
        let payload = submittable
        let preview = RouteStore.deletionPreview(payload, in: route)
        if !preview.names.isEmpty {
            pendingDeletions = PendingDeletions(
                entries: payload, names: preview.names, skipped: entries.count - payload.count)
            return
        }
        importTask = Task { await apply(payload) }
    }

    private func apply(_ payload: [CustomerJSON]) async {
        busy = true
        defer { busy = false; progress = nil }

        do {
            let r = try await RouteStore.importJSON(
                payload, into: route, in: context, keepOrder: keepOrder
            ) { done, total in
                progress = "Adresse \(done + 1) von \(total) wird gesucht …"
            }
            // Even a partial, cancelled-partway import already wrote
            // something real to `route` — a caller waiting to find out
            // whether the shell it created is still empty needs to hear
            // about that case too, not just a clean finish.
            onImported?()
            applied = true
            if r.hasProblems {
                result = ImportReport(result: r)
            } else {
                dismiss()
            }
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Import fehlgeschlagen.")
        }
    }

    /// A confirmed-once deletion, with its sentences built ahead of the
    /// dismissal animation — the same reason `PendingRouteDeletion` exists.
    struct PendingDeletions: Identifiable {
        let id = UUID()
        let entries: [CustomerJSON]
        let title: String
        let message: String

        init(entries: [CustomerJSON], names: [String], skipped: Int) {
            self.entries = entries
            title = names.count == 1
                ? "1 Kunde wird entfernt"
                : "\(names.count) Kunden werden entfernt"

            let shown = names.prefix(5).joined(separator: ", ")
            let rest = names.count - min(names.count, 5)
            let list = rest > 0 ? "\(shown) und \(rest) weitere" : shown

            // Only open stops are ever named: one already answered for stays
            // on the tour whatever the list says, so there is no Lieferstatus
            // left to lose here.
            var text = entries.isEmpty
                ? "Die Liste ist leer — damit werden alle offenen Kundenstopps dieser "
                    + "Tour gelöscht: \(list). Paket und Notizen gehen mit."
                : "Diese Kunden stehen nicht mehr in der Liste und werden aus der Tour "
                    + "gelöscht: \(list). Paket und Notizen gehen mit."
            if skipped > 0 {
                // Said out loud, because a row skipped for a warning is a row
                // the driver may well have meant to keep — and its customer is
                // then one of the names above.
                text += skipped == 1
                    ? "\n\n1 Eintrag mit Warnung wird nicht übernommen."
                    : "\n\n\(skipped) Einträge mit Warnung werden nicht übernommen."
            }
            message = text
        }
    }
}

// MARK: - Editing one entry

/// One row of the list, open for correction.
///
/// The same five fields `StopEditorSheet` has and deliberately none of its
/// machinery: nothing here is geocoded, nothing is saved, and there is no stop
/// to delete. It is a text correction on a list that has not been applied yet.
struct ImportEntryEditor: View {
    @State private var entry: ImportReviewView.Entry
    /// The entry as it arrived, so "Abbrechen" can tell a look from an edit.
    private let original: ImportReviewView.Entry
    let onSave: (ImportReviewView.Entry) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?
    /// What the postcode field held when the driver tapped into it — the same
    /// clear-on-focus the stop editor does, for the same reason. See
    /// `StopEditorSheet.plzField`.
    @State private var plzBeforeEditing = ""
    @State private var confirmingDiscard = false

    private enum Field: Hashable { case kunde, telefon, strasse, plz, paket, notiz }

    init(entry: ImportReviewView.Entry, onSave: @escaping (ImportReviewView.Entry) -> Void) {
        _entry = State(initialValue: entry)
        original = entry
        self.onSave = onSave
    }

    /// The entry as it would be saved: a postcode emptied for typing and left
    /// untouched is the postcode it was, not a blank one.
    private var result: ImportReviewView.Entry {
        var out = entry
        if focused == .plz && out.plz.isEmpty { out.plz = plzBeforeEditing }
        return out
    }

    private var hasChanges: Bool { result != original }

    var body: some View {
        NavigationStack {
            Form {
                Section("Kunde") {
                    TextField("Name", text: $entry.kunde)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .kunde)
                        .onSubmit { focused = .telefon }
                        .limited(to: FieldLimits.kunde, text: $entry.kunde)
                    TextField("Telefon", text: $entry.telefon)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .submitLabel(.next)
                        .focused($focused, equals: .telefon)
                        .onSubmit { focused = .strasse }
                        .limited(to: FieldLimits.telefon, text: $entry.telefon)
                }

                Section {
                    TextField("Straße und Hausnummer", text: $entry.strasse)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .strasse)
                        .onSubmit { focused = .plz }
                        .limited(to: FieldLimits.strasse, text: $entry.strasse)
                    // A field rather than the picker over the 23 districts
                    // this used to be: the office's list runs past the
                    // Stadtgrenze, and a postcode it carries that the picker
                    // had no row for could only be corrected by choosing a
                    // Viennese district that was not where the customer lives.
                    LabeledContent("PLZ") {
                        HStack(spacing: 10) {
                            if let name = Districts.name(for: entry.plz) {
                                Text(name)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            TextField("1210", text: $entry.plz)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focused, equals: .plz)
                                .limited(to: 4, text: $entry.plz)
                                .frame(width: 58)
                                // Emptied on focus, put back if nothing was
                                // typed. Prefilled and capped at four digits,
                                // the field swallowed every keystroke of a
                                // corrected postcode until the driver thought
                                // to delete the old one first.
                                .onChange(of: focused) { was, now in
                                    if now == .plz {
                                        plzBeforeEditing = entry.plz
                                        entry.plz = ""
                                    } else if was == .plz, entry.plz.isEmpty {
                                        entry.plz = plzBeforeEditing
                                    }
                                }
                            Menu {
                                ForEach(Districts.all) { d in
                                    Button("\(d.plz) — \(d.label)") { entry.plz = d.plz }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                                    .frame(width: 30, height: 30)
                                    .contentShape(.rect)
                            }
                            .accessibilityLabel("Wiener Bezirk wählen")
                        }
                    }
                } header: {
                    Text("Adresse")
                } footer: {
                    // Judged on what would be saved, so tapping into the
                    // postcode does not flash "Keine PLZ" while the field is
                    // emptied for typing.
                    if let problem = result.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(TintedIconLabelStyle(tint: .attention))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Paket (z. B. 1x Vitalmenü EP TGM5)", text: $entry.paket)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .paket)
                        .onSubmit { focused = .notiz }
                        .limited(to: FieldLimits.paket, text: $entry.paket)
                    TextField("Notiz", text: $entry.notiz, axis: .vertical)
                        .lineLimit(2...6)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .notiz)
                        .limited(to: FieldLimits.notiz, text: $entry.notiz)
                } header: {
                    Text("Lieferung")
                } footer: {
                    Text("Autokorrektur ist hier aus — Türcodes und Stiegen bleiben, wie sie sind.")
                }
            }
            .navigationTitle("Eintrag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        if hasChanges { confirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog(
                        "Änderungen verwerfen?", isPresented: $confirmingDiscard,
                        titleVisibility: .visible
                    ) {
                        Button("Änderungen verwerfen", role: .destructive) { dismiss() }
                        Button("Weiter bearbeiten", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        onSave(result)
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges)
        }
    }
}
