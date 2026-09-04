import SwiftUI
import SwiftData

/// The bulk editor: paste a whole day's customer list at once. The same JSON
/// shape the web app used, so an existing list pastes straight in.
struct JSONEditorSheet: View {
    let route: Route
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    @State private var result: ImportResult?
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .disabled(busy)

                if let result {
                    ImportSummary(result: result)
                        .frame(maxHeight: 260)
                }
            }
            .navigationTitle("Stopps als JSON")
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
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Kopieren", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                    }
                    Button("Einsetzen", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string { text = s }
                    }
                    Spacer()
                    Button("Leeren", systemImage: "trash", role: .destructive) {
                        text = "[]"
                    }
                }
            }
            .errorAlert($error)
            .onAppear { text = RouteStore.exportJSON(route) }
        }
        .interactiveDismissDisabled(busy)
    }

    private func save() async {
        busy = true
        defer { busy = false }

        do {
            let entries = try RouteStore.parseImport(text)
            let r = try await RouteStore.importJSON(entries, into: route, in: context)
            result = r
            // A clean import has nothing left to say — closing is the answer
            // the driver wants. One with problems stays open so they can see
            // which addresses need attention.
            if !r.hasProblems { dismiss() }
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Import fehlgeschlagen.")
        }
    }
}

struct ImportSummary: View {
    let result: ImportResult

    var body: some View {
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
                    ForEach(result.validationFailures, id: \.label) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.label).font(.subheadline.weight(.medium))
                            Text(f.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !result.geocodeFailures.isEmpty {
                Section("Adresse nicht gefunden") {
                    ForEach(result.geocodeFailures, id: \.kunde) { f in
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
                    ForEach(result.approximate, id: \.kunde) { a in
                        Label(
                            "\(a.kunde) — \(a.precision.shortLabel)",
                            systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
