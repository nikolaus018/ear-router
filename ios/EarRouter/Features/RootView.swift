import SwiftUI
import SwiftData

/// Three destinations, and the tour is not one of them.
///
/// It briefly was. "Heute" was added as a front door because the app opened on
/// a list of tours — a document browser for a filing cabinet holding one live
/// document — so the screen the driver spends the whole shift on cost a tap
/// every launch. But Heute rendered `TourView` for the newest active tour, and
/// tapping the one row in Touren rendered `TourView` for that same tour: two
/// tabs, one screen, and no way for anybody to tell them apart because there
/// was nothing to tell.
///
/// The tap was never a missing destination. It was the app forgetting where it
/// had been — so `ToursTab` reopens the tour it was last on, and the driver
/// lands on it with a Back button that leads somewhere real.
///
/// **Touren** is also the old Routen and Verlauf merged. Finishing a tour is a
/// change of state, not a change of filing cabinet, and two tabs meant two
/// places to look for something that is only ever in one of them — with the
/// second empty on a new phone and thin for weeks after. One list with an
/// "Aktiv" section and an "Erledigt" section is how iOS files things everywhere
/// it can.
///
/// Deliberately *not* `tabBarMinimizeBehavior(.onScrollDown)`: that is meant
/// for immersive, content-first screens (Music, Safari), where chrome getting
/// out of the way is the point. Here the tab bar is the app's primary
/// navigation, and minimizing it collapsed the whole bar into a single pill
/// showing only the active tab's icon — on "Mehr" that is a circle with three
/// dots, which reads as a bug, not as an affordance.
struct RootView: View {
    @Environment(RouteFocus.self) private var focus

    var body: some View {
        @Bindable var focus = focus

        // Selection routed through `focus.select` rather than straight into
        // `focus.tab`: choosing Karte is a request to be shown where you are,
        // and that is not something a tab value can carry. See `RouteFocus`.
        TabView(selection: Binding(get: { focus.tab }, set: { focus.select($0) })) {
            // `truck.box`, not `shippingbox`: a tour is a delivery *run*, and
            // `shippingbox` is already the glyph for the Lager stop in the list
            // and for the empty state. One symbol doing three jobs teaches the
            // driver nothing about any of them.
            Tab("Touren", systemImage: "truck.box", value: RouteFocus.Tab.tours) {
                NavigationStack(path: $focus.toursPath) {
                    ToursTab()
                }
            }
            Tab("Karte", systemImage: "map", value: RouteFocus.Tab.map) {
                NavigationStack {
                    MapTab()
                }
            }
            Tab("Mehr", systemImage: "ellipsis", value: RouteFocus.Tab.more) {
                NavigationStack {
                    MoreTab()
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environment(RouteFocus())
        .modelContainer(for: [Route.self, Stop.self, StockwerkNote.self], inMemory: true)
}
