import SwiftUI
import SwiftData

struct RouteDetailView: View {
    @Bindable var route: Route
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus
    @Environment(\.openURL) private var openURL

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
    /// Briefly tinted after arriving from a map pin, so the driver's eye
    /// lands on the row that was tapped rather than on the middle of a list.
    @State private var highlighted: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: focus.revealStopID, initial: true) { _, id in
                    guard let id else { return }
                    // Cleared immediately so this fires once, not on every
                    // redraw of the list.
                    focus.revealStopID = nil
                    search = ""
                    highlighted = id
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation { highlighted = nil }
                    }
                }
        }
    }

    private var list: some View {
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
                        // Faintly tinted. This row is a *repeat* of one further
                        // down the list, and without something marking it as
                        // pinned-to-the-top the same customer appearing twice on
                        // one screen just looks like a bug.
                        .listRowBackground(Color.brand.opacity(0.07))
                }
            }

            Section {
                ForEach(visibleStops) { stop in
                    row(for: stop)
                }
            } header: {
                Text(listHeader)
            } footer: {
                if let totals = totalsLine { Text(totals) }
            }

            // Nothing to deliver yet. A route always has its three fixed
            // points, so the list is never actually empty — which is exactly
            // why a freshly created tour needed something saying what to do
            // next instead of three grey rows and silence.
            if route.customerStops.isEmpty && search.isEmpty {
                Section {
                    EmptyStopsPrompt(
                        onAdd: { addingStop = true },
                        onPaste: { showingJSON = true })
                }
            }

            // The tour is done. Finishing it is deliberately still the driver's
            // call (see `RouteStore.setDelivered`), but the call should not be
            // buried in an overflow menu at the moment it becomes the only
            // thing left to do.
            if route.isComplete && route.status == .active && search.isEmpty {
                Section {
                    Button {
                        try? RouteStore.toggleStatus(route, in: context)
                    } label: {
                        Label("Tour abschließen", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        // The one place in-flight work is reported. `busy` already carried a
        // sentence describing what was happening; before this it went nowhere,
        // and a bare spinner in the toolbar left the driver guessing whether
        // the app was optimising, geocoding or removing something.
        // `safeAreaInset`, not an overlay: the list runs underneath the floating
        // tab bar, so a banner pinned to the bottom of its frame would be drawn
        // behind it. An inset is placed *inside* the safe area, above the bar,
        // and takes up no room at all while there is nothing to report.
        .safeAreaInset(edge: .bottom) {
            if let busy {
                BusyBanner(text: busy)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: busy)
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
            StopEditorSheet(route: route, stop: stop) {
                // Dismissed first, then deleted: the sheet is bound to this
                // stop, and tearing the object out from under it would leave
                // the sheet rendering a row that no longer exists.
                editingStop = nil
                Task { await delete(stop) }
            }
        }
        .sheet(isPresented: $showingJSON) {
            JSONEditorSheet(route: route)
        }
        .sheet(isPresented: $showingLadeliste) {
            LadelisteView(route: route)
        }
        .alert("Tour umbenennen", isPresented: $renaming) {
            TextField("Name", text: $newName)
                .limited(to: FieldLimits.routeName, text: $newName)
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

    /// Extracted for the same reason `StopListRow` was: adding one more
    /// modifier inside the `ForEach` pushed the enclosing `List` past what the
    /// type checker will solve in reasonable time.
    private func row(for stop: Stop) -> some View {
        StopListRow(
            stop: stop,
            sameDoorCount: doorGroups[stop.id]?.count ?? 1,
            number: customerNumbers[stop.id],
            onTap: { tapped(stop) },
            onToggleDelivered: { setDelivered(stop, !stop.delivered) },
            onDelete: { Task { await delete(stop) } },
            onNavigate: { open(stop) })
            // The id is the scroll target `reveal` aims at.
            .id(stop.id)
            .listRowBackground(highlighted == stop.id ? Color.brand.opacity(0.12) : nil)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Stays a plus, disabled, while work is in flight. Swapping it for
            // a spinner moved the button the driver was aiming at and said less
            // than the banner at the bottom of the screen already says.
            Button("Stopp hinzufügen", systemImage: "plus") { addingStop = true }
                .disabled(busy != nil)
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
        // "0 von 0 geliefert" over a route that has only its three fixed points
        // is a progress report on nothing.
        if route.customerStops.isEmpty { return "Fixpunkte" }
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
        openURL(url)
    }
}

/// What the list shows a driver who has just created a tour: the two ways
/// stops get onto it, rather than three grey fixed rows and no next step.
struct EmptyStopsPrompt: View {
    let onAdd: () -> Void
    let onPaste: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Noch keine Kundenstopps")
                    .font(.headline)
                Text("Einzeln hinzufügen, oder die ganze Tagesliste auf einmal einsetzen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                Button("Stopp hinzufügen", systemImage: "plus", action: onAdd)
                    .buttonStyle(.borderedProminent)
                Button("Liste als JSON einsetzen", systemImage: "curlybraces", action: onPaste)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }
}

/// The "something is happening" pill. A capsule floating over the list rather
/// than a scrim across it: the driver can still read and scroll the stops while
/// an optimization runs, which is a slow network call they have no reason to be
/// locked out of.
struct BusyBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct OptimizeBanner: View {
    let busy: Bool
    let retry: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.warning)
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
