import SwiftUI
import SwiftData

/// The bulk editor: paste a whole day's customer list at once. The same JSON
/// shape the web app used, so an existing list pastes straight in.
struct JSONEditorSheet: View {
    let route: Route
    /// What the editor opens on, when something other than the route's own
    /// stops put it there — a scanned list handed over from the photo import
    /// for correction. `nil` is the normal case: the route's current stops.
    var initialText: String?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    /// A full-screen `TextEditor` has no way out of the keyboard of its own —
    /// no Return to commit, nothing else to tap. Without an explicit Fertig the
    /// driver was stuck looking at half a JSON list.
    @FocusState private var editing: Bool
    @State private var result: ImportReport?
    @State private var error: AppError?
    @State private var loaded = false
    /// What the import is doing right now, once it reaches the addresses it has
    /// to look up. `nil` while there is nothing to report.
    @State private var progress: String?

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
                .disabled(busy)
                .focused($editing)
                // The same pill the stop list uses to report work in flight,
                // for the same reason: this one runs for half a minute.
                .safeAreaInset(edge: .bottom) {
                    if let progress {
                        BusyBanner(text: progress)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: progress)
            // Short enough to survive the two glass toolbar buttons either side
            // of it: "Stopps als JSON" truncated to "Stopps als…", which is a
            // title that says nothing.
            .navigationTitle("JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .primaryAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Übernehmen") { Task { await save() } }
                            .disabled(text.trimmed.isEmpty)
                    }
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
                    Button("Kopieren") { UIPasteboard.general.string = text }
                    // The system paste control rather than reading the
                    // pasteboard ourselves: touching `UIPasteboard.general`
                    // raises iOS's "would like to paste from…" alert every
                    // single time, which is a modal interruption in the middle
                    // of the one action this whole screen exists for.
                    PasteButton(payloadType: String.self) { items in
                        if let first = items.first { text = first }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    Spacer()
                    Button("Leeren", role: .destructive) { text = "[]" }
                }
            }
            .errorAlert($error)
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
                if let initialText {
                    text = initialText
                } else {
                    text = route.customerCount == 0 ? "" : RouteStore.exportJSON(route)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        // A full screen rather than a 260pt panel wedged under the editor and
        // behind the bottom bar. What a partly-failed import has to say —
        // which addresses were rejected, which resolved only approximately —
        // is the whole reason the driver is still on this screen, and it was
        // the part with the least room to say it.
        .sheet(item: $result) { report in
            ImportSummary(result: report.result)
                // Half height: this is a short report, and leaving the editor
                // visible behind it keeps the entries it is complaining about
                // in view.
                .presentationDetents([.medium, .large])
        }
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
                "Die Tagesliste hier einsetzen — „Kunde“, „Straße“ und „Bezirk“ muss jeder "
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

    private func save() async {
        busy = true
        defer { busy = false; progress = nil }

        do {
            let entries = try RouteStore.parseImport(text)
            // A fresh day's list is thirty addresses at a throttled round trip
            // each — half a minute behind a spinner that says nothing about how
            // much of it is left, or whether it is moving at all.
            let r = try await RouteStore.importJSON(
                entries, into: route, in: context
            ) { done, total in
                progress = "Adresse \(done + 1) von \(total) wird gesucht …"
            }
            // A clean import has nothing left to say — closing is the answer
            // the driver wants. One with problems reports itself, and the
            // editor stays open behind it so the offending entries can be
            // corrected and submitted again.
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
                if result.deletionsSkipped {
                    Label(
                        "Nichts entfernt — erst die Fehler unten beheben und noch einmal "
                            + "übernehmen.",
                        systemImage: "exclamationmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.warningText)
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
                        Label(
                            "\(a.kunde) — \(a.precision.shortLabel)",
                            systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.warning)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
