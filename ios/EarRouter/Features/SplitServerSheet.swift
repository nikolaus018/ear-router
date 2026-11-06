import SwiftUI
import SwiftData

/// "Vom Server laden" in Tour aufteilen: the parts sent to the split server
/// over the last weeks, by day, today on top. Picking one makes it a tour on
/// this phone, through the same review a portal import goes through.
///
/// The customers' Globale Infos that came with the part are kept on this
/// phone too — but only for customers it knows nothing about yet: what the
/// driver here has written down about a door is not overwritten by somebody
/// else's phone.
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

    @State private var review: Pending?
    /// Kept across the dismissal — see `SplitOverview.pending`.
    @State private var pending: Pending?
    @State private var imported = false

    struct Pending: Identifiable {
        let id = UUID()
        let route: Route
        let part: SplitServer.Part
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
                ImportReviewView(route: ctx.route, entries: ctx.part.entries) { imported = true }
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
            if parts.isEmpty {
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

    private func load() async {
        do {
            parts = try await SplitServer.list()
        } catch is CancellationError {
        } catch let e as AppError {
            if parts == nil { parts = [] }
            hasKey = SplitServer.key != nil
            error = e
        } catch {
            self.error = AppError.message("Die Liste konnte nicht geladen werden.")
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
            let open = FetchDescriptor<Route>(predicate: #Predicate { $0.statusRaw == "active" })
            let taken = Set(((try? context.fetch(open)) ?? []).map(\.name))
            var name = summary.title
            if taken.contains(name), let date = SplitServer.date(of: summary.date) {
                name += " – " + date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))
            }
            let route = try RouteStore.createRoute(name: name, in: context)
            let ctx = Pending(route: route, part: part)
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
        let infos = ctx.part.infos
        if !infos.isEmpty {
            for stop in ctx.route.stops {
                guard let key = StockwerkKey.make(for: stop), let info = infos[key],
                    (try? StockwerkStore.note(forKey: key, in: context)) == nil
                else { continue }
                try? StockwerkStore.save(info, for: stop, in: context)
            }
        }
        focus.open(ctx.route)
        // Only the screen underneath is dismissed, and it takes this one
        // with it — two dismissals at once lose one (see `TourSplitSheet`).
        onOpenedTour()
    }
}
