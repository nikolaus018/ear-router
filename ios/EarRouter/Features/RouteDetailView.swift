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
    @State private var showingTuercode = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var busy: String?
    @State private var error: AppError?
    @State private var recheckSummary: String?
    /// A stop swiped (or long-pressed) away, waiting to be confirmed.
    ///
    /// Deleting a stop is not undoable and takes its Paket, its Notiz and its
    /// delivered tick with it. The editor sheet has always asked first; the
    /// swipe in this list did not, so the one path a driver can trigger by
    /// accident — a thumb dragging across a row on a phone in a moving van —
    /// was also the only one that deleted a customer outright.
    @State private var deletingStop: Stop?
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
        // Everything the list needs about the route, derived exactly once.
        //
        // Read as computed properties — which is what these were — each of them
        // re-sorted the route's stops, and `doorGroups` re-ran a whole
        // union-find over it, *per row*, because the `ForEach` body asked for
        // them again for every stop it built. On a full tour that is a hundred
        // sorts and a hundred union-finds for one pass of the list, repeated on
        // every tick of a delivery. Derived here, it is one of each.
        let snapshot = RouteSnapshot(route)
        let visible = visibleStops(in: snapshot)

        return Group {
            if visible.isEmpty && !search.isEmpty {
                // Outside the `List`, not an empty section inside it: as a row
                // it rendered inset under a header counting the nothing it had
                // found.
                ContentUnavailableView.search(text: search)
            } else {
                stops(snapshot, visible: visible)
            }
        }
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
            prompt: "Kunde, Adresse, Paket oder Notiz")
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
        .sheet(isPresented: $showingTuercode) { TuercodeSheet() }
        .alert("Tour umbenennen", isPresented: $renaming) {
            TextField("Name", text: $newName)
                .limited(to: FieldLimits.routeName, text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                save("Die Tour konnte nicht umbenannt werden.") {
                    try RouteStore.rename(route, to: newName, in: context)
                }
            }
        }
        // Bound to the staged stop rather than to a flag, so the sentence the
        // dialog asks survives the dismissal animation instead of blanking out
        // halfway through it — the same reason `PendingRouteDeletion` exists.
        .confirmationDialog(
            "Stopp löschen?",
            isPresented: Binding(
                get: { deletingStop != nil },
                set: { if !$0 { deletingStop = nil } }),
            titleVisibility: .visible,
            presenting: deletingStop
        ) { stop in
            Button("Löschen", role: .destructive) {
                deletingStop = nil
                Task { await delete(stop) }
            }
            Button("Abbrechen", role: .cancel) { deletingStop = nil }
        } message: { stop in
            Text("„\(stop.kunde ?? "Dieser Stopp")“ wird aus der Tour entfernt.")
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

    private func stops(_ snapshot: RouteSnapshot, visible: [Stop]) -> some View {
        List {
            if route.needsOptimize {
                Section {
                    OptimizeBanner(busy: busy != nil) { await optimize() }
                }
            }

            if let next = snapshot.nextOpen, search.isEmpty {
                Section("Nächster Stopp") {
                    StopRow(
                        stop: next, isNext: true,
                        sameDoorCount: snapshot.doorCount(next),
                        number: snapshot.number(next),
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
                ForEach(visible) { stop in
                    row(for: stop, in: snapshot)
                }
            } header: {
                Text(listHeader(snapshot, visible: visible))
            } footer: {
                RouteFooter(snapshot: snapshot, searching: !search.isEmpty)
            }

            // Nothing to deliver yet. A route always has its three fixed
            // points, so the list is never actually empty — which is exactly
            // why a freshly created tour needed something saying what to do
            // next instead of three grey rows and silence.
            if snapshot.customerCount == 0 && search.isEmpty {
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
            if snapshot.isComplete && route.status == .active && search.isEmpty {
                Section {
                    Button {
                        save("Die Tour konnte nicht abgeschlossen werden.") {
                            try RouteStore.toggleStatus(route, in: context)
                        }
                    } label: {
                        WideButtonLabel("Tour abschließen", systemImage: "checkmark.seal.fill")
                            .onBrandLabel()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        // The moment the last meal is ticked off. Every individual tick already
        // gives its own impact; this is the one that says the tour is done,
        // and it is worth feeling through a coat pocket without looking.
        .sensoryFeedback(.success, trigger: snapshot.isComplete) { was, now in
            !was && now
        }
    }

    /// Extracted for the same reason `StopListRow` was: adding one more
    /// modifier inside the `ForEach` pushed the enclosing `List` past what the
    /// type checker will solve in reasonable time.
    private func row(for stop: Stop, in snapshot: RouteSnapshot) -> some View {
        StopListRow(
            stop: stop,
            sameDoorCount: snapshot.doorCount(stop),
            number: snapshot.number(stop),
            onTap: { tapped(stop) },
            onToggleDelivered: { setDelivered(stop, !stop.delivered) },
            onDelete: { deletingStop = stop },
            onNavigate: { open(stop) },
            onShowOnMap: { focus.showOnMap(stop: stop, of: route) })
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
                // Also in Mehr, and it stays there — but this is the screen a
                // driver is standing on when they read "Türcode ENVV" off a
                // Notiz at a front door, and getting to the decoder from here
                // used to mean leaving the tour for another tab.
                Button("Türcode", systemImage: "key.fill") { showingTuercode = true }
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
                    save("Der Lieferstatus konnte nicht zurückgesetzt werden.") {
                        try RouteStore.resetDelivered(route, in: context)
                    }
                }
                Button(
                    route.status == .active ? "Als erledigt markieren" : "Wieder aktivieren",
                    systemImage: route.status == .active ? "checkmark.seal" : "arrow.uturn.backward"
                ) {
                    save("Der Status der Tour konnte nicht geändert werden.") {
                        try RouteStore.toggleStatus(route, in: context)
                    }
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

    private func visibleStops(in snapshot: RouteSnapshot) -> [Stop] {
        guard !search.isEmpty else { return snapshot.ordered }
        let tokens = search.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        return snapshot.ordered.filter { stop in
            guard stop.kind == .customer else { return false }
            // Paket and Notiz are in here as well as the address. They are
            // where the day's real detail lives — "2x Menü", a door code, "Hund
            // im Hof" — and a driver who remembers a note but not the name had
            // no way to find that stop again short of scrolling the whole tour.
            let haystack = [stop.kunde, stop.strasse, stop.plz, stop.paket, stop.notiz]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    private func listHeader(_ snapshot: RouteSnapshot, visible: [Stop]) -> String {
        if !search.isEmpty {
            return "\(visible.count) von \(snapshot.customerCount) Stopps"
        }
        // "0 von 0 geliefert" over a route that has only its three fixed points
        // is a progress report on nothing.
        if snapshot.customerCount == 0 { return "Fixpunkte" }
        return "\(snapshot.deliveredCount) von \(snapshot.customerCount) geliefert"
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
        save("Konnte den Lieferstatus nicht speichern.") {
            try RouteStore.setDelivered(stop, value, in: context)
        }
    }

    /// Runs a store write and says so when it fails.
    ///
    /// These were `try?`. A failed save is rare — it means the store itself is
    /// in trouble — but "rare" is not "impossible", and swallowing it left the
    /// driver tapping "Als erledigt markieren" on a tour that stayed open, with
    /// nothing on screen suggesting why or that anything had gone wrong at all.
    /// One of these actions already reported itself; now they all do.
    private func save(_ failure: String, _ write: () throws -> Void) {
        do { try write() } catch { self.error = AppError.message(failure) }
    }

    /// True when this screen already has something in flight.
    ///
    /// Guards the two long-running, repeatable jobs — optimizing and
    /// re-checking addresses — against being started on top of each other. The
    /// toolbar disables itself while `busy` is set, but pull-to-refresh cannot
    /// be disabled, so a driver could pull the list to optimize during a
    /// minute-long address re-check. Neither corrupts anything (the optimizer
    /// serializes per route), but the two share one banner, and whichever
    /// finished first cleared it and left the other running invisibly.
    ///
    /// Deliberately *not* applied to deleting a stop or switching a fixed point
    /// out: those are one-shot answers to something the driver just asked for,
    /// and silently dropping one of those is worse than two overlapping
    /// banners.
    private var isBusy: Bool { busy != nil }

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
        guard !isBusy else { return }
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
        guard !isBusy else { return }
        busy = "Adressen werden geprüft …"
        defer { busy = nil }
        // Each address is a throttled round trip, so this runs for the better
        // part of a minute on a route with thirty of them. The count is the
        // difference between a driver waiting and a driver wondering.
        let r = await RouteStore.recheckAddresses(route, in: context) { done, total in
            busy = "Adresse \(done + 1) von \(total) wird geprüft …"
        }
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

/// Everything one pass of the stop list needs to know about a route, computed
/// in a single walk of its stops.
///
/// Exists because each of these answers used to be a computed property on
/// `Route` or on the view, and every one of them re-sorted the whole stop array
/// on each read — several times per row, from inside a `ForEach`. The numbers
/// are identical; the difference is that they are worked out once.
struct RouteSnapshot {
    /// The stops in display order — one sort, shared by everything below.
    let ordered: [Stop]
    let customerCount: Int
    let deliveredCount: Int
    let nextOpen: Stop?
    let totalKm: Double
    let totalMinutes: Double
    /// What is still to drive: every leg from the last stop the driver has
    /// actually ticked off to the end of the tour.
    ///
    /// Not the same number as the total, and the total is not the one a driver
    /// halfway through a shift is asking for — "27,3 km" stops meaning
    /// anything the moment the first meal is delivered. A leg belongs to the
    /// stop it leaves from, so everything before the last delivered stop has
    /// been driven and everything from it onwards has not. With nothing
    /// delivered yet this is the whole tour; with everything delivered it is
    /// the drive back to the depot, which is real and still has to be made.
    let remainingKm: Double
    let remainingMinutes: Double

    /// Each customer's position in driving order, so the list badge and the map
    /// pin show the same number.
    private let numbers: [UUID: Int]
    /// How many customers share each stop's front door — two households in one
    /// Gemeindebau is one ring of the bell and two meals carried up.
    private let doorCounts: [UUID: Int]

    var isComplete: Bool { customerCount > 0 && deliveredCount == customerCount }

    /// Customers still waiting for their meal.
    var openCount: Int { customerCount - deliveredCount }

    func number(_ stop: Stop) -> Int? { numbers[stop.id] }
    func doorCount(_ stop: Stop) -> Int { doorCounts[stop.id] ?? 1 }

    init(_ route: Route) {
        let ordered = route.orderedStops
        self.ordered = ordered

        var numbers: [UUID: Int] = [:]
        var customers = 0
        var delivered = 0
        var next: Stop?
        var km = 0.0
        var minutes = 0.0
        // The legs already behind the driver: everything up to, but not
        // including, the leg leaving the last stop they ticked off. Captured
        // *before* this stop's own leg is added, and overwritten by each
        // delivered stop in turn, so the last one to be seen wins — which is
        // the right answer whether the tour was ticked off in order or not.
        var drivenKm = 0.0
        var drivenMinutes = 0.0

        for stop in ordered {
            if stop.kind == .customer {
                customers += 1
                numbers[stop.id] = customers
                if stop.delivered {
                    delivered += 1
                    drivenKm = km
                    drivenMinutes = minutes
                } else if next == nil {
                    next = stop
                }
            }
            // Only the legs actually driven count towards the tour's totals.
            guard !stop.excluded else { continue }
            km += stop.nextLegKm ?? 0
            minutes += stop.nextLegMin ?? 0
        }

        self.customerCount = customers
        self.deliveredCount = delivered
        self.nextOpen = next
        self.numbers = numbers
        self.totalKm = km
        self.totalMinutes = minutes
        // Clamped: a route whose legs were written by two different
        // optimization runs can hold slightly inconsistent numbers, and a
        // negative "still to drive" is worse than a zero.
        self.remainingKm = max(0, km - drivenKm)
        self.remainingMinutes = max(0, minutes - drivenMinutes)
        self.doorCounts = SameDoor.counts(for: ordered)
    }
}

/// The line under the stop list: what is still to drive, and what the whole
/// tour comes to.
///
/// The total on its own was a number for the morning. Once the first meal is
/// delivered the question stops being "how long is this tour" and becomes "how
/// much of it is left" — so that is what leads, with the total kept underneath
/// it for the planning it is still good for. Hidden entirely while the list is
/// filtered: the search shows a handful of stops out of context, and a distance
/// covering the ones it is not showing would only be read as belonging to them.
struct RouteFooter: View {
    let snapshot: RouteSnapshot
    let searching: Bool

    var body: some View {
        if !searching, snapshot.totalKm > 0,
           let total = Format.leg(km: snapshot.totalKm, minutes: snapshot.totalMinutes) {
            VStack(alignment: .leading, spacing: 2) {
                if let remaining = remainingLine {
                    Text(remaining)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.primary)
                }
                Text("Gesamt \(total)")
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// `nil` before the first delivery, when "still to drive" and "the whole
    /// tour" are the same number written twice.
    private var remainingLine: String? {
        guard snapshot.deliveredCount > 0 else { return nil }
        let distance = Format.leg(
            km: snapshot.remainingKm, minutes: snapshot.remainingMinutes)

        if snapshot.isComplete {
            // The last meal is handed over but the van still has to get home,
            // and that drive is the only thing left on the tour.
            guard let distance else { return "Alle Stopps geliefert" }
            return "Alle Stopps geliefert · Rückfahrt \(distance)"
        }

        let stops = "Noch \(Format.stops(snapshot.openCount))"
        guard let distance else { return stops }
        return "\(stops) · \(distance)"
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
                Button(action: onAdd) {
                    WideButtonLabel("Stopp hinzufügen", systemImage: "plus")
                        .onBrandLabel()
                }
                .buttonStyle(.borderedProminent)

                Button(action: onPaste) {
                    WideButtonLabel("Liste einsetzen", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .listRowBackground(Color.clear)
    }
}

/// A button label that fills the width it is given and centres its icon and
/// title inside it.
///
/// Two reasons this is not just `Button(_:systemImage:)`. That initializer's
/// icon is advisory — in a bordered button inside a `List` the system drops it,
/// so a pair of buttons ended up with one icon between them and looked broken.
/// And without the explicit `maxWidth`, two buttons stacked under each other
/// size to their own titles, so they came out different widths with their text
/// sitting at different places on the screen.
struct WideButtonLabel: View {
    private let title: String
    private let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .imageScale(.medium)
            Text(title)
        }
        .fontWeight(.medium)
        .frame(maxWidth: .infinity)
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
            Button { Task { await retry() } } label: {
                Text("Neu").onBrandLabel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
    }
}
