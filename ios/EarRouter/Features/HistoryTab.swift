import SwiftUI
import SwiftData

struct HistoryTab: View {
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @Query(
        filter: #Predicate<Route> { $0.statusRaw == "completed" },
        sort: \Route.completedAt, order: .reverse)
    private var routes: [Route]

    /// Unfiltered, and used only to resolve a pushed detail screen.
    /// Resolving through the filtered query above would make the detail
    /// vanish the moment the route's status changes — which its own
    /// "Als erledigt markieren" menu item does deliberately.
    @Query private var allRoutes: [Route]

    var body: some View {
        Group {
            if routes.isEmpty {
                ContentUnavailableView(
                    "Noch keine erledigten Touren", systemImage: "clock.arrow.circlepath",
                    description: Text("Eine Tour landet hier, sobald du sie als erledigt markierst."))
            } else {
                List {
                    ForEach(routes) { route in
                        NavigationLink(value: route.id) {
                            RouteSummaryRow(
                                route: route,
                                completedDate: route.completedAt ?? route.createdAt)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { try? RouteStore.delete(routes[i], in: context) }
                    }
                }
            }
        }
        .navigationTitle("Verlauf")
        .navigationDestination(for: UUID.self) { id in
            if let route = allRoutes.first(where: { $0.id == id }) {
                RouteDetailView(route: route)
            } else {
                ContentUnavailableView("Tour nicht gefunden", systemImage: "questionmark.folder")
            }
        }
    }
}
