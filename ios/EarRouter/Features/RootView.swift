import SwiftUI
import SwiftData

/// Four destinations: the tours, what to do now, the map, and everything else.
///
/// **Jetzt** is the stop the driver is on, given the whole screen. It used to be
/// a card floating over the bottom of the tour's stop list, where it covered a
/// third of the list and repeated the row right above it. It is deliberately not
/// the "Heute" tab this app once had and dropped: Heute rendered the same stop
/// list as Touren, two doors to one room. Jetzt is a different room — one stop
/// and what to do there, nothing else. The app opens on it whenever a delivery
/// is waiting (see `EarRouterApp.launchTab`).
///
/// **Touren** is the old Routen and Verlauf merged. Finishing a tour is a
/// change of state, not a change of filing cabinet, and two tabs meant two
/// places to look for something that is only ever in one of them. One list with
/// an "Aktiv" section and an "Erledigt" section is how iOS files things
/// everywhere it can.
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
            // Touren first, then Jetzt: the order a day goes in — pick the
            // tour, then work it.
            //
            // `truck.box`, not `shippingbox`: a tour is a delivery *run*, and
            // `shippingbox` is already the glyph for the Lager stop in the list
            // and for the empty state. One symbol doing three jobs teaches the
            // driver nothing about any of them.
            Tab("Touren", systemImage: "truck.box", value: RouteFocus.Tab.tours) {
                NavigationStack(path: $focus.toursPath) {
                    ToursTab()
                }
            }
            // An open door: the one the driver is at, or on the way to. Not a
            // parcel — `shippingbox` is the Lager and the Paket — and not a
            // pin, which is the map's.
            Tab("Jetzt", systemImage: "door.left.hand.open", value: RouteFocus.Tab.now) {
                NavigationStack {
                    NowTab()
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
        // Not a tab and not a screen: the door the driver is on, put where the
        // phone can show it without being unlocked. Here rather than on one of
        // the tabs because it has to hold whichever tab is in front.
        .syncingLiveActivity()
    }
}

#Preview {
    RootView()
        .environment(RouteFocus())
        .modelContainer(for: [Route.self, Stop.self, StockwerkNote.self], inMemory: true)
}
