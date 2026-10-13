import SwiftUI
import SwiftData

/// One tour: its stops in driving order, and everything you can do to them.
///
/// **The list is the tour** — an uninterrupted sequence from the depot to the
/// finish flag, in the order it will be driven, with nothing wedged into it and
/// nothing floating over it. The stop the driver is on is the one row with a
/// solid badge; the stop itself, set large with its two buttons, is the Jetzt
/// tab's. It used to be a card here — first wedged between the fixed points and
/// the customers, then pinned over the bottom of the list — and in both places
/// it showed one customer twice on one screen and hid part of the list it was
/// about.
///
/// The bottom of the screen holds only what is transient: the progress banner
/// while a long job runs, and the button that files the tour once every meal is
/// handed over.
///
/// Pushed from Touren. On launch that push happens for you, onto the tour the
/// app was last on.
struct TourView: View {
    @Bindable var route: Route
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus
    @Environment(\.openURL) private var openURL

    @State private var search = ""
    @State private var editingStop: Stop?
    @State private var addingStop = false
    @State private var showingJSON = false
    @State private var showingGourmetImport = false
    @State private var showingErayImport = false
    @State private var showingLadeliste = false
    @State private var showingPDF = false
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
    /// Briefly tinted after arriving from a map pin, so the driver's eye lands
    /// on the row that was tapped rather than on the middle of a list.
    @State private var highlighted: UUID?
    /// The pending fade of that highlight. Cancelled when a second reveal
    /// arrives inside the first one's 1.6 seconds, so the older timer cannot
    /// clear the row the driver has just been sent to.
    @State private var highlightTask: Task<Void, Never>?
    /// "Lieferstatus zurücksetzen", waiting to be confirmed — see the menu.
    @State private var confirmingReset = false
    /// The stop whose floor is being asked about — set by ticking a delivery
    /// off at a door nothing is known about yet, or from the row's own menu.
    @State private var stockwerkStop: Stop?
    /// The end-of-day report, and the checklist before setting off. Two screens
    /// about the same tour at its two ends.
    @State private var showingReport = false
    @State private var showingPreflight = false
    /// "Reihenfolge ändern" — see `ReorderSheet`.
    @State private var reordering = false
    /// "Neu optimieren" on a hand-sorted tour, waiting to be confirmed.
    @State private var confirmingReoptimize = false

    /// Every door ever answered for. Queried whole rather than per row: this is
    /// a few thousand short rows after years of tours, one pass turns it into
    /// the lookup below, and a `@Query` is what makes a floor typed into the
    /// sheet appear on the row behind it without anything having to reload.
    @Query private var stockwerkNotes: [StockwerkNote]

    var body: some View {
        ScrollViewReader { proxy in
            screen
                .onChange(of: focus.revealStopID, initial: true) { _, id in
                    guard let id else { return }
                    // Cleared immediately so this fires once, not on every
                    // redraw of the list.
                    focus.revealStopID = nil
                    search = ""
                    highlighted = id
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    highlightTask?.cancel()
                    highlightTask = Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        guard !Task.isCancelled else { return }
                        withAnimation { highlighted = nil }
                    }
                }
        }
    }

    private var screen: some View {
        // Everything the list needs about the route, derived exactly once.
        //
        // Read as computed properties — which is what these were — each of them
        // re-sorted the route's stops, and the door grouping re-ran a whole
        // union-find over it, *per row*, because the `ForEach` body asked for
        // them again for every stop it built. On a full tour that is a hundred
        // sorts and a hundred union-finds for one pass of the list, repeated on
        // every tick of a delivery. Derived here, it is one of each.
        let snapshot = RouteSnapshot(route)
        let visible = visibleStops(in: snapshot)
        let info = stockwerkNotes.info(for: snapshot.ordered)

        return Group {
            if visible.isEmpty && !search.isEmpty {
                // Outside the `List`, not an empty section inside it: as a row
                // it rendered inset under a header counting the nothing it had
                // found.
                ContentUnavailableView.search(text: search)
            } else {
                stops(snapshot, visible: visible, info: info)
            }
        }
        // Floated rather than given room of its own — see `floatingBanner`.
        // Applied before the finish button's inset, so it hangs above it.
        .floatingBanner {
            if let busy {
                BusyBanner(text: busy, onCancel: busyTask.map { task in { task.cancel() } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // `safeAreaInset`, not an overlay: the list runs underneath the
        // floating tab bar, so anything pinned to the bottom of its frame would
        // be drawn behind it. An inset is placed *inside* the safe area, above
        // the bar. The button appears once, when the tour is done, and stays.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            finishButton(snapshot)
        }
        .animation(.snappy, value: busy)
        .navigationTitle(route.name)
        .navigationSubtitle(snapshot.summary(of: route))
        // Default placement: tucked above the list, revealed by pulling it down,
        // as in Mail or Settings — a control the driver uses a handful of times
        // a week, not given a fixed slot on the screen they look at all day.
        // Pulling down used to re-optimize the tour as well, which is why this
        // field was as good as unreachable.
        .searchable(text: $search, prompt: "Kunde, Adresse, Paket oder Notiz")
        // No pull-to-refresh. It re-optimized the tour, and pulling down is the
        // same move a thumb makes to get back to the top of a long list — so a
        // driver scrolling up mid-tour could reorder the doors still ahead
        // without meaning to. The amber row and "Neu optimieren" say what they do.
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
        .sheet(isPresented: $showingReport) {
            TourReportSheet(route: route)
        }
        .sheet(isPresented: $showingPreflight) {
            PreflightSheet(
                route: route,
                onOptimize: { startLongJob { await optimize() } },
                onRecheck: { startLongJob { await recheck() } },
                onResetDelivered: {
                    save("Der Lieferstatus konnte nicht zurückgesetzt werden.") {
                        try RouteStore.resetDelivered(route, in: context)
                    }
                },
                onLadeliste: { showingLadeliste = true })
        }
        .sheet(isPresented: $showingJSON) {
            JSONEditorSheet(route: route)
        }
        .sheet(isPresented: $showingGourmetImport) {
            GourmetImportSheet(mode: .existing(route))
        }
        .sheet(isPresented: $showingErayImport) {
            ErayImportSheet(mode: .existing(route))
        }
        .sheet(isPresented: $showingLadeliste) {
            LadelisteView(route: route)
        }
        .sheet(isPresented: $showingPDF) {
            TourPDFSheet(route: route)
        }
        .sheet(isPresented: $reordering) {
            ReorderSheet(route: route)
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
        .confirmationDialog(
            "Neu optimieren?", isPresented: $confirmingReoptimize,
            titleVisibility: .visible
        ) {
            Button("Neu optimieren") { startLongJob { await optimize(afresh: true) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Deine eigene Reihenfolge wird durch die optimierte ersetzt.")
        }
        .confirmationDialog(
            "Lieferstatus zurücksetzen?", isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Zurücksetzen", role: .destructive) {
                save("Der Lieferstatus konnte nicht zurückgesetzt werden.") {
                    try RouteStore.resetDelivered(route, in: context)
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(RouteStore.resetDeliveredMessage(for: route))
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
        // "Wieder aktivieren" on the tour on screen makes it a tour that can be
        // worked again, and this is the screen it was reactivated on.
        .onChange(of: route.status) { focus.focus(route) }
    }

    // MARK: - The list

    private func stops(
        _ snapshot: RouteSnapshot, visible: [Stop], info: [UUID: StockwerkNote]
    ) -> some View {
        List {
            if route.needsOptimize {
                Section {
                    OptimizeBanner(busy: busy != nil, handOrdered: route.handOrdered) {
                        startLongJob { await optimize() }
                    }
                }
            }

            Section {
                ForEach(visible) { stop in
                    row(for: stop, in: snapshot, info: info)
                }
            } header: {
                Text(Format.strip(listHeader(snapshot, visible: visible)))
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
                        onPortal: { showingGourmetImport = true },
                        onEray: { showingErayImport = true },
                        onPaste: { showingJSON = true })
                }
            }
        }
        // The moment the last meal is ticked off. Every individual tick already
        // gives its own impact; this is the one that says the tour is done, and
        // it is worth feeling through a coat pocket without looking.
        //
        // Only while this is the screen in use: Jetzt gives its own for the
        // same last tick, and this view stays alive behind it in Touren.
        .sensoryFeedback(.success, trigger: snapshot.isComplete) { was, now in
            !was && now && focus.tab == .tours
        }
    }

    /// Extracted for the same reason `StopListRow` was: one more modifier
    /// inside the `ForEach` pushed the enclosing `List` past what the type
    /// checker will solve in reasonable time.
    private func row(
        for stop: Stop, in snapshot: RouteSnapshot, info: [UUID: StockwerkNote]
    ) -> some View {
        StopListRow(
            stop: stop,
            sameDoorCount: snapshot.doorCount(stop),
            number: snapshot.number(stop),
            info: info[stop.id],
            eta: snapshot.eta(for: stop),
            isNext: snapshot.nextOpen?.id == stop.id,
            onTap: { tapped(stop) },
            onToggleDelivered: { setDelivered(stop, !stop.isSettled) },
            onDelete: { deletingStop = stop },
            onNavigate: { open(stop) },
            onShowOnMap: { focus.showOnMap(stop: stop, of: route) },
            onEditStockwerk: { stockwerkStop = stop },
            onRecord: { record($0, for: stop) },
            onToggleExcluded: { Task { await toggleExcluded(stop) } })
            // The id is the scroll target `reveal` aims at.
            .id(stop.id)
            .listRowBackground(rowBackground(for: stop))
    }

    /// Highlighted takes priority — it only ever lands on the row `reveal`
    /// just scrolled to, and losing that flash under a permanent tint would
    /// defeat the point of it. Otherwise a stop whose address the geocoder
    /// only narrowed to a street or a district, never a door, gets a soft
    /// amber wash: the list is where a driver decides what to trust before
    /// setting off, and a precise-looking row for an address nobody actually
    /// pinned is the wrong moment to find that out.
    ///
    /// Amber, not the red this was. Red is the colour of deleting in this app
    /// and nothing else (see `Theme`), and the same approximate pin is amber
    /// on the map, on the row's own ≈ mark and in the editor.
    private func rowBackground(for stop: Stop) -> Color? {
        if highlighted == stop.id { return Color.accentColor.opacity(0.12) }
        if let precision = stop.precision, precision != .exact {
            return Color.attention.opacity(0.12)
        }
        return nil
    }

    // MARK: - Finishing

    /// The button that files the tour, once every meal is handed over.
    ///
    /// Finishing is deliberately the driver's call (see
    /// `RouteStore.setDelivered`), but the moment it becomes the only thing left
    /// to do it should not be buried in an overflow menu. Not on a tour already
    /// filed, and not while the list is filtered, where it would cover the
    /// results the driver is looking for.
    @ViewBuilder
    private func finishButton(_ snapshot: RouteSnapshot) -> some View {
        if search.isEmpty, route.status == .active, snapshot.isComplete {
            Button(action: finish) {
                WideButtonLabel("Tour abschließen", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    /// Filed *and* reported, in one press. The report is the whole reason
    /// anybody asked for outcomes and timestamps, and a screen the driver has
    /// to remember to go and find is one that gets found on the third day and
    /// never again.
    private func finish() {
        save("Die Tour konnte nicht abgeschlossen werden.") {
            try RouteStore.toggleStatus(route, in: context)
            PaceHistory.refresh(in: context)
        }
        if error == nil { showingReport = true }
    }

    // MARK: - Toolbar

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
                // The two ends of a shift, at the top of the menu, because
                // they are the two things a driver opens deliberately rather
                // than stumbles into.
                Button("Tour vorbereiten", systemImage: "checklist.checked") {
                    showingPreflight = true
                }
                Button("Tagesabschluss", systemImage: "doc.text") { showingReport = true }
                Divider()
                // `shippingbox`, not a second checklist: "Tour vorbereiten"
                // two rows above already wears one, and the pair sat in the
                // same menu as two near-identical glyphs. What this list is
                // about is what goes in the van, which is the box.
                Button("Ladeliste", systemImage: "shippingbox") { showingLadeliste = true }
                Button("Als PDF exportieren", systemImage: "printer") { showingPDF = true }
                    .disabled(route.customerCount == 0)
                // One entry for the three ways a day's list arrives. Side by
                // side they made this menu thirteen rows long, and the last
                // two — the reset and filing the tour — scrolled out of it.
                Menu("Stopps laden", systemImage: "arrow.down.circle") {
                    Button("Vom Zusteller-Portal", systemImage: "arrow.down.circle") {
                        showingGourmetImport = true
                    }
                    Button("Eray-Liste einsetzen", systemImage: "list.bullet.rectangle") {
                        showingErayImport = true
                    }
                    Button("JSON einsetzen", systemImage: "curlybraces") {
                        showingJSON = true
                    }
                }
                Divider()
                Button("Neu optimieren", systemImage: "arrow.triangle.2.circlepath") {
                    if route.handOrdered {
                        confirmingReoptimize = true
                    } else {
                        startLongJob { await optimize(afresh: true) }
                    }
                }
                Button("Reihenfolge ändern", systemImage: "arrow.up.arrow.down") {
                    reordering = true
                }
                .disabled(route.customerCount < 2)
                Button("Adressen prüfen", systemImage: "mappin.and.ellipse") {
                    startLongJob { await recheck() }
                }
                Divider()
                Button("Umbenennen", systemImage: "pencil") {
                    newName = route.name
                    renaming = true
                }
                // Asks first. It is one tap in a menu and it clears every tick
                // of the day at once — the doors a driver has already handed a
                // meal over at by midday are not something to lose to a thumb
                // that was aiming for "Umbenennen". Deleting one stop asks;
                // this took all of them back without a word.
                //
                // Red in the menu, the way iOS marks the one entry that takes
                // something away — it was drawn exactly like "Umbenennen".
                Button(
                    "Lieferstatus zurücksetzen", systemImage: "arrow.counterclockwise",
                    role: .destructive
                ) {
                    confirmingReset = true
                }
                .disabled(route.settledCount == 0)
                // The same words and the same result as the button at the
                // bottom of a finished list: filed, and the report up. As
                // "Als erledigt markieren" it filed the tour without one.
                if route.status == .active {
                    Button("Tour abschließen", systemImage: "checkmark.seal") { finish() }
                } else {
                    Button("Wieder aktivieren", systemImage: "arrow.uturn.backward") {
                        save("Der Status der Tour konnte nicht geändert werden.") {
                            try RouteStore.toggleStatus(route, in: context)
                            PaceHistory.refresh(in: context)
                        }
                    }
                }
            } label: {
                Label("Mehr", systemImage: "ellipsis")
            }
            .disabled(busy != nil)
        }
    }

    // MARK: - Text

    private func listHeader(_ snapshot: RouteSnapshot, visible: [Stop]) -> String {
        if !search.isEmpty {
            return "\(visible.count) von \(snapshot.customerCount) Stopps"
        }
        // "0 von 0 geliefert" over a route that has only its three fixed points
        // is a progress report on nothing.
        if snapshot.customerCount == 0 { return "Fixpunkte" }
        return snapshot.deliveryLine
    }

    private var recheckAlert: Binding<Bool> {
        Binding(
            get: { recheckSummary != nil },
            set: { if !$0 { recheckSummary = nil } })
    }

    private func visibleStops(in snapshot: RouteSnapshot) -> [Stop] {
        guard !search.isEmpty else { return snapshot.ordered }
        // Folded on both sides, not just lowercased — see `AddressText.Search`,
        // which is where that rule and the word-by-word matching now live, so
        // this list, the portal's and the saved floors' all answer a typed
        // query the same way.
        //
        // This app already knows that a Viennese address survives being typed
        // without its umlauts — `AddressText.germanFold` is what makes the
        // register answer for "Waehringer Guertel", and what makes a re-pasted
        // list match the stops already on the route. This one field did not, so
        // a driver hunting for "Grosse Neugasse" or "Doebling" on a phone
        // keyboard they are holding in one hand got an empty list for a stop
        // sitting right there — and a search that finds nothing reads as a tour
        // that has lost a customer.
        let query = AddressText.Search(search)
        guard !query.isEmpty else { return snapshot.ordered }
        return snapshot.ordered.filter { stop in
            guard stop.kind == .customer else { return false }
            // Paket and Notiz are in here as well as the address. They are
            // where the day's real detail lives — "2x Menü", a door code, "Hund
            // im Hof" — and a driver who remembers a note but not the name had
            // no way to find that stop again short of scrolling the whole tour.
            return query.matches(
                AddressText.matchKey(
                    [stop.kunde, stop.strasse, stop.plz, stop.paket, stop.notiz]
                        .compactMap { $0 }.joined(separator: " ")))
        }
    }

    // MARK: - Actions

    /// Tapping a customer, Start or Ziel opens the editor. The Lager has
    /// nothing to edit, so a tap on it does nothing — switching it back into
    /// the tour is the ↺ on its row or the context menu, never a stray tap on
    /// a greyed-out line that re-plans the whole tour.
    private func tapped(_ stop: Stop) {
        guard stop.kind != .via else { return }
        editingStop = stop
    }

    /// Ticking a delivery off — and, on the way past, the one moment worth
    /// asking which floor this was.
    ///
    /// Only on the tick going *on*, and only once the write has succeeded: a
    /// driver correcting a mis-tap is not standing in the stairwell, and a
    /// question on top of a failed save would bury the error it needs to
    /// report.
    private func setDelivered(_ stop: Stop, _ value: Bool) {
        record(value ? .delivered : nil, for: stop)
    }

    /// Records what happened at a door, and asks about the floor on the way
    /// past when the meal actually got there.
    ///
    /// Not after a locked door: the driver is walking back to the van, not
    /// standing in the stairwell, and the whole argument for asking at that
    /// moment is that they are looking at the answer. Asking anyway would train
    /// them to dismiss the one question this app relies on being answered
    /// honestly.
    private func record(_ outcome: DeliveryOutcome?, for stop: Stop) {
        var ok = false
        save("Konnte den Lieferstatus nicht speichern.") {
            try RouteStore.record(outcome, for: stop, in: context)
            ok = true
        }
        guard ok, outcome?.handedOver == true,
              StockwerkStore.shouldAsk(stop, in: context)
        else { return }
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
    private func save(_ failure: String, _ write: () throws -> Void) {
        do { try write() } catch { self.error = AppError.message(failure) }
    }

    /// True when this screen already has something in flight.
    ///
    /// Guards the two long-running, repeatable jobs against being started on
    /// top of each other. The toolbar disables itself while `busy` is set, but
    /// the amber row and Tour vorbereiten can still start one. Neither
    /// corrupts anything (the optimizer serializes per route), but the two
    /// share one banner, and whichever finished first cleared it and left the
    /// other running invisibly.
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
    /// belonged to carried on invisibly underneath.
    private var ownsBanner: Bool { busyTask == nil }

    private func toggleExcluded(_ stop: Stop) async {
        let banner = ownsBanner
        if banner { busy = stop.excluded ? "Wird wieder eingeplant …" : "Wird ausgelassen …" }
        defer { if banner { busy = nil } }
        do {
            try await RouteStore.setExcluded(stop, !stop.excluded, in: context)
        } catch let e as AppError {
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

    /// `afresh` is "Neu optimieren" from the menu: a new order, even on a
    /// tour sorted by hand. Everything else — the banner, Tour vorbereiten —
    /// brings the route up to date and keeps a hand-sorted order as it is.
    private func optimize(afresh: Bool = false) async {
        guard !isBusy else { return }
        let keepOrder = route.handOrdered && !afresh
        busy = keepOrder ? "Route wird aktualisiert …" : "Route wird optimiert …"
        defer { busy = nil }
        do {
            try await RouteOptimizer.optimize(route, in: context, keepOrder: keepOrder)
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

    private func open(_ stop: Stop) {
        guard let url = NavigationHandoff.url(for: stop) else { return }
        TourDeparture.noteNavigation(to: stop)
        openURL(url)
    }
}

/// The line under the stop list: how long the tour is as a whole.
///
/// One number, and it is the planning one. What is still to drive — and the
/// drive home once the last meal is handed over — is the screen's subtitle,
/// under the tour's own name, where it is legible whether or not the driver has
/// scrolled this far.
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
            Text("Gesamt \(total)")
        }
    }
}

/// What the list shows a driver who has just created a tour: the ways stops get
/// onto it, rather than three grey fixed rows and no next step.
struct EmptyStopsPrompt: View {
    let onAdd: () -> Void
    /// The day's tour straight from the Zusteller-Portal — the way a whole
    /// list most often arrives, and the one path the tour's menu had and this
    /// prompt, the screen a new tour opens on, did not.
    let onPortal: () -> Void
    /// A whole tour out of Eray's planner, of which this takes the
    /// customers — see `ErayImport`.
    let onEray: () -> Void
    let onPaste: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Noch keine Kundenstopps")
                    .font(.headline)
                Text(
                    "Einzeln hinzufügen, oder die ganze Tagesliste auf einmal — vom "
                        + "Zusteller-Portal, als Eray-Liste oder als JSON-Liste.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                Button(action: onAdd) {
                    WideButtonLabel("Stopp hinzufügen", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                VStack(spacing: 8) {
                    Button(action: onPortal) {
                        WideButtonLabel("Vom Zusteller-Portal", systemImage: "arrow.down.circle")
                    }
                    Button(action: onEray) {
                        WideButtonLabel("Eray-Liste einsetzen", systemImage: "list.bullet.rectangle")
                    }
                    Button(action: onPaste) {
                        WideButtonLabel("JSON einsetzen", systemImage: "curlybraces")
                    }
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

/// The "something is happening" pill, above whatever else is in the bottom
/// slot. A capsule floating over the list rather than a scrim across it: the
/// driver can still read and scroll the stops while an optimization runs, which
/// is a slow network call they have no reason to be locked out of.
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
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // Glass tinted towards the background. Clear glass let the list show
        // through at full contrast, and in Prüfen "Adresse 8 von 8 wird
        // gesucht …" sat on top of a stop's own address, the two lines of text
        // tangled together. The tint keeps the glass and gives the words a
        // ground of their own.
        .glassEffect(
            .regular.tint(Color(.systemBackground).opacity(0.7)), in: .capsule)
        // Outside the capsule: this is what stops the pill growing past the
        // screen. Without it nothing proposes a narrower width, so the text
        // never wraps and the shape simply overflows.
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// "The order you are looking at is not the order to drive."
///
/// An ordinary list row rather than the filled-button banner it was. The amber
/// glyph is what makes it findable; the action is a plain tinted verb on the
/// right, which is what every actionable row on this phone looks like.
struct OptimizeBanner: View {
    let busy: Bool
    /// A hand-sorted tour keeps its order, so only the line and the
    /// distances are out of date — and the button does not reorder anything.
    var handOrdered = false
    let retry: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(Color.attention)
                .symbolRenderingMode(.monochrome)
            VStack(alignment: .leading, spacing: 2) {
                Text("Route nicht aktuell").font(.subheadline.weight(.semibold))
                Text(handOrdered
                     ? "Linie und Distanzen stimmen nicht mehr."
                     : "Reihenfolge und Distanzen stimmen nicht mehr.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(handOrdered ? "Aktualisieren" : "Optimieren") { Task { await retry() } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(busy ? Color.secondary : Color.accentColor)
                .disabled(busy)
        }
        .padding(.vertical, 2)
    }
}
