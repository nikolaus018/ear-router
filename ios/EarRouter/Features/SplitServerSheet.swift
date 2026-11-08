import SwiftUI
import SwiftData

/// "Vom Server laden" in Tour aufteilen: the parts sent to the split server
/// over the last weeks, by day, today on top. Picking one makes it a tour on
/// this phone, through the same review a portal import goes through.
///
/// A part carries only names and addresses; Paket, phone, note and postcode
/// come from this phone's own Zusteller-Portal login on the way in — see
/// `SplitServer.portalEntries`.
struct SplitServerSheet: View {
    var onOpenedTour: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @State private var parts: [SplitServer.Summary]?
    @State private var busy: String?
    @State private var task: Task<Void, Never>?
    @State private var error: AppError?
    @State private var hasKey = SplitServer.key != nil
    @State private var keyDraft = ""
    @State private var changingKey = false
    @State private var deleting: SplitServer.Summary?
    /// The last load did not get the list — the empty screen then says so
    /// and offers to try again, rather than "Nichts am Server".
    @State private var loadFailed = false

    @State private var review: Pending?
    /// Kept across the dismissal — see `SplitOverview.pending`.
    @State private var pending: Pending?
    @State private var imported = false

    struct Pending: Identifiable {
        let id = UUID()
        let route: Route
        let part: SplitServer.Part
        /// The day the server filed it under, "2026-11-06".
        let day: String
        /// The part's stops with the portal's Paket, phone and note, and what
        /// the portal could not answer for.
        let portal: SplitServer.PortalResult
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasKey {
                    list
                } else {
                    keyForm
                }
            }
            .navigationTitle("Vom Server laden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                if hasKey {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Neu laden", systemImage: "arrow.clockwise") {
                                task = Task { await load() }
                            }
                            Button("API-Schlüssel ändern", systemImage: "key") { changingKey = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Mehr")
                    }
                }
            }
            .floatingBanner {
                if let busy { BusyBanner(text: busy, onCancel: { task?.cancel() }) }
            }
            .animation(.snappy, value: busy)
            .errorAlert($error)
            .task { if hasKey { await load() } }
            .refreshable { await load() }
            .alert("API-Schlüssel ändern", isPresented: $changingKey) {
                SecureField("API-Schlüssel", text: $keyDraft)
                Button("Sichern") { saveKey() }
                Button("Abbrechen", role: .cancel) { keyDraft = "" }
            }
            .confirmationDialog(
                "Vom Server löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible, presenting: deleting
            ) { part in
                Button("Löschen", role: .destructive) { task = Task { await delete(part) } }
            } message: { part in
                Text("„\(part.title)“ ist dann für niemanden mehr abrufbar.")
            }
            .sheet(item: $review, onDismiss: reviewDismissed) { ctx in
                ImportReviewView(
                    route: ctx.route, entries: ctx.portal.entries,
                    notice: ctx.portal.notice(tour: ctx.part.tour, day: ctx.day),
                    hints: ctx.portal.entries.indices.map(ctx.portal.hint(at:))
                ) { imported = true }
            }
        }
    }

    // MARK: Screens

    private var keyForm: some View {
        Form {
            Section {
                SecureField("API-Schlüssel", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveKey)
                Button("Sichern", action: saveKey)
                    .disabled(keyDraft.trimmed.isEmpty)
            } footer: {
                Text("Den API-Schlüssel legt der Admin auf ear-split-api.ringtwo.win an. Einmal auf diesem Telefon eingeben.")
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if let parts {
            if parts.isEmpty && loadFailed {
                ContentUnavailableView {
                    Label("Liste nicht geladen", systemImage: "icloud.slash")
                } actions: {
                    Button("Neu laden") { task = Task { await load() } }
                }
            } else if parts.isEmpty {
                ContentUnavailableView(
                    "Nichts am Server", systemImage: "icloud",
                    description: Text("In den letzten 30 Tagen wurde kein Teil gesendet."))
            } else {
                List {
                    ForEach(days(of: parts), id: \.day) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.parts) { part in
                                Button {
                                    task = Task { await open(part) }
                                } label: {
                                    row(part)
                                }
                                .disabled(busy != nil)
                                .swipeActions {
                                    Button("Löschen", role: .destructive) { deleting = part }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ part: SplitServer.Summary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(part.title).foregroundStyle(.primary)
                Text(part.stops == 1 ? "1 Stopp" : "\(part.stops) Stopps")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    private func days(of parts: [SplitServer.Summary]) -> [(day: String, parts: [SplitServer.Summary])] {
        var order: [String] = []
        var byDay: [String: [SplitServer.Summary]] = [:]
        for p in parts {
            if byDay[p.date] == nil { order.append(p.date) }
            byDay[p.date, default: []].append(p)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    private func dayTitle(_ day: String) -> String {
        guard let date = SplitServer.date(of: day) else { return day }
        if day == SplitServer.dayString(Date()) { return "Heute" }
        if Calendar.current.isDateInYesterday(date) { return "Gestern" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "de_AT")))
    }

    // MARK: Actions

    private func saveKey() {
        let key = keyDraft.trimmed
        keyDraft = ""
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(key, forKey: SplitServer.keyDefaultsKey)
        hasKey = true
        task = Task { await load() }
    }

    /// Whatever happens, the spinner goes: a load that was cancelled or
    /// failed before any list arrived leaves "Neu laden" behind instead.
    private func load() async {
        do {
            parts = try await SplitServer.list()
            loadFailed = false
            return
        } catch is CancellationError {
        } catch let e as AppError {
            hasKey = SplitServer.key != nil
            error = e
        } catch {
            self.error = AppError.message("Die Liste konnte nicht geladen werden.")
        }
        if parts == nil || parts?.isEmpty == true {
            parts = []
            loadFailed = true
        }
    }

    private func delete(_ summary: SplitServer.Summary) async {
        busy = "Wird gelöscht …"
        defer { busy = nil }
        do {
            try await SplitServer.delete(summary.id)
            parts?.removeAll { $0.id == summary.id }
        } catch let e as AppError {
            hasKey = SplitServer.key != nil
            error = e
        } catch {}
    }

    private func open(_ summary: SplitServer.Summary) async {
        busy = "Wird geladen …"
        defer { busy = nil }
        do {
            let part = try await SplitServer.part(summary.id)
            try Task.checkCancellation()
            guard !part.entries.isEmpty else {
                error = AppError.message("Dieser Teil hat keine Stopps.")
                return
            }
            // Paket, phone and note from this phone's own portal login.
            let portal = await SplitServer.portalEntries(for: part, day: summary.date) { text in
                Task { @MainActor in busy = text }
            }
            try Task.checkCancellation()
            let open = FetchDescriptor<Route>(predicate: #Predicate { $0.statusRaw == "active" })
            let taken = Set(((try? context.fetch(open)) ?? []).map(\.name))
            var name = summary.title
            if taken.contains(name), let date = SplitServer.date(of: summary.date) {
                name += " – " + date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))
            }
            let route = try RouteStore.createRoute(name: name, in: context)
            let ctx = Pending(route: route, part: part, day: summary.date, portal: portal)
            pending = ctx
            review = ctx
        } catch is CancellationError {
        } catch let e as AppError {
            hasKey = SplitServer.key != nil
            error = e
        } catch {
            self.error = AppError.message("Die Tour konnte nicht angelegt werden.")
        }
    }

    /// As `SplitOverview.reviewDismissed`: a saved review opens the tour, one
    /// that saved nothing takes its empty route with it.
    private func reviewDismissed() {
        guard let ctx = pending else { return }
        pending = nil
        defer { imported = false }
        guard imported else {
            try? RouteStore.delete(ctx.route, in: context)
            return
        }
        focus.open(ctx.route)
        // Only the screen underneath is dismissed, and it takes this one
        // with it — two dismissals at once lose one (see `TourSplitSheet`).
        onOpenedTour()
    }
}
