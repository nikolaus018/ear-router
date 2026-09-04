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
                    Button("Neue Tour") { startCreate() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(routes) { route in
                        NavigationLink(value: route.id) {
                            RouteSummaryRow(route: route)
                        }
                    }
                    .onDelete(perform: delete)
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
            Button("Abbrechen", role: .cancel) {}
            Button("Anlegen") { create() }
        } message: {
            Text("Start, Lager und Ziel werden automatisch gesetzt.")
        }
        .errorAlert($error)
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

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            try? RouteStore.delete(routes[i], in: context)
        }
    }
}

struct RouteSummaryRow: View {
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.name)
                .font(.headline)

            HStack(spacing: 6) {
                Text(Format.stops(route.customerStops.count))
                if route.customerStops.count > 0 {
                    Text("·")
                    Text("\(route.deliveredCount) geliefert")
                }
                if let km = Format.km(route.totals.km), route.totals.km > 0 {
                    Text("·")
                    Text(km)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if route.needsOptimize {
                Label("Route nicht aktuell", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ProgressView(
                value: Double(route.deliveredCount),
                total: Double(max(route.customerStops.count, 1))
            )
            .tint(.success)
        }
        .padding(.vertical, 2)
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
