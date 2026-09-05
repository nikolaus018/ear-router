import SwiftUI
import SwiftData

struct RoutesTab: View {
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @Query(
        filter: #Predicate<Route> { $0.statusRaw == "active" },
        sort: \Route.createdAt, order: .reverse)
    private var routes: [Route]

    /// Unfiltered, and used only to resolve a pushed detail screen.
    /// Resolving through the filtered query above would make the detail
    /// vanish the moment the route's status changes — which its own
    /// "Als erledigt markieren" menu item does deliberately.
    @Query private var allRoutes: [Route]

    @State private var creating = false
    @State private var newName = ""
    @State private var error: AppError?
    @State private var pendingDeletion = PendingRouteDeletion()

    var body: some View {
        Group {
            if routes.isEmpty {
                // Outside the `List`, not a row inside it — as a row it would
                // render inset between separators instead of filling the screen.
                ContentUnavailableView {
                    Label("Keine aktive Tour", systemImage: "shippingbox")
                } description: {
                    Text("Leg eine Tour an und füg die Kundenstopps hinzu.")
                } actions: {
                    Button { startCreate() } label: {
                        Text("Neue Tour").onBrandLabel()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(routes) { route in
                        NavigationLink(value: route.id) {
                            RouteSummaryRow(route: route)
                        }
                    }
                    .onDelete { pendingDeletion.stage($0, in: routes) }
                }
            }
        }
        .navigationTitle("Routen")
        .navigationDestination(for: UUID.self) { id in
            if let route = allRoutes.first(where: { $0.id == id }) {
                RouteDetailView(route: route)
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
            focus.focus(route)
            focus.routesPath.append(route.id)
        } catch {
            self.error = AppError.message("Tour konnte nicht angelegt werden.")
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

/// One route in a list — the same row in Routen and in Verlauf, so a tour looks
/// like the same tour on either side of being finished.
///
/// The two differ only in what the subtitle leads with: an active tour's
/// headline number is how much of it is done, a finished one's is the day it was
/// driven.
struct RouteSummaryRow: View {
    let route: Route
    /// Shown instead of the delivery count once the tour is in Verlauf.
    var completedDate: Date?

    var body: some View {
        // Walked once, for all four numbers. Read as computed properties, the
        // subtitle alone counted the customers twice and summed the tour's legs
        // twice more, and then the accessibility label below asked for the
        // whole sentence a second time.
        let stats = Stats(route)
        let subtitle = subtitle(stats)

        return VStack(alignment: .leading, spacing: 4) {
            Text(route.name)
                .font(.headline)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if route.needsOptimize {
                Label("Route nicht aktuell", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.warning)
            }

            // Only where there is progress to show. On a tour with no stops yet
            // the bar was an empty trough promising something the route cannot
            // deliver, and on a finished one it is always full and says nothing.
            if completedDate == nil && stats.customers > 0 {
                ProgressView(value: Double(stats.delivered), total: Double(stats.customers))
                    .tint(.success)
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
        if completedDate == nil && stats.customers > 0 {
            parts.append("\(stats.delivered) geliefert")
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

/// Presents an `AppError` as an alert, with the one-tap district correction
/// when the geocoder offered one.
extension View {
    func errorAlert(_ error: Binding<AppError?>, onFix: ((String) -> Void)? = nil) -> some View {
        alert(
            "Fehler",
            isPresented: Binding(
                get: { error.wrappedValue != nil },
                set: { if !$0 { error.wrappedValue = nil } })
        ) {
            if case .wrongDistrict(let plz) = error.wrappedValue?.recovery, let onFix {
                Button("Auf \(plz) ändern") {
                    onFix(plz)
                    error.wrappedValue = nil
                }
            }
            Button("OK", role: .cancel) { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue?.message ?? "")
        }
    }
}
