import SwiftUI
import SwiftData

/// Every tour there has ever been, in one list.
///
/// This used to be two tabs — "Routen" for the active ones and "Verlauf" for
/// the finished ones — which is two places to look for a thing that is only
/// ever in one of them, and a tab that is empty on the driver's first day and
/// most days after it. Finishing a tour is a change of state, not a change of
/// filing cabinet; iOS files by section, not by tab, everywhere it can (Mail's
/// mailboxes, Reminders' completed items, Files' recents), and so does this.
///
/// The tab it freed up went to `TodayTab`, which is the screen the driver is
/// actually on all day.
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
    @State private var error: AppError?
    @State private var pendingDeletion = PendingRouteDeletion()

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
        .navigationDestination(for: UUID.self) { id in
            if let route = allRoutes.first(where: { $0.id == id }) {
                TourView(route: route)
            } else {
                ContentUnavailableView("Tour nicht gefunden", systemImage: "questionmark.folder")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Neue Tour", systemImage: "plus") { startCreate() }
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

    private func startCreate() {
        newName = ""
        creating = true
    }

    private func create() {
        do {
            let route = try RouteStore.createRoute(name: newName, in: context)
            // Focused, not pushed. A tour you have just created is the tour you
            // are about to drive, so it belongs on Heute — and pushing a detail
            // screen here as well would leave the driver two taps deep in a
            // stack they never asked for.
            focus.focus(route)
            focus.tab = .today
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
            if completedDate == nil, stats.delivered > 0, stats.delivered < stats.customers {
                ProgressView(value: Double(stats.delivered), total: Double(stats.customers))
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
        if completedDate == nil, stats.delivered > 0 {
            parts.append(
                stats.delivered == stats.customers
                    ? "alle geliefert"
                    : "\(stats.delivered) von \(stats.customers) geliefert")
        }
        if stats.km > 0, let formatted = Format.km(stats.km) { parts.append(formatted) }
        return parts.joined(separator: " · ")
    }

    /// Everything the row says about a tour, counted in one pass of its stops.
    private struct Stats {
        let customers: Int
        let delivered: Int
        let km: Double

        init(_ route: Route) {
            var customers = 0, delivered = 0, km = 0.0
            for s in route.stops {
                if s.kind == .customer {
                    customers += 1
                    if s.delivered { delivered += 1 }
                }
                if !s.excluded { km += s.nextLegKm ?? 0 }
            }
            self.customers = customers
            self.delivered = delivered
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
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(tint)
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
