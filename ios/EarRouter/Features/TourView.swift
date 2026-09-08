import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// One tour: its stops in driving order, and everything you can do to them.
///
/// The screen is two things stacked, and the split is the whole idea.
///
/// **The list is the tour** — an uninterrupted sequence from the depot to the
/// finish flag, in the order it will be driven, with nothing wedged into the
/// middle of it. It used to have a card for the current stop sitting between
/// the fixed points and the customers, which meant the same customer appeared
/// twice on one screen four rows apart, at two different sizes.
///
/// **The bottom of the screen is what to do now.** It holds exactly one thing
/// at a time and it never scrolls away: the card for the stop the driver is on
/// while there are meals left, the button that finishes the tour once there are
/// not, and the progress banner over the top of either while a long job runs.
/// That is the Now Playing bar, the Maps route card, the call banner — the
/// pattern this phone has always used for "the thing you are doing, while you
/// look at something else".
///
/// One screen, one way in: pushed from Touren. On launch that push happens for
/// you, onto the tour the app was last on — which is what a short-lived "Heute"
/// tab was trying to buy, at the price of a second tab rendering this same
/// view.
struct TourView: View {
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
    /// Briefly tinted after arriving from a map pin, so the driver's eye lands
    /// on the row that was tapped rather than on the middle of a list.
    @State private var highlighted: UUID?
    /// The stop whose floor is being asked about — set by ticking a delivery
    /// off at a door nothing is known about yet, or from the row's own menu.
    @State private var stockwerkStop: Stop?
    /// How wide this screen is, so the card at the bottom of it can be given a
    /// real width. Measured rather than assumed: `safeAreaInset` proposes an
    /// unspecified width to its content, and everything inside the card then
    /// negotiates against nothing.
    @State private var screenSize: CGSize = .zero

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
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
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
        // The one slot on this screen for "what to do now", and it holds one
        // thing at a time. `safeAreaInset`, not an overlay: the list runs
        // underneath the floating tab bar, so anything pinned to the bottom of
        // its frame would be drawn behind it. An inset is placed *inside* the
        // safe area, above the bar, and takes up no room at all when there is
        // nothing to put in it.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { screenSize = geo.size }
                    .onChange(of: geo.size) { _, new in screenSize = new }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let busy {
                    BusyBanner(text: busy, onCancel: busyTask.map { task in { task.cancel() } })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomAction(snapshot, floors: floors)
            }
            .padding(.bottom, 8)
        }
        .animation(.snappy, value: busy)
        .navigationTitle(route.name)
        .navigationSubtitle(subtitle(snapshot))
        // Default placement, which on iOS 26 is a search button in the toolbar
        // that opens the field. Pinned into the title's drawer it was a bar
        // permanently parked under the tour's name — a control the driver uses
        // a handful of times a week, given a fixed slot on the screen they look
        // at all day.
        .searchable(text: $search, prompt: "Kunde, Adresse, Paket oder Notiz")
        // Awaited, so pull-to-refresh keeps its own spinner for exactly as long
        // as the optimization runs — but started the same way as the menu item,
        // so it is the same cancellable job with the same stop button.
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

    // MARK: - The list

    private func stops(
        _ snapshot: RouteSnapshot, visible: [Stop], floors: [UUID: String]
    ) -> some View {
        List {
            if route.needsOptimize {
                Section {
                    OptimizeBanner(busy: busy != nil) { startLongJob { await optimize() } }
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
        }
        // The moment the last meal is ticked off. Every individual tick already
        // gives its own impact; this is the one that says the tour is done, and
        // it is worth feeling through a coat pocket without looking.
        .sensoryFeedback(.success, trigger: snapshot.isComplete) { was, now in
            !was && now
        }
    }

    /// Extracted for the same reason `StopListRow` was: one more modifier
    /// inside the `ForEach` pushed the enclosing `List` past what the type
    /// checker will solve in reasonable time.
    private func row(
        for stop: Stop, in snapshot: RouteSnapshot, floors: [UUID: String]
    ) -> some View {
        StopListRow(
            stop: stop,
            sameDoorCount: snapshot.doorCount(stop),
            number: snapshot.number(stop),
            stockwerk: floors[stop.id],
            isNext: snapshot.nextOpen?.id == stop.id,
            onCard: cardStop(snapshot)?.id == stop.id,
            onTap: { tapped(stop) },
            onToggleDelivered: { setDelivered(stop, !stop.delivered) },
            onDelete: { deletingStop = stop },
            onNavigate: { open(stop) },
            onShowOnMap: { focus.showOnMap(stop: stop, of: route) },
            onEditStockwerk: { stockwerkStop = stop },
            onToggleExcluded: { Task { await toggleExcluded(stop) } })
            // The id is the scroll target `reveal` aims at.
            .id(stop.id)
            .listRowBackground(
                highlighted == stop.id ? Color.accentColor.opacity(0.12) : nil)
    }

    // MARK: - What to do now

    /// The stop the card is holding, or `nil` when there is no card.
    ///
    /// Asked in two places that must never disagree: the card itself, and the
    /// row for that same stop — which drops the errand from its own text
    /// precisely because the card is about to repeat it. Read from one function
    /// so a filtered list cannot end up with a stripped row and no card under
    /// it to hold what was stripped.
    private func cardStop(_ snapshot: RouteSnapshot) -> Stop? {
        guard search.isEmpty, route.status == .active else { return nil }
        return snapshot.nextOpen
    }

    /// The bottom slot: the stop being delivered, or the button that ends the
    /// tour, or nothing at all.
    ///
    /// Hidden while the list is filtered. A driver typing a name into the
    /// search field is looking something up, not standing at a door, and the
    /// card would cover a third of the results they came for.
    @ViewBuilder
    private func bottomAction(_ snapshot: RouteSnapshot, floors: [UUID: String]) -> some View {
        if let next = cardStop(snapshot) {
            NowCard(
                stop: next,
                number: snapshot.number(next),
                stockwerk: floors[next.id],
                sameDoorCount: snapshot.doorCount(next),
                onNavigate: { open(next) },
                onDelivered: { setDelivered(next, true) },
                onOpen: { editingStop = next },
                width: max(0, screenSize.width - NowCard.screenInset * 2))
        } else if !search.isEmpty || route.status != .active {
            // Nothing at all on a finished tour. The slot is "what to do now",
            // and a tour in the archive is not something to do — it showed a
            // live "Navigation / Geliefert" card for a day's work already done,
            // over a list already struck through, because it was gated on there
            // being an undelivered stop rather than on the tour being open.
            EmptyView()
        } else if snapshot.isComplete && route.status == .active {
            // Finishing the tour is deliberately still the driver's call (see
            // `RouteStore.setDelivered`), but the moment it becomes the only
            // thing left to do it should not be buried in an overflow menu —
            // and this slot has just been vacated by the last stop.
            Button {
                save("Die Tour konnte nicht abgeschlossen werden.") {
                    try RouteStore.toggleStatus(route, in: context)
                }
            } label: {
                WideButtonLabel("Tour abschließen", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
        }
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
                Label("Mehr", systemImage: "ellipsis")
            }
            .disabled(busy != nil)
        }
    }

    // MARK: - Text

    /// The line under the tour's name: what is still ahead of the driver.
    ///
    /// "Noch 22 Stopps · 18,2 km" rather than "12 von 34 geliefert" — both are
    /// the same fact, but only one of them is the question anybody has at half
    /// past eleven. The list's own section header still counts the deliveries,
    /// for the times the other framing is the one wanted.
    private func subtitle(_ snapshot: RouteSnapshot) -> String {
        guard snapshot.customerCount > 0 else { return "Noch keine Stopps" }
        // A finished tour is history, and history has no "still to drive". It
        // was answering "Noch 4 Stopps · 11,7 km" under a tour filed in
        // Erledigt — a forecast about a day that is over, and one that goes on
        // being wrong for as long as the tour is kept.
        guard route.status == .active else {
            let day = route.completedAt ?? route.createdAt
            let parts = [Format.date(day), Format.stops(snapshot.customerCount),
                         Format.km(snapshot.totalKm)].compactMap { $0 }
            return parts.joined(separator: " · ")
        }
        guard snapshot.openCount > 0 else {
            guard let back = Format.km(snapshot.remainingKm), snapshot.remainingKm >= 0.05
            else { return "Alle geliefert" }
            return "Alle geliefert · Rückfahrt \(back)"
        }
        let stops = "Noch \(Format.stops(snapshot.openCount))"
        guard let km = Format.km(snapshot.remainingKm), snapshot.remainingKm >= 0.05
        else { return stops }
        return "\(stops) · \(km)"
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
        // list match the stops already on the route. This one field did not, so
        // a driver hunting for "Grosse Neugasse" or "Doebling" on a phone
        // keyboard they are holding in one hand got an empty list for a stop
        // sitting right there — and a search that finds nothing reads as a tour
        // that has lost a customer.
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
    private func save(_ failure: String, _ write: () throws -> Void) {
        do { try write() } catch { self.error = AppError.message(failure) }
    }

    /// True when this screen already has something in flight.
    ///
    /// Guards the two long-running, repeatable jobs against being started on
    /// top of each other. The toolbar disables itself while `busy` is set, but
    /// pull-to-refresh cannot be disabled, so a driver could pull the list to
    /// optimize during a minute-long address re-check. Neither corrupts
    /// anything (the optimizer serializes per route), but the two share one
    /// banner, and whichever finished first cleared it and left the other
    /// running invisibly.
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
        // exactly where a file mailed to a phone ends up.
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
                }
                .buttonStyle(.borderedProminent)

                // Both secondary paths bordered, and the style set on the stack
                // rather than on the last button in it — written per-button it
                // landed on "JSON einsetzen" alone, so the two ways of doing
                // the same thing came out wearing different buttons.
                VStack(spacing: 8) {
                    Button(action: onImportFile) {
                        WideButtonLabel("Tabelle importieren", systemImage: "tablecells")
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
        .glassEffect(.regular, in: .capsule)
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
    let retry: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(Color.attention)
                .symbolRenderingMode(.monochrome)
            VStack(alignment: .leading, spacing: 2) {
                Text("Route nicht aktuell").font(.subheadline.weight(.semibold))
                Text("Reihenfolge und Distanzen stimmen nicht mehr.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Optimieren") { Task { await retry() } }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(busy ? Color.secondary : Color.accentColor)
                .disabled(busy)
        }
        .padding(.vertical, 2)
    }
}
