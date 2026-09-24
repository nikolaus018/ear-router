import SwiftUI
import SwiftData

/// Every tour there has ever been, in one list — and, on launch, the one the
/// driver was last on, already open.
///
/// This used to be two tabs — "Routen" for the active ones and "Verlauf" for
/// the finished ones — which is two places to look for a thing that is only
/// ever in one of them, and a tab that is empty on the driver's first day and
/// most days after it. Finishing a tour is a change of state, not a change of
/// filing cabinet; iOS files by section, not by tab, everywhere it can (Mail's
/// mailboxes, Reminders' completed items, Files' recents), and so does this.
///
/// The restore is the other half. A driver opens this app to work a tour, not
/// to browse a list of one, so landing on the list every launch charged a tap
/// for nothing — and answering that with a separate "Heute" tab just built a
/// second door onto the same room. Reopening where you were costs no tab, no
/// screen, and leaves the Back button meaning what it says.
struct ToursTab: View {
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @Query(
        filter: #Predicate<Route> { $0.statusRaw == "active" },
        sort: \Route.createdAt, order: .reverse)
    private var active: [Route]

    @Query(
        filter: #Predicate<Route> { $0.statusRaw == "completed" },
        sort: \Route.completedAt, order: .reverse)
    private var completed: [Route]

    /// Unfiltered, and used only to resolve a pushed detail screen. Resolving
    /// through either query above would make the detail vanish the moment the
    /// route's status changes — which its own "Als erledigt markieren" menu
    /// item does deliberately.
    @Query private var allRoutes: [Route]

    @State private var creating = false
    @State private var newName = ""
    @State private var showingGourmetImport = false
    @State private var showingErayImport = false
    @State private var error: AppError?
    @State private var pendingDeletion = PendingRouteDeletion()
    /// Once per launch. Without the flag the restore would fire again every
    /// time the driver deliberately went Back to the list and then switched
    /// tabs, which would put them straight back where they had just left.
    @State private var didRestore = false

    var body: some View {
        Group {
            if active.isEmpty && completed.isEmpty {
                ContentUnavailableView {
                    Label("Keine Touren", systemImage: "shippingbox")
                } description: {
                    Text("Leg eine Tour an und füg die Kundenstopps hinzu.")
                } actions: {
                    Button("Neue Tour") { startCreate() }
                        .buttonStyle(.borderedProminent)
                    Button("Vom Zusteller-Portal") { showingGourmetImport = true }
                    Button("Eray-Liste einsetzen") { showingErayImport = true }
                }
            } else {
                List {
                    if !active.isEmpty {
                        Section("Aktiv") {
                            ForEach(active) { route in
                                NavigationLink(value: route.id) {
                                    TourRow(route: route)
                                }
                            }
                            .onDelete { pendingDeletion.stage($0, in: active) }
                        }
                    }
                    if !completed.isEmpty {
                        Section("Erledigt") {
                            ForEach(completed) { route in
                                NavigationLink(value: route.id) {
                                    TourRow(
                                        route: route,
                                        completedDate: route.completedAt ?? route.createdAt)
                                }
                            }
                            .onDelete { pendingDeletion.stage($0, in: completed) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Touren")
        // Reopens the tour the app was last on. Only an *active* one: a tour
        // that has been finished is something the driver went to look at, not
        // somewhere to be put back on a week later.
        .task {
            guard !didRestore else { return }
            didRestore = true
            guard focus.toursPath.isEmpty, let route = routeToReopen() else { return }
            focus.focus(route)
            focus.toursPath.append(route.id)
        }
        .navigationDestination(for: UUID.self) { id in
            if let route = allRoutes.first(where: { $0.id == id }) {
                TourView(route: route)
            } else {
                ContentUnavailableView("Tour nicht gefunden", systemImage: "questionmark.folder")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Neue Tour", systemImage: "plus") { startCreate() }
                    Button("Vom Zusteller-Portal", systemImage: "arrow.down.circle") {
                        showingGourmetImport = true
                    }
                    Button("Eray-Liste einsetzen", systemImage: "list.bullet.rectangle") {
                        showingErayImport = true
                    }
                } label: {
                    Label("Neue Tour", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingErayImport) {
            // Named after the document's own tour, and landing in it the same
            // way the portal import below does.
            ErayImportSheet(mode: .newRoute) { route in
                focus.focus(route)
                focus.toursPath.append(route.id)
            }
        }
        .sheet(isPresented: $showingGourmetImport) {
            GourmetImportSheet(mode: .newRoute) { route in
                // Straight into it, the same as a route just named by hand —
                // except this one already has its stops, ready to check over
                // rather than to start typing in.
                focus.focus(route)
                focus.toursPath.append(route.id)
            }
        }
        .alert("Neue Tour", isPresented: $creating) {
            // The date is the *placeholder*, not prefilled text. Prefilling
            // meant clearing it before you could type your own name; as a
            // placeholder it still applies when the field is left empty (see
            // `RouteStore.createRoute`) and gets out of the way when it is not.
            TextField(RouteStore.defaultRouteName(), text: $newName)
                .limited(to: FieldLimits.routeName, text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Anlegen") { create() }
        } message: {
            Text("Start, Lager und Ziel werden automatisch gesetzt.")
        }
        .errorAlert($error)
        .confirmRouteDeletion($pendingDeletion, in: context, error: $error)
    }

    /// The tour being worked, if it is still active, and otherwise the newest
    /// active one — the same tour Jetzt shows. The fallback matters on the day
    /// the driver finishes a tour and creates the next one on a different
    /// device — or simply the first time, when nothing has been remembered yet.
    private func routeToReopen() -> Route? {
        Route.current(among: active, working: focus.workingRouteID)
    }

    private func startCreate() {
        newName = ""
        creating = true
    }

    private func create() {
        do {
            let route = try RouteStore.createRoute(name: newName, in: context)
            // Straight into it. A tour you have just named is a tour with no
            // stops on it, and the next thing to do is put some there.
            focus.focus(route)
            focus.toursPath.append(route.id)
        } catch {
            self.error = AppError.message("Tour konnte nicht angelegt werden.")
        }
    }
}

/// One tour in the list — the same row whether it is active or finished, so a
/// tour looks like the same tour on either side of being done.
///
/// The two differ only in what the subtitle leads with: an active tour's
/// headline number is how much of it is left, a finished one's is the day it
/// was driven.
struct TourRow: View {
    let route: Route
    /// Shown instead of the delivery count once the tour is finished.
    var completedDate: Date?

    var body: some View {
        // Walked once, for all four numbers. Read as computed properties, the
        // subtitle alone counted the customers twice and summed the tour's legs
        // twice more, and then the accessibility label below asked for the
        // whole sentence a second time.
        let stats = Stats(route)
        let subtitle = subtitle(stats)

        return VStack(alignment: .leading, spacing: 3) {
            Text(route.name)
                .font(.body)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if route.needsOptimize {
                Label("Route nicht aktuell", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.monochrome)
                    .labelStyle(TintedIconLabelStyle(tint: .attention))
            }

            // Only while there is progress to show: at least one meal handed
            // over and at least one still to go. An empty trough under a tour
            // nobody has started promises something it cannot say, and a full
            // one under a finished tour says what the section header said.
            if completedDate == nil, stats.settled > 0, stats.settled < stats.customers {
                ProgressView(value: Double(stats.settled), total: Double(stats.customers))
                    .tint(.delivered)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            route.needsOptimize
                ? "\(route.name), \(subtitle), Route nicht aktuell"
                : "\(route.name), \(subtitle)")
    }

    private func subtitle(_ stats: Stats) -> String {
        var parts: [String] = []
        if let completedDate { parts.append(Format.date(completedDate)) }
        parts.append(Format.stops(stats.customers))
        // "0 geliefert" is not a progress report, it is the absence of one —
        // and it was on every tour the moment it was created.
        if completedDate == nil, stats.settled > 0 {
            parts.append(
                stats.delivered == stats.customers
                    ? "alle geliefert"
                    : "\(stats.delivered) von \(stats.customers) geliefert")
        }
        // Named on the row, not left to be discovered by opening the tour. It
        // is the one fact about a day that somebody still has to do something
        // about.
        if stats.notHome > 0 { parts.append("\(stats.notHome) nicht angetroffen") }
        if stats.km > 0, let formatted = Format.km(stats.km) { parts.append(formatted) }
        return parts.joined(separator: " · ")
    }

    /// Everything the row says about a tour, counted in one pass of its stops.
    private struct Stats {
        let customers: Int
        let delivered: Int
        /// Doors answered for — what the progress trough fills to. A customer
        /// nobody was home for is behind the driver, and a bar that refused to
        /// move for them sat at 29 of 30 for the rest of the afternoon.
        let settled: Int
        /// Only the doors nobody opened. Settled-but-not-delivered also takes
        /// in an abbestellt customer, who was never owed a meal and must not
        /// be named on the row as somebody nobody found at home.
        let notHome: Int
        let km: Double

        init(_ route: Route) {
            var customers = 0, delivered = 0, settled = 0, notHome = 0, km = 0.0
            for s in route.stops {
                if s.kind == .customer {
                    customers += 1
                    if s.delivered { delivered += 1 }
                    if s.isSettled { settled += 1 }
                    if s.outcome?.needsFollowUp == true { notHome += 1 }
                }
                if !s.excluded { km += s.nextLegKm ?? 0 }
            }
            self.customers = customers
            self.delivered = delivered
            self.settled = settled
            self.notHome = notHome
            self.km = km
        }
    }
}

/// A `Label` whose glyph carries a colour and whose text does not.
///
/// The app's one rule about colour in running text: it marks *which kind* of
/// thing a line is, and the words stay words. Written inline that is a `Label`
/// with an explicit `icon:` closure every time, which is four lines to say one
/// thing, so it is a style.
///
/// Laid out by hand rather than by handing the parts to a second `Label`. That
/// inner `Label` took whatever style the surroundings gave it, and inside a
/// `List` row that is the list's own: the glyph set in a wide icon column,
/// scaled up to a list icon, with a gutter after it. The same Notiz was then
/// "📝 1 Stunde vorher anrufen" on the card and "📝    1 Stunde / vorher
/// anrufen", broken over two lines, in the row directly above it. Baseline
/// aligned, so the glyph sits on the first line of a note that wraps and the
/// lines after it hang under the words rather than under the glyph.
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// A swipe-to-delete waiting on the driver to confirm it.
///
/// Two problems, one type. A tour carries a day of work — its stops, its notes
/// and, at midday, which of them have already had their meal — and deleting one
/// is not undoable anywhere in this app, while deleting a single *stop* already
/// asks first. And the deletion itself has to be staged by id: `onDelete` hands
/// over row offsets into a live `@Query`, and saving after the first delete can
/// refresh that array underneath the loop, so the second offset then names a
/// different tour, or none at all.
struct PendingRouteDeletion {
    private(set) var ids: [UUID] = []
    private(set) var title = ""
    private(set) var message = ""
    var isConfirming = false

    mutating func stage(_ offsets: IndexSet, in routes: [Route]) {
        let targets = offsets.compactMap { routes.indices.contains($0) ? routes[$0] : nil }
        guard !targets.isEmpty else { return }
        ids = targets.map(\.id)
        if let only = targets.first, targets.count == 1 {
            title = "Tour löschen?"
            message =
                "„\(only.name)“ wird mit \(Format.stops(only.customerCount)) "
                + "endgültig gelöscht."
        } else {
            title = "\(targets.count) Touren löschen?"
            message = "Die Touren werden mit allen ihren Stopps endgültig gelöscht."
        }
        isConfirming = true
    }
}

extension View {
    /// The confirmation itself. Bound to its own flag rather than to the
    /// presence of the staged deletion, so the title and the message survive
    /// the dismissal animation instead of blanking out halfway through it.
    func confirmRouteDeletion(
        _ pending: Binding<PendingRouteDeletion>, in context: ModelContext,
        error binding: Binding<AppError?>
    ) -> some View {
        confirmationDialog(
            pending.wrappedValue.title,
            isPresented: pending.isConfirming,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                do {
                    try RouteStore.delete(ids: pending.wrappedValue.ids, in: context)
                } catch {
                    // Swallowed, a failed delete looked exactly like a delete
                    // the driver had cancelled: the row simply stayed.
                    binding.wrappedValue = AppError.message(
                        "Die Tour konnte nicht gelöscht werden.")
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(pending.wrappedValue.message)
        }
    }
}
