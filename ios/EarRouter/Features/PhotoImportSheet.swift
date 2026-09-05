import SwiftUI
import SwiftData
import PhotosUI
import VisionKit

/// Import a day's stops by photographing the printed list.
///
/// The dispatch office hands the driver the tour on paper, and until now
/// getting it into the app meant typing thirty addresses, or typing thirty
/// addresses as JSON. This scans the sheet instead — the same import the JSON
/// editor runs, with the entries read off the page rather than typed.
///
/// Nothing is written until the driver has seen every row. OCR of a table
/// photographed on a van seat is right most of the time and not all of the
/// time, and the failure it makes — a plausible-looking wrong house number —
/// is not one that announces itself later. So the scan produces a review list
/// first, rows that came out incomplete are flagged rather than quietly
/// dropped, and each one can be corrected or deleted before any of it becomes
/// a stop.
struct PhotoImportSheet: View {
    let route: Route
    /// Hands the scanned list to the JSON editor instead of importing it.
    /// The escape hatch for a page OCR made a mess of: the driver gets the
    /// whole list as text and fixes it there rather than row by row in here.
    let onEditAsJSON: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var stops: [ScannedStop] = []
    /// How many photos have been read this session, so a second batch's pages
    /// are reported by their number in the whole stack rather than in the
    /// batch.
    @State private var pagesRead = 0
    @State private var pagesWithoutTable: [Int] = []

    @State private var picking: [PhotosPickerItem] = []
    @State private var showingScanner = false
    @State private var editing: ScannedStop?

    @State private var reading = false
    @State private var importing = false
    @State private var progress: String?
    @State private var error: AppError?
    @State private var result: ImportReport?

    /// Roughly ten rows print on a page, and a route holds `maxBulkStops` of
    /// them. Well clear of both, and low enough that a mis-tap in the picker
    /// cannot queue up a hundred holiday photos for OCR.
    private static let maxPages = 12

    private var busy: Bool { reading || importing }
    private var usable: [ScannedStop] { stops.filter(\.isUsable) }

    var body: some View {
        NavigationStack {
            content
                // Short enough to survive the two glass toolbar buttons
                // either side of it, for the same reason the JSON editor's
                // title is one word: "Liste scannen" truncated to "Liste
                // scann…", which reads as a bug rather than as a title.
                .navigationTitle("Aus Foto")
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
        }
        .interactiveDismissDisabled(busy)
        .fullScreenCover(isPresented: $showingScanner) {
            DocumentScanner(
                onFinish: { pages in
                    showingScanner = false
                    Task { await add(pages) }
                },
                onCancel: { showingScanner = false })
                .ignoresSafeArea()
        }
        // `onChange` rather than the picker's own completion, because a
        // `PhotosPicker` reports its selection by writing the binding.
        .onChange(of: picking) { _, items in
            guard !items.isEmpty else { return }
            picking = []
            Task { await add(loading: items) }
        }
        .sheet(item: $editing) { stop in
            ScannedStopEditor(
                stop: stop,
                number: (stops.firstIndex { $0.id == stop.id }).map { $0 + 1 }
            ) { edited in
                guard let i = stops.firstIndex(where: { $0.id == edited.id }) else { return }
                stops[i] = edited
            }
        }
        .sheet(item: $result) { report in
            ImportSummary(result: report.result)
                .presentationDetents([.medium, .large])
        }
        .errorAlert($error)
    }

    // MARK: - Screens

    @ViewBuilder
    private var content: some View {
        if stops.isEmpty && pagesRead == 0 {
            intro
        } else if stops.isEmpty && !reading {
            nothingFound
        } else {
            review
        }
    }

    private var intro: some View {
        ContentUnavailableView {
            Label("Tagesliste abfotografieren", systemImage: "text.viewfinder")
        } description: {
            Text(
                "Die App liest Kunde, Straße, Bezirk, Paket und Hinweis aus der gedruckten "
                    + "Liste heraus. Alles bleibt am Gerät — es wird kein Foto verschickt.")
        } actions: {
            VStack(spacing: 10) {
                // Only where there is a camera to open. On a device without
                // one the button is not disabled, it is absent: a greyed-out
                // control invites a driver to work out what is wrong with it.
                if VNDocumentCameraViewController.isSupported {
                    Button { showingScanner = true } label: {
                        WideButtonLabel("Seiten scannen", systemImage: "camera.fill")
                            .onBrandLabel()
                    }
                    .buttonStyle(.borderedProminent)
                }
                photosPicker("Fotos auswählen", systemImage: "photo.on.rectangle", wide: true)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .frame(maxWidth: 320)
        }
    }

    /// Photos were read and no table came out of any of them. A blank review
    /// list would say the same thing while looking like a bug.
    private var nothingFound: some View {
        ContentUnavailableView {
            Label("Keine Tabelle erkannt", systemImage: "doc.questionmark")
        } description: {
            Text(
                "Auf \(Format.pages(pagesRead)) war keine Liste zu erkennen. Am besten die "
                    + "Seite flach hinlegen, gerade von oben aufnehmen und darauf achten, "
                    + "dass die ganze Tabelle im Bild ist.")
        } actions: {
            VStack(spacing: 10) {
                if VNDocumentCameraViewController.isSupported {
                    Button { showingScanner = true } label: {
                        WideButtonLabel("Noch einmal scannen", systemImage: "camera.fill")
                            .onBrandLabel()
                    }
                    .buttonStyle(.borderedProminent)
                }
                photosPicker("Fotos auswählen", systemImage: "photo.on.rectangle", wide: true)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .frame(maxWidth: 320)
        }
    }

    private var review: some View {
        List {
            if !pagesWithoutTable.isEmpty {
                Section {
                    Label(
                        "Auf Seite \(pagesWithoutTable.map(String.init).formatted(.list(type: .and))) "
                            + "war keine Tabelle zu erkennen. Diese Seite bitte noch einmal "
                            + "aufnehmen.",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.warningText)
                }
            }

            Section {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    Button { editing = stop } label: { row(stop, number: index + 1) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Entfernen", systemImage: "trash", role: .destructive) {
                                stops.removeAll { $0.id == stop.id }
                            }
                        }
                }
            } header: {
                Text(header)
            } footer: {
                Text(footer)
            }
        }
        .listStyle(.insetGrouped)
        .disabled(busy)
    }

    private var header: String {
        let bad = stops.count - usable.count
        let read = "\(Format.stops(stops.count)) aus \(Format.pages(pagesRead))"
        return bad == 0 ? read : "\(read) · \(bad) unvollständig"
    }

    private var footer: String {
        var lines = [
            "Zum Ausbessern auf eine Zeile tippen, zum Entfernen nach links wischen."
        ]
        // Said out loud, because "Übernehmen" quietly leaving two customers
        // behind is exactly the kind of thing nobody notices until a meal is
        // missing. The count in the header says how many are incomplete; this
        // says what happens to them.
        let bad = stops.count - usable.count
        if bad > 0 {
            lines.append(
                bad == 1
                    ? "Die unvollständige Zeile wird nicht übernommen."
                    : "Die \(bad) unvollständigen Zeilen werden nicht übernommen.")
        }
        lines.append(
            "Beim Übernehmen ersetzen diese Stopps die Kundenstopps der Tour — also "
                + "zuerst alle Seiten der Liste hinzufügen.")
        return lines.joined(separator: " ")
    }

    private func row(_ stop: ScannedStop, number: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Its place in this list, not the tour's own Stopp number off the
            // paper. That column is printed in the narrowest space on the page
            // and wraps mid-number, and a row labelled with a *wrong* stop
            // number is worse than one with none: the number is the thing the
            // driver checks the list against the paper by. Counted here, the
            // rows are in the order the pages were, so the check still works —
            // and a count that ends at 41 against a paper that ends at 43 says
            // exactly what it should.
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.kunde.nilIfEmpty ?? "Ohne Namen")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(stop.kunde.isEmpty ? .secondary : .primary)
                Text([stop.strasse.nilIfEmpty, stop.plz.nilIfEmpty]
                    .compactMap { $0 }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let paket = stop.paket {
                    Text(paket).font(.caption)
                }
                if let notiz = stop.notiz {
                    Text(notiz).font(.caption).foregroundStyle(.secondary)
                }
                if let problem = stop.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.warningText)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Schließen") { dismiss() }.disabled(busy)
        }
        ToolbarItem(placement: .primaryAction) {
            if importing {
                ProgressView()
            } else {
                Button("Übernehmen") { Task { await apply() } }
                    .disabled(usable.isEmpty || busy)
            }
        }
        if !stops.isEmpty {
            ToolbarItemGroup(placement: .bottomBar) {
                if VNDocumentCameraViewController.isSupported {
                    Button("Weitere Seite", systemImage: "camera") { showingScanner = true }
                        .disabled(busy)
                }
                photosPicker("Fotos", systemImage: "photo.on.rectangle")
                    .disabled(busy)
                Spacer()
                Button("Als JSON", systemImage: "curlybraces") {
                    onEditAsJSON(RouteStore.exportJSON(stops.map(\.asJSON)))
                }
                .disabled(busy)
            }
        }
    }

    /// One picker, configured the same way wherever it appears. `maxPages`
    /// rather than an unlimited selection, and images only.
    ///
    /// Takes the label as two strings rather than as a view, because
    /// `PhotosPicker`'s label closure is `@Sendable` and a generic `some View`
    /// handed into it is not.
    private func photosPicker(
        _ title: String, systemImage: String, wide: Bool = false
    ) -> some View {
        PhotosPicker(
            selection: $picking, maxSelectionCount: Self.maxPages,
            selectionBehavior: .ordered, matching: .images, photoLibrary: .shared()
        ) {
            PickerLabel(title, systemImage: systemImage, wide: wide)
        }
    }

    // MARK: - Actions

    private func add(loading items: [PhotosPickerItem]) async {
        reading = true
        progress = "Fotos werden geladen …"
        var pages: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                pages.append(data)
            }
        }
        // `add` sets it again for the OCR itself; cleared here so a load that
        // yielded nothing does not leave the pill up.
        reading = false
        progress = nil
        guard !pages.isEmpty else {
            error = AppError.message("Die ausgewählten Fotos konnten nicht geladen werden.")
            return
        }
        await add(pages)
    }

    private func add(_ pages: [Data]) async {
        guard !pages.isEmpty else { return }
        reading = true
        defer { reading = false; progress = nil }

        let offset = pagesRead
        let scan = await ListeOCR.read(pages: pages) { done, total in
            progress = "Seite \(done + 1) von \(total) wird gelesen …"
        }
        pagesRead += pages.count
        pagesWithoutTable.append(contentsOf: scan.pagesWithoutTable.map { $0 + offset })
        // Appended in the order the pages were handed in, which is the order
        // the tour is printed in. Nothing is sorted or merged: the paper is
        // the authority on what order these stops go in, and the optimizer
        // decides the order they are *driven* in anyway.
        stops += scan.stops
    }

    private func apply() async {
        importing = true
        defer { importing = false; progress = nil }

        do {
            let r = try await RouteStore.importJSON(
                usable.map(\.asJSON), into: route, in: context
            ) { done, total in
                progress = "Adresse \(done + 1) von \(total) wird gesucht …"
            }
            // Same as the JSON editor: a clean import has nothing left to say,
            // one with problems reports itself over a review list the driver
            // can still correct from.
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

/// The label inside a `PhotosPicker`.
///
/// Its own type rather than a `Label` written inline, because the picker's
/// label closure is `@Sendable` and `Label`'s initializer is isolated to the
/// main actor — so building one in there is a concurrency warning, while
/// building this is not.
private struct PickerLabel: View {
    let title: String
    let systemImage: String
    let wide: Bool

    nonisolated init(_ title: String, systemImage: String, wide: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.wide = wide
    }

    var body: some View {
        if wide {
            WideButtonLabel(title, systemImage: systemImage)
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Fixing up one scanned row before it is imported.
///
/// Bezirk is a picker rather than a text field, for the same reason it is one
/// in `StopEditorSheet` — and more so here, since a misread postcode is the
/// single likeliest thing to come back wrong off a photograph, and the picker
/// cannot produce a value the import would then reject.
private struct ScannedStopEditor: View {
    @State private var draft: ScannedStop
    private let number: Int?
    private let onSave: (ScannedStop) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?

    private enum Field: Hashable { case kunde, strasse, paket, notiz }

    init(stop: ScannedStop, number: Int?, onSave: @escaping (ScannedStop) -> Void) {
        _draft = State(initialValue: stop)
        self.number = number
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Kunde") {
                    TextField("Name", text: $draft.kunde)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .kunde)
                        .onSubmit { focused = .strasse }
                        .limited(to: FieldLimits.kunde, text: $draft.kunde)
                }
                Section("Adresse") {
                    TextField("Straße und Hausnummer", text: $draft.strasse)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .strasse)
                        .onSubmit { focused = .paket }
                        .limited(to: FieldLimits.strasse, text: $draft.strasse)
                    Picker("Bezirk", selection: $draft.plz) {
                        Text("Bitte wählen").tag("")
                        // A postcode the camera got wrong is not in the list,
                        // and dropping it silently would leave the picker
                        // sitting on "Bitte wählen" as though nothing had been
                        // read at all. Kept as its own entry so the driver can
                        // see what it read and what they are replacing.
                        if !draft.plz.isEmpty, !Districts.isValid(draft.plz) {
                            Text("\(draft.plz) — nicht erkannt").tag(draft.plz)
                        }
                        ForEach(Districts.all) { d in
                            Text("\(d.plz) — \(d.label)").tag(d.plz)
                        }
                    }
                }
                Section("Lieferung") {
                    TextField("Paket", text: paket)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .paket)
                        .onSubmit { focused = .notiz }
                        .limited(to: FieldLimits.paket, text: paket)
                    TextField("Notiz", text: notiz, axis: .vertical)
                        .lineLimit(2...6)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .notiz)
                        .limited(to: FieldLimits.notiz, text: notiz)
                }
            }
            .navigationTitle(number.map { "Stopp \($0)" } ?? "Stopp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        draft.kunde = draft.kunde.trimmed
                        draft.strasse = draft.strasse.trimmed
                        draft.paket = draft.paket?.trimmed.nilIfEmpty
                        draft.notiz = draft.notiz?.trimmed.nilIfEmpty
                        onSave(draft)
                        dismiss()
                    }
                }
            }
        }
    }

    /// `TextField` wants a non-optional binding; the model wants "no Paket" to
    /// be absent rather than an empty string.
    private var paket: Binding<String> {
        Binding(get: { draft.paket ?? "" }, set: { draft.paket = $0.nilIfEmpty })
    }

    private var notiz: Binding<String> {
        Binding(get: { draft.notiz ?? "" }, set: { draft.notiz = $0.nilIfEmpty })
    }
}
