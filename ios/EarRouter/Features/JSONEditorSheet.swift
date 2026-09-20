import SwiftUI
import SwiftData

/// The bulk editor: paste a whole day's customer list at once. The same JSON
/// shape the web app used, so an existing list pastes straight in.
struct JSONEditorSheet: View {
    let route: Route
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    /// A full-screen `TextEditor` has no way out of the keyboard of its own —
    /// no Return to commit, nothing else to tap. Without an explicit Fertig the
    /// driver was stuck looking at half a JSON list.
    @FocusState private var editing: Bool
    @State private var result: ImportReport?
    @State private var error: AppError?
    @State private var loaded = false
    /// The parsed list, waiting to be checked over.
    ///
    /// Everything that used to happen when "Übernehmen" was tapped — the
    /// deletion warning, the thirty throttled lookups, the report at the end —
    /// now happens one screen further on, after the driver has actually seen
    /// what the paste was understood to say.
    @State private var review: ReviewPayload?
    /// Set once the review has written stops to the tour. From then on the
    /// paste has done its job, and closing the review closes this too — the
    /// same way the portal import closes itself. Left open, a finished import
    /// dropped the driver back into a screen of raw JSON with nothing left to
    /// do on it but find "Schließen".
    @State private var imported = false
    /// The text as it was loaded, so closing can tell a look from an edit —
    /// the same question every other editing sheet in this app asks before it
    /// throws work away.
    @State private var loadedText = ""
    @State private var confirmingDiscard = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                // Inside the editor's own bounds, so it sits exactly where the
                // first typed character will.
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { placeholder }
                }
                .padding(.horizontal, 12)
                .focused($editing)
            // Named for the format, because the format is the only thing that
            // distinguishes this screen from importing a table — and the driver
            // chooses between the two while holding one or the other. It also
            // has to be short: the two glass toolbar buttons either side of it
            // truncate anything longer.
            .navigationTitle("JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") {
                        if text == loadedText { dismiss() } else { confirmingDiscard = true }
                    }
                    .confirmationDialog(
                        "Änderungen verwerfen?", isPresented: $confirmingDiscard,
                        titleVisibility: .visible
                    ) {
                        Button("Änderungen verwerfen", role: .destructive) { dismiss() }
                        Button("Weiter bearbeiten", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    // "Weiter", not "Übernehmen": this button no longer changes
                    // the tour, it opens the list for checking.
                    Button("Weiter") { submit() }
                        .disabled(text.trimmed.isEmpty)
                }
                ToolbarItem(placement: .keyboard) {
                    Spacer()
                }
                ToolbarItem(placement: .keyboard) {
                    Button("Fertig") { editing = false }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    // Text, not glyphs. Rendered icon-only in the bottom bar,
                    // "copy" and "paste" are two near-identical sheets of paper
                    // and the driver has to guess which is which.
                    // Greyed out, like Leeren, while there is nothing to act
                    // on: live over an empty editor they both did nothing.
                    Button("Kopieren") { UIPasteboard.general.string = text }
                        .disabled(text.isEmpty)
                    // The same button the Eray paste screen carries, and for
                    // the same reasons — see `PasteTextButton`. It was the
                    // system `PasteButton`, which drew a solid blue pill inside
                    // the bar's own glass capsule and stayed just as blue, just
                    // as tappable and entirely inert on an empty clipboard.
                    PasteTextButton { text = $0 }
                    Spacer()
                    // Empties the editor, which is what the word means — it
                    // used to leave "[]" behind, and "[]" is not an empty
                    // editor but a *valid list of no customers*. Two taps,
                    // Leeren then Übernehmen, and every stop on the tour was
                    // gone, silently, with the sheet closing on a job well
                    // done. Empty text disables Übernehmen and brings the
                    // placeholder back; a driver who really means to clear the
                    // round can still type the two brackets, and is asked.
                    Button("Leeren", role: .destructive) { text = "" }
                        .disabled(text.isEmpty)
                }
            }
            .errorAlert($error)
            // A swipe is the easiest gesture to make by accident, and what it
            // would throw away here is a pasted day's list.
            .interactiveDismissDisabled(text != loadedText)
            // Loaded once, not on every appearance. `onAppear` fires again when
            // a sheet presented over this one goes away — and the sheet
            // presented over this one is the import report, so a partly-failed
            // import would have thrown away the corrected paste the driver was
            // standing there to fix.
            .task {
                guard !loaded else { return }
                loaded = true
                // A tour with no stops yet opens *empty* rather than on "[]".
                // Two brackets are not an example of anything — they are what
                // the driver is trying to work out how to fill — and an empty
                // editor is what lets the placeholder below say it instead.
                // "Übernehmen" is disabled on empty text, so nothing is lost:
                // applying "[]" to a route that has no stops did nothing
                // anyway.
                let loaded = route.customerCount == 0 ? "" : RouteStore.exportJSON(route)
                text = loaded
                loadedText = loaded
            }
        }
        // The parsed list, before any of it is applied. Full screen, because
        // checking thirty stops is the job it is there for.
        .sheet(item: $review, onDismiss: { if imported { dismiss() } }) { payload in
            ImportReviewView(route: route, entries: payload.entries) { imported = true }
        }
    }

    /// `[CustomerJSON]` is a plain value; this is the identity a
    /// `.sheet(item:)` needs to present one.
    struct ReviewPayload: Identifiable {
        let id = UUID()
        let entries: [CustomerJSON]
    }

    /// What the editor shows before anything is in it: the shape a day's list
    /// has to have.
    ///
    /// A placeholder rather than prefilled text, for the same reason the "Neue
    /// Tour" field takes the date as one — prefilled, it would have to be
    /// deleted before anything could be pasted over it, and an example left in
    /// by accident is two invented customers imported onto a real tour.
    ///
    /// Two entries, not one: the comma between them is the thing people get
    /// wrong when they write this out by hand, and the second entry carries
    /// only the three required fields, which says more plainly than a sentence
    /// could that Paket and Notiz may simply be left out.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Die Tagesliste hier einsetzen — „Kunde“, „Straße“ und „PLZ“ muss jeder "
                    + "Eintrag haben, „Paket“ und „Notiz“ sind freiwillig.")
                .font(.footnote)
            Text(Self.exampleJSON)
                .font(.system(.footnote, design: .monospaced))
        }
        .foregroundStyle(.tertiary)
        // The insets `TextEditor` puts around its own text, so the placeholder
        // sits on the same line the cursor does rather than a few points off it.
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        // Taps belong to the editor underneath — tapping the example is how
        // most people will try to start typing.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private static let exampleJSON = """
        [
          {
            "kunde": "Fam. Gruber",
            "strasse": "Gentzgasse 129/1",
            "plz": "1180",
            "paket": "2x Menü",
            "notiz": "Stiege 1, bitte laut klingeln"
          },
          {
            "kunde": "Hr. Novak",
            "strasse": "Alser Straße 21",
            "plz": "1080"
          }
        ]
        """

    /// Parses the paste and hands it on to be checked.
    ///
    /// Nothing here reaches the store, the geocoder or the tour — the driver
    /// has typed or pasted text and the only honest next step is showing them
    /// what it was understood to mean.
    ///
    /// This screen takes a JSON list and nothing else.
    private func submit() {
        do {
            review = ReviewPayload(entries: try RouteStore.parseImport(text))
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Import fehlgeschlagen.")
        }
    }
}

/// `ImportResult` is a plain value the store hands back; this is the identity a
/// `.sheet(item:)` needs to present one.
struct ImportReport: Identifiable {
    let id = UUID()
    let result: ImportResult
}

struct ImportSummary: View {
    let result: ImportResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            summary
                .navigationTitle("Import")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
    }

    private var summary: some View {
        List {
            Section("Übernommen") {
                LabeledContent("Neu", value: "\(result.inserted)")
                LabeledContent("Aktualisiert", value: "\(result.updated)")
                if result.moved > 0 {
                    LabeledContent("Umgezogen", value: "\(result.moved)")
                }
                if result.deleted > 0 {
                    LabeledContent("Entfernt", value: "\(result.deleted)")
                }
                if result.cancelled {
                    Label(
                        "Gestoppt — die restlichen Adressen wurden nicht gesucht. Noch "
                            + "einmal übernehmen macht dort weiter.",
                        systemImage: "hand.raised.fill")
                        .font(.footnote)
                        .labelStyle(TintedIconLabelStyle(tint: .attention))
                        .foregroundStyle(.secondary)
                } else if result.deletionsSkipped {
                    Label(
                        "Nichts entfernt — erst die Fehler unten beheben und noch einmal "
                            + "übernehmen.",
                        systemImage: "exclamationmark.shield.fill")
                        .font(.footnote)
                        .labelStyle(TintedIconLabelStyle(tint: .attention))
                        .foregroundStyle(.secondary)
                }
            }

            if !result.validationFailures.isEmpty {
                Section("Nicht übernommen") {
                    // Keyed by position, not by name. Two customers called
                    // "Fam. Gruber" — or two entries that failed with no name at
                    // all — are exactly the case this list exists to report, and
                    // identifying rows by their label made SwiftUI treat them as
                    // one row and show only the first.
                    ForEach(Array(result.validationFailures.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.label).font(.subheadline.weight(.medium))
                            Text(f.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !result.geocodeFailures.isEmpty {
                Section("Adresse nicht gefunden") {
                    ForEach(Array(result.geocodeFailures.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.kunde).font(.subheadline.weight(.medium))
                            Text("\(f.strasse), \(f.plz)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !result.approximate.isEmpty {
                Section("Bitte prüfen") {
                    ForEach(Array(result.approximate.enumerated()), id: \.offset) { _, a in
                        // Triangle in the full-strength amber, the name in the
                        // darker one. Amber text on a white list row measures
                        // about 2.1:1, and this is the section telling the
                        // driver which addresses to go and look at.
                        Label {
                            Text("\(a.kunde) — \(a.precision.shortLabel)")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.attention)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
