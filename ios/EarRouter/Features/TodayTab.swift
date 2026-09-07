import SwiftUI
import SwiftData

/// The tour being driven, with nothing between the driver and it.
///
/// This tab did not exist. The app opened on a *list of tours* — a document
/// browser, one row long on almost every day of its life — and the screen the
/// driver spends the whole shift on was one tap behind it. That is the right
/// shape for an app that manages many documents and the wrong one for an app
/// with a single subject: Fitness opens on today's rings rather than on a list
/// of days, Maps opens on the map.
///
/// So the front door is now the tour itself. `TourView` renders it, exactly as
/// it renders any tour picked out of Touren; what this adds is the rule for
/// *which* tour that is, and something to do on the one day there isn't one.
struct TodayTab: View {
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @Query(
        filter: #Predicate<Route> { $0.statusRaw == "active" },
        sort: \Route.createdAt, order: .reverse)
    private var active: [Route]

    @State private var creating = false
    @State private var newName = ""
    @State private var error: AppError?

    /// The tour in focus if it is still active, and otherwise the newest one.
    ///
    /// The fallback is what keeps this screen stable: opening a *finished* tour
    /// from Touren focuses it, so without it Heute would empty itself out
    /// behind the driver's back while they were looking at last Tuesday.
    private var route: Route? {
        active.first { $0.id == focus.currentRouteID } ?? active.first
    }

    var body: some View {
        Group {
            if let route {
                TourView(route: route)
            } else {
                ContentUnavailableView {
                    Label("Keine aktive Tour", systemImage: "shippingbox")
                } description: {
                    Text("Leg die Tour für heute an und füg die Kundenstopps hinzu.")
                } actions: {
                    Button("Neue Tour") {
                        newName = ""
                        creating = true
                    }
                    .buttonStyle(.borderedProminent)

                    // The way back to a finished tour, on the one screen that
                    // otherwise has no way anywhere. Without it a driver whose
                    // tours are all done is looking at an empty state with a
                    // single button on it, and the whole archive is behind a
                    // tab they have no reason to think of.
                    Button("Frühere Touren") { focus.tab = .tours }
                }
                .navigationTitle("Heute")
            }
        }
        .alert("Neue Tour", isPresented: $creating) {
            TextField(RouteStore.defaultRouteName(), text: $newName)
                .limited(to: FieldLimits.routeName, text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Anlegen") { create() }
        } message: {
            Text("Start, Lager und Ziel werden automatisch gesetzt.")
        }
        .errorAlert($error)
    }

    private func create() {
        do {
            let route = try RouteStore.createRoute(name: newName, in: context)
            focus.focus(route)
        } catch {
            self.error = AppError.message("Tour konnte nicht angelegt werden.")
        }
    }
}
