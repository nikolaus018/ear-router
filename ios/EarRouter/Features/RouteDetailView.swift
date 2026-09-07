import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RouteDetailView: View {
    @Bindable var route: Route
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus
    @Environment(\.openURL) private var openURL

    @State private var search = ""
    @State private var editingStop: Stop?
    @State private var addingStop = false
    @State private var showingJSON = false
    /// The office's own file, on its way to being checked over.
    @State private var pickingFile = false
    @State private var fileReview: [CustomerJSON]?
    @State private var showingLadeliste = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var busy: String?
    /// The long job `busy` is describing, kept so the banner can stop it.
    ///
    /// Only the two that run on the network for a minute at a time — optimizing
    /// and re-checking addresses — set this. Ticking a stop off or removing one
    /// is a single write with nothing to interrupt.
    @State private var busyTask: Task<Void, Never>?
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
    /// The stop whose floor is being asked about — set by ticking a delivery
    /// off at a door nothing is known about yet, or from the row's own menu.
    @State private var stockwerkStop: Stop?

    /// Every door ever answered for. Queried whole rather than per row: this is
    /// a few thousand short rows after years of tours, one pass turns it into
    /// the lookup below, and a `@Query` is what makes a floor typed into the
    /// sheet appear on the row behind it without anything having to reload.
    @Query private var stockwerkNotes: [StockwerkNote]

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
        let floors = stockwerkNotes.floors(for: snapshot.ordered)

        return Group {
            if visible.isEmpty && !search.isEmpty {
                // Outside the `List`, not an empty section inside it: as a row
                // it rendered inset under a header counting the nothing it had
                // found.
                ContentUnavailableView.search(text: search)
            } else {
                stops(snapshot, visible: visible, floors: floors)
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
                BusyBanner(text: busy, onCancel: busyTask.map { task in { task.cancel() } })
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
        // Awaited, so pull-to-refresh keeps its own spinner for exactly as
        // long as the optimization runs — but started the same way as the menu
        // item, so it is the same cancellable job with the same stop button.
        .refreshable { await startLongJob { await optimize() }?.value }
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
        .stockwerkPrompt(for: $stockwerkStop)
        .sheet(isPresented: $showingJSON) {
            JSONEditorSheet(route: route)
        }
        // A file and a paste are two ways of saying the same thing, so they
        // arrive at the same screen: the list, as understood, before any of it
        // touches the tour.
        .sheet(item: fileReviewBinding) { payload in
            ImportReviewView(route: route, entries: payload.entries)
        }
        .fileImporter(
            isPresented: $pickingFile,
            // Broad on purpose. A file arriving by mail or AirDrop is regularly
            // typed as plain `data` or `text` whatever its extension says, and a
            // picker that greys out the one file the driver came to open is
            // worse than one that opens it and explains what it found. The
            // format is decided on the bytes in `Tagesliste`, not on the type.
            allowedContentTypes: [
                .commaSeparatedText, .tabSeparatedText, .delimitedText,
                .plainText, .text, .spreadsheet, .data,
            ],
            allowsMultipleSelection: false
        ) { outcome in
            switch outcome {
            case .success(let urls):
                if let url = urls.first { readList(url) }
            case .failure(let failure):
                error = AppError.message(
                    "Die Datei konnte nicht geöffnet werden. \(failure.localizedDescription)")
            }
        }
        .sheet(isPresented: $showingLadeliste) {
            LadelisteView(route: route)
        }
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

    private func stops(
        _ snapshot: RouteSnapshot, visible: [Stop], floors: [UUID: String]
    ) -> some View {
        List {
            if route.needsOptimize {
                Section {
                    OptimizeBanner(busy: busy != nil) { startLongJob { await optimize() } }
                }
            }

            // Not a section with a header and a row in it: the card draws its
            // own surface, so the list's inset-grouped chrome is cleared out
            // from under it. It keeps its place *in* the list rather than
            // floating above one, because the driver scrolls past it to the
            // rest of the tour constantly and a pinned header would eat a
            // sixth of a phone screen for the whole shift.
            if let next = snapshot.nextOpen, search.isEmpty {
                Section {
                    NextStopCard(
                        stop: next,
                        number: snapshot.number(next),
                        stockwerk: floors[next.id],
                        sameDoorCount: snapshot.doorCount(next),
                        deliveredCount: snapshot.deliveredCount,
                        customerCount: snapshot.customerCount,
                        openCount: snapshot.openCount,
                        remainingKm: snapshot.remainingKm,
                        remainingMinutes: snapshot.remainingMinutes,
                        onNavigate: { open(next) },
                        onDelivered: { setDelivered(next, true) },
                        onEditStockwerk: { stockwerkStop = next },
                        onEdit: { editingStop = next })
                        .listRowInsets(
                            EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                ForEach(visible) { stop in
                    row(for: stop, in: snapshot, floors: floors)
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
                        onImportFile: { pickingFile = true },
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
    private func row(
        for stop: Stop, in snapshot: RouteSnapshot, floors: [UUID: String]
    ) -> some View {
        StopListRow(
            stop: stop,
            sameDoorCount: snapshot.doorCount(stop),
            number: snapshot.number(stop),
            stockwerk: floors[stop.id],
            onTap: { tapped(stop) },
            onToggleDelivered: { setDelivered(stop, !stop.delivered) },
            onDelete: { deletingStop = stop },
            onNavigate: { open(stop) },
            onShowOnMap: { focus.showOnMap(stop: stop, of: route) },
            onEditStockwerk: { stockwerkStop = stop },
            onToggleExcluded: { Task { await toggleExcluded(stop) } })
            // The id is the scroll target `reveal` aims at.
            .id(stop.id)
            .listRowBackground(highlighted == stop.id ? Color.brandWashStrong : nil)
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
                // Two names for two things. These were "Tagesliste aus Datei"
                // and "Tagesliste einsetzen", which read as one feature worded
                // twice — and the driver has to pick between them at the moment
                // they are holding one or the other. What actually tells them
                // apart is the format, so that is what they are called.
                Button("Tabelle importieren", systemImage: "tablecells") {
                    pickingFile = true
                }
                Button("JSON einsetzen", systemImage: "curlybraces") {
                    showingJSON = true
                }
                Divider()
                Button("Neu optimieren", systemImage: "arrow.triangle.2.circlepath") {
                    startLongJob { await optimize() }
                }
                Button("Adressen prüfen", systemImage: "mappin.and.ellipse") {
                    startLongJob { await recheck() }
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
        // Folded on both sides, not just lowercased.
        //
        // This app already knows that a Viennese address survives being typed
        // without its umlauts — `AddressText.germanFold` is what makes the
        // register answer for "Waehringer Guertel", and what makes a re-pasted
        // list match the stops already on the route. The Stockwerke list
        // searches through it too. This one field did not, so a driver hunting
        // for "Grosse Neugasse" or "Doebling" on a phone keyboard they are
        // holding in one hand got an empty list for a stop that is sitting
        // right there — and a search that finds nothing reads as a tour that
        // has lost a customer.
        let tokens = AddressText.matchKey(search)
            .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return snapshot.ordered }
        return snapshot.ordered.filter { stop in
            guard stop.kind == .customer else { return false }
            // Paket and Notiz are in here as well as the address. They are
            // where the day's real detail lives — "2x Menü", a door code, "Hund
            // im Hof" — and a driver who remembers a note but not the name had
            // no way to find that stop again short of scrolling the whole tour.
            let haystack = AddressText.matchKey(
                [stop.kunde, stop.strasse, stop.plz, stop.paket, stop.notiz]
                    .compactMap { $0 }.joined(separator: " "))
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

    /// Ticking a delivery off — and, on the way past, the one moment worth
    /// asking which floor this was.
    ///
    /// Only on the tick going *on*, and only once the write has succeeded: a
    /// driver correcting a mis-tap is not standing in the stairwell, and a
    /// question on top of a failed save would bury the error it needs to
    /// report.
    private func setDelivered(_ stop: Stop, _ value: Bool) {
        var ok = false
        save("Konnte den Lieferstatus nicht speichern.") {
            try RouteStore.setDelivered(stop, value, in: context)
            ok = true
        }
        guard ok, value, StockwerkStore.shouldAsk(stop, in: context) else { return }
        stockwerkStop = stop
    }

    /// Starts one of the two long network jobs — optimizing, or re-checking
    /// addresses — and keeps a handle on it so the busy banner can offer a stop
    /// button. Returns `nil`, and starts nothing, when one is already running.
    ///
    /// The guard lives here rather than only inside the jobs themselves: a job
    /// that declined to start would otherwise still have replaced `busyTask`,
    /// and the banner's stop button would then cancel that finished no-op while
    /// the job actually running carried on behind it.
    @discardableResult
    private func startLongJob(_ work: @escaping () async -> Void) -> Task<Void, Never>? {
        // `busyTask` as well as `busy`: the job sets `busy` from inside its own
        // body, which does not run until this one suspends, so two taps close
        // together both saw `busy` still nil. The handle is assigned right
        // here, synchronously, and is what actually closes that window.
        guard !isBusy, busyTask == nil else { return nil }
        let task = Task {
            await work()
            // Cleared here rather than in each job's own `defer`. The guard
            // above refuses to start anything while this is non-nil, so a job
            // that forgot to clear it would not just leak a handle — it would
            // leave "Neu optimieren" and "Adressen prüfen" permanently dead for
            // the rest of the screen's life. Whoever sets it clears it.
            busyTask = nil
        }
        busyTask = task
        return task
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

    /// Whether a one-shot write may put its own sentence in the banner.
    ///
    /// The list stays tappable while a long job runs — deliberately, so a
    /// minute of address checking does not lock the driver out of their own
    /// tour — which means removing a stop or switching out a fixed point can
    /// land on top of one. Sharing `busy` unconditionally, both of those wrote
    /// their sentence over the running job's, and then their `defer` tore the
    /// banner down: the pill and its "Stoppen" button vanished while the job it
    /// belonged to carried on invisibly underneath. A long job owns the banner
    /// for as long as it runs; a one-shot write that arrives during one does
    /// its work quietly and leaves the report alone.
    private var ownsBanner: Bool { busyTask == nil }

    private func toggleExcluded(_ stop: Stop) async {
        let banner = ownsBanner
        if banner { busy = stop.excluded ? "Wird wieder eingeplant …" : "Wird ausgelassen …" }
        defer { if banner { busy = nil } }
        do { try await RouteStore.setExcluded(stop, !stop.excluded, in: context) } catch let e as AppError {
            self.error = e
        } catch {
            self.error = AppError.message("Konnte den Stopp nicht ändern.")
        }
    }

    private func delete(_ stop: Stop) async {
        let banner = ownsBanner
        if banner { busy = "Wird entfernt …" }
        defer { if banner { busy = nil } }
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
        } catch is CancellationError {
            // Stopped from the banner. The route keeps its `needsOptimize`
            // flag, so the amber "Route nicht aktuell" row is still there to
            // try again from — which says it better than an alert would.
            return
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
        // Stopped from the banner. Whatever it managed to improve is saved; a
        // summary counting the addresses it never got to would be reporting on
        // work the driver called off.
        if Task.isCancelled { return }
        // The store refused the corrections. Reported as the failure it is
        // rather than folded into the summary: every other line in that alert
        // is about an address, and this one is about the phone.
        guard r.stored else {
            self.error = AppError.message(
                "Die geprüften Adressen konnten nicht gespeichert werden. Die Stopps "
                    + "stehen unverändert auf der alten Position.")
            return
        }
        // A route with nothing approximate on it never had anything to check,
        // and "alle unverändert" claims a check that did not happen.
        if r.improved == 0 && r.unchanged == 0 && r.failed == 0 {
            recheckSummary = "Keine ungenauen Adressen — es gab nichts zu prüfen."
        } else if r.improved == 0 && r.failed == 0 {
            recheckSummary = "Alle Adressen sind unverändert."
        } else {
            var parts: [String] = []
            if r.improved > 0 { parts.append("\(r.improved) verbessert") }
            if r.unchanged > 0 { parts.append("\(r.unchanged) unverändert") }
            if r.failed > 0 { parts.append("\(r.failed) weiter offen") }
            recheckSummary = parts.joined(separator: ", ") + "."
        }
    }

    /// `sheet(item:)` needs an identity, and a bare array has none.
    private struct FileReview: Identifiable {
        let id = UUID()
        let entries: [CustomerJSON]
    }

    private var fileReviewBinding: Binding<FileReview?> {
        Binding(
            get: { fileReview.map { FileReview(entries: $0) } },
            set: { if $0 == nil { fileReview = nil } })
    }

    /// Reads the office's file and hands what it says to the review screen.
    ///
    /// Nothing is written and no address is looked up here: this is a decode,
    /// and the driver sees the result before any of it becomes a stop.
    private func readList(_ url: URL) {
        // A file from the document picker lives outside this app's sandbox and
        // the permission to read it has to be taken and given back explicitly —
        // without this the read fails on anything in iCloud Drive, which is
        // exactly where a file mailed to a phone ends up. The same dance
        // `BackupView` does.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            fileReview = try Tagesliste.parse(data, filename: url.lastPathComponent)
        } catch let failure as AppError {
            error = failure
        } catch {
            self.error = AppError.message(
                "Die Datei konnte nicht gelesen werden. \(error.localizedDescription)")
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
        // *before* this stop's own leg is added, so the drive out of that stop
        // still counts as ahead of them — they are standing at its door.
        var drivenKm = 0.0
        var drivenMinutes = 0.0

        for stop in ordered {
            if stop.kind == .customer {
                customers += 1
                numbers[stop.id] = customers
                if stop.delivered {
                    delivered += 1
                    // Only while every customer up to here has been delivered.
                    //
                    // Ticked off in order — the normal case, and the one every
                    // other test in `RouteSnapshotTests` describes — that is
                    // every delivered stop in turn, and this is exactly what it
                    // always was. What it now refuses to do is let a delivery
                    // made *out* of order drag the mark forward past doors that
                    // are still owed. A customer met on the street and handed
                    // their meal twenty stops early used to move it to their
                    // position, so the card paired "Noch 22 Stopps" with the
                    // four kilometres between stop 25 and the depot — a
                    // distance twenty-two doors cannot fit in, on the one line
                    // a driver plans the next hour from.
                    //
                    // What is left then covers the whole tour from the last
                    // point the plan was still being followed. That over-counts
                    // by however much of it the driver has already driven, and
                    // that is the deliberate direction: the real answer — "how
                    // far is it from where I am now, back to the doors I
                    // skipped, and on to the end" — is a re-routing problem
                    // this cannot solve from stored leg distances. Of the two
                    // ways to be wrong about it, telling a driver a tour is
                    // shorter than it is, at midday, with meals going cold, is
                    // the one that costs something.
                    if next == nil {
                        drivenKm = km
                        drivenMinutes = minutes
                    }
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

/// The line under the stop list: what the whole tour comes to.
///
/// It used to lead with what was still to drive. The next-stop card says that
/// now, at the top of the screen where a driver halfway through a shift is
/// already looking, so repeating it down here was the same sentence twice on
/// one screen. What is left is the planning number — the length of the tour as
/// a whole — plus the one case the card cannot cover, because the card is gone
/// by then: the last meal is handed over and the van still has to get home.
///
/// Hidden entirely while the list is filtered: the search shows a handful of
/// stops out of context, and a distance covering the ones it is not showing
/// would only be read as belonging to them.
struct RouteFooter: View {
    let snapshot: RouteSnapshot
    let searching: Bool

    var body: some View {
        if !searching, snapshot.totalKm > 0,
           let total = Format.leg(km: snapshot.totalKm, minutes: snapshot.totalMinutes) {
            VStack(alignment: .leading, spacing: 2) {
                if let home = wayHome {
                    Text(home)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.primary)
                }
                Text("Gesamt \(total)")
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Only once every meal is handed over. Until then the card above is
    /// carrying "how much is left", and this is the tour's total.
    private var wayHome: String? {
        guard snapshot.isComplete else { return nil }
        guard let distance = Format.leg(
            km: snapshot.remainingKm, minutes: snapshot.remainingMinutes)
        else { return "Alle Stopps geliefert" }
        return "Alle Stopps geliefert · Rückfahrt \(distance)"
    }
}

/// What the list shows a driver who has just created a tour: the two ways
/// stops get onto it, rather than three grey fixed rows and no next step.
struct EmptyStopsPrompt: View {
    let onAdd: () -> Void
    let onImportFile: () -> Void
    let onPaste: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Noch keine Kundenstopps")
                    .font(.headline)
                Text(
                    "Einzeln hinzufügen, oder die ganze Tagesliste auf einmal — als "
                        + "Excel-Tabelle vom Büro, oder als JSON-Liste.")
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

                Button(action: onImportFile) {
                    WideButtonLabel("Tabelle importieren", systemImage: "tablecells")
                }
                Button(action: onPaste) {
                    WideButtonLabel("JSON einsetzen", systemImage: "curlybraces")
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
    /// Offered by the two jobs that run on the network for a minute at a time.
    /// A one-off write has nothing to interrupt and gets no button.
    var onCancel: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // The label and the stop button sit side by side only while the two of
        // them fit on one line. "Adresse 4 von 10 wird geprüft …" plus
        // "Stoppen" is already wider than a phone at accessibility sizes, and
        // an `HStack` that does not fit does not wrap — it just grows, so the
        // pill ran off both edges of the screen with the stop button half cut
        // off the right of it.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onCancel {
                Button("Stoppen", action: onCancel)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brand)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
        // Outside the capsule: this is what stops the pill growing past the
        // screen. Without it nothing proposes a narrower width, so the text
        // never wraps and the shape simply overflows.
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
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
