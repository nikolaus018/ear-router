import SwiftUI
import SwiftData

/// Paste a tour Eray's planner wrote out, and take its customers.
///
/// A paste screen rather than an editor: unlike `JSONEditorSheet`, there is
/// nothing on this side to export back into it and nothing to hand-write — a
/// document arrives whole, from somewhere else, and the only thing to do with
/// it is read it. So "Weiter" parses it and hands the entries straight to the
/// same `ImportReviewView` every other import ends on.
///
/// The customers are all it takes. Start, Lager and Ziel stay the tour's own,
/// and the sequence stays the optimizer's — see `ErayImport`.
///
/// Two ways in, like the portal import: from a tour's own menu this adds to
/// that tour; from Touren's "+" there is no tour yet, and one is created —
/// named after the document — only once there is something real to put on it,
/// then deleted again if the driver walks out of the review without saving.
struct ErayImportSheet: View {
    enum Mode {
        case existing(Route)
        case newRoute
    }

    let mode: Mode
    var onRouteCreated: ((Route) -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    /// A full-screen `TextEditor` has no way out of the keyboard of its own.
    /// See `JSONEditorSheet`.
    @FocusState private var editing: Bool
    @State private var review: ReviewContext?
    /// Only ever set in `.newRoute` mode — the shell created to have
    /// something to hand the review. Cleared, and the route with it, unless
    /// the review actually saves.
    @State private var createdRoute: Route?
    @State private var imported = false
    @State private var error: AppError?
    @State private var confirmingDiscard = false

    /// What `ImportReviewView` needs, bundled so the sheet always presents
    /// the route the entries were parsed for — `.newRoute` has no route until
    /// the paste has been read.
    struct ReviewContext: Identifiable {
        let id = UUID()
        let route: Route
        let entries: [CustomerJSON]
    }

    init(mode: Mode, onRouteCreated: ((Route) -> Void)? = nil) {
        self.mode = mode
        self.onRouteCreated = onRouteCreated
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { placeholder }
                }
                .padding(.horizontal, 12)
                .focused($editing)
                .navigationTitle("Eray-Import")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .errorAlert($error)
                .interactiveDismissDisabled(!text.isEmpty)
        }
        .sheet(item: $review, onDismiss: reviewDismissed) { ctx in
            ImportReviewView(route: ctx.route, entries: ctx.entries) { imported = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Schließen") {
                if text.isEmpty { dismiss() } else { confirmingDiscard = true }
            }
            .confirmationDialog(
                "Liste verwerfen?", isPresented: $confirmingDiscard, titleVisibility: .visible
            ) {
                Button("Verwerfen", role: .destructive) { dismiss() }
                Button("Weiter", role: .cancel) {}
            }
        }
        ToolbarItem(placement: .primaryAction) {
            // "Weiter", not "Übernehmen": nothing on the tour changes until
            // the list has been looked over one screen further on.
            Button("Weiter") { submit() }
                .disabled(text.trimmed.isEmpty)
        }
        ToolbarItem(placement: .keyboard) { Spacer() }
        ToolbarItem(placement: .keyboard) {
            Button("Fertig") { editing = false }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            // The system paste control still, so no "would like to paste
            // from…" alert lands in the middle of the one action this screen
            // exists for — but greyed out when the clipboard has nothing on
            // it, which is what it would not do on its own. See
            // `PasteTextButton`, which the JSON editor uses too.
            PasteTextButton { text = $0 }
            Spacer()
            Button("Leeren", role: .destructive) { text = "" }
                .disabled(text.isEmpty)
        }
    }

    /// What the screen shows before anything is in it. Not an example of the
    /// format: nobody writes one of these by hand, and a page of it would
    /// bury the one sentence that matters.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Die Tour aus Erays Planer hier einsetzen.")
                .font(.footnote)
            Text(
                "Übernommen werden nur die Kunden. Start, Lager und Ziel bleiben, wie sie "
                    + "sind, die Adressen werden wie immer selbst gesucht, und die "
                    + "Reihenfolge optimiert die App.")
                .font(.footnote)
        }
        .foregroundStyle(.tertiary)
        // The insets `TextEditor` puts around its own text.
        .padding(.horizontal, 5)
        .padding(.vertical, 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// Reads the paste and hands it on to be checked. Nothing here reaches
    /// the geocoder or the tour.
    private func submit() {
        do {
            let document = try ErayImport.parse(text)
            let entries = ErayImport.entries(from: document)
            switch mode {
            case .existing(let route):
                review = ReviewContext(route: route, entries: entries)
            case .newRoute:
                // Created only now that there is something real to put on it.
                let open = FetchDescriptor<Route>(
                    predicate: #Predicate { $0.statusRaw == "active" })
                let taken = Set(((try? context.fetch(open)) ?? []).map(\.name))
                let route = try RouteStore.createRoute(
                    name: ErayImport.routeName(for: document, taken: taken), in: context)
                createdRoute = route
                review = ReviewContext(route: route, entries: entries)
            }
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Import fehlgeschlagen.")
        }
    }

    /// Runs once the review sheet is gone, whichever way it went. Both
    /// branches only matter in `.newRoute` mode — see `GourmetImportSheet`,
    /// which does exactly this for the same reason.
    private func reviewDismissed() {
        defer { imported = false }
        if let createdRoute {
            if imported {
                onRouteCreated?(createdRoute)
            } else {
                try? RouteStore.delete(createdRoute, in: context)
            }
            self.createdRoute = nil
        }
        if imported { dismiss() }
    }
}
