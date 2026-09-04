import SwiftUI
import SwiftData

struct RouteDetailView: View {
    @Bindable var route: Route
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @State private var search = ""
    @State private var editingStop: Stop?
    @State private var addingStop = false
    @State private var showingJSON = false
    @State private var showingLadeliste = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var busy: String?
    @State private var error: AppError?
    @State private var recheckSummary: String?

    var body: some View {
        List {
            if route.needsOptimize {
                Section {
                    OptimizeBanner(busy: busy != nil) { await optimize() }
                }
            }

            if let next = route.nextOpenStop, search.isEmpty {
                Section("Nächster Stopp") {
                    StopRow(
                        stop: next, isNext: true,
                        sameDoorCount: doorGroups[next.id]?.count ?? 1,
                        number: customerNumbers[next.id],
                        onToggleDelivered: { setDelivered(next, true) },
                        onNavigate: { open(next) })
                        .contentShape(.rect)
                        .onTapGesture { editingStop = next }
                }
            }

            Section {
                ForEach(visibleStops) { stop in
                    StopListRow(
                        stop: stop,
                        sameDoorCount: doorGroups[stop.id]?.count ?? 1,
                        number: customerNumbers[stop.id],
                        onTap: { tapped(stop) },
                        onToggleDelivered: { setDelivered(stop, !stop.delivered) },
                        onDelete: { Task { await delete(stop) } },
                        onNavigate: { open(stop) })
                }
            } header: {
                Text(listHeader)
            } footer: {
                if let totals = totalsLine { Text(totals) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Kunde, Straße oder Bezirk")
        .refreshable { await optimize() }
        .toolbar { toolbar }
        .sheet(isPresented: $addingStop) {
            StopEditorSheet(route: route, stop: nil)
        }
        .sheet(item: $editingStop) { stop in
            StopEditorSheet(route: route, stop: stop)
        }
        .sheet(isPresented: $showingJSON) {
            JSONEditorSheet(route: route)
        }
        .sheet(isPresented: $showingLadeliste) {
            LadelisteView(route: route)
        }
        .alert("Tour umbenennen", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") { try? RouteStore.rename(route, to: newName, in: context) }
        }
        .errorAlert($error)
        // An alert only where there is something to report. "Route optimiert"
        // gets none: the amber banner disappearing and the distances updating
        // is the confirmation, and Apple does not interrupt for success.
        .alert("Adressen geprüft", isPresented: recheckAlert) {
            Button("OK", role: .cancel) { recheckSummary = nil }
        } message: {
            Text(recheckSummary ?? "")
        }
        .onAppear { focus.focus(route) }
    }

    // MARK: - Pieces

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if busy != nil {
                ProgressView()
            } else {
                Button("Stopp hinzufügen", systemImage: "plus") { addingStop = true }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Ladeliste", systemImage: "checklist") { showingLadeliste = true }
                Button("Stopps als JSON", systemImage: "curlybraces") { showingJSON = true }
                Divider()
                Button("Neu optimieren", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await optimize() }
                }
                Button("Adressen prüfen", systemImage: "mappin.and.ellipse") {
                    Task { await recheck() }
                }
                Divider()
                Button("Umbenennen", systemImage: "pencil") {
                    newName = route.name
                    renaming = true
                }
                Button("Lieferstatus zurücksetzen", systemImage: "arrow.counterclockwise") {
                    try? RouteStore.resetDelivered(route, in: context)
                }
                Button(
                    route.status == .active ? "Als erledigt markieren" : "Wieder aktivieren",
                    systemImage: route.status == .active ? "checkmark.seal" : "arrow.uturn.backward"
                ) {
                    try? RouteStore.toggleStatus(route, in: context)
                }
            } label: {
                Label("Mehr", systemImage: "ellipsis.circle")
            }
            .disabled(busy != nil)
        }
    }

    private var recheckAlert: Binding<Bool> {
        Binding(
            get: { recheckSummary != nil },
            set: { if !$0 { recheckSummary = nil } })
    }

    /// Which stops share a front door — two households in one Gemeindebau is
    /// one ring of the bell and two meals carried up, so the list says so.
    private var doorGroups: [UUID: [UUID]] {
        SameDoor.groups(for: route.orderedStops)
    }

    /// Each customer's position in driving order, so the list badge and the
    /// map pin show the same number.
    private var customerNumbers: [UUID: Int] {
        var out: [UUID: Int] = [:]
        for (i, s) in route.customerStops.enumerated() { out[s.id] = i + 1 }
        return out
    }

    private var visibleStops: [Stop] {
        let all = route.orderedStops
        guard !search.isEmpty else { return all }
        let tokens = search.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return all.filter { stop in
            guard stop.kind == .customer else { return false }
            let haystack = [stop.kunde, stop.strasse, stop.plz]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    private var listHeader: String {
        if !search.isEmpty {
            return "\(visibleStops.count) von \(route.customerStops.count) Stopps"
        }
        return "\(route.deliveredCount) von \(route.customerStops.count) geliefert"
    }

    private var totalsLine: String? {
        let t = route.totals
        guard t.km > 0 else { return nil }
        return Format.leg(km: t.km, minutes: t.minutes)
    }

    // MARK: - Actions

    /// Tapping a fixed stop switches it in or out of this tour; tapping a
    /// customer opens the editor.
    private func tapped(_ stop: Stop) {
        if stop.kind.isFixed {
            Task { await toggleExcluded(stop) }
        } else {
            editingStop = stop
        }
    }

    private func setDelivered(_ stop: Stop, _ value: Bool) {
        do { try RouteStore.setDelivered(stop, value, in: context) } catch {
            self.error = AppError.message("Konnte den Lieferstatus nicht speichern.")
        }
    }

    private func toggleExcluded(_ stop: Stop) async {
        busy = stop.excluded ? "Wird wieder eingeplant …" : "Wird ausgelassen …"
        defer { busy = nil }
        do { try await RouteStore.setExcluded(stop, !stop.excluded, in: context) } catch let e as AppError {
            self.error = e
        } catch {
            self.error = AppError.message("Konnte den Stopp nicht ändern.")
        }
    }

    private func delete(_ stop: Stop) async {
        busy = "Wird entfernt …"
        defer { busy = nil }
        do { try await RouteStore.deleteStop(stop, in: context) } catch {
            self.error = AppError.message("Stopp konnte nicht entfernt werden.")
        }
    }

    private func optimize() async {
        busy = "Route wird optimiert …"
        defer { busy = nil }
        do {
            try await RouteOptimizer.optimize(route, in: context)
        } catch let e as AppError {
            self.error = e
        } catch {
            self.error = AppError.routerUnavailable
        }
    }

    private func recheck() async {
        busy = "Adressen werden geprüft …"
        defer { busy = nil }
        let r = await RouteStore.recheckAddresses(route, in: context)
        if r.improved == 0 && r.failed == 0 {
            recheckSummary = "Alle Adressen sind unverändert."
        } else {
            var parts: [String] = []
            if r.improved > 0 { parts.append("\(r.improved) verbessert") }
            if r.unchanged > 0 { parts.append("\(r.unchanged) unverändert") }
            if r.failed > 0 { parts.append("\(r.failed) weiter offen") }
            recheckSummary = parts.joined(separator: ", ") + "."
        }
    }

    private func open(_ stop: Stop) {
        guard let url = NavigationHandoff.url(for: stop) else { return }
        UIApplication.shared.open(url)
    }
}

struct OptimizeBanner: View {
    let busy: Bool
    let retry: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Route nicht aktuell").font(.subheadline.weight(.semibold))
                Text("Reihenfolge und Distanzen stimmen nicht mehr.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Neu") { Task { await retry() } }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
        }
    }
}
