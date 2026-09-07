import SwiftUI
import SwiftData

/// The four destinations.
///
/// Three of them are the same three the app has always had. What changed is
/// which one you land on and what the last one holds.
///
/// **Heute** is new, and it is the front door: the tour being driven, with
/// nothing in front of it. The app used to open on a list of tours — a document
/// browser for a filing cabinet that holds one live document — so the screen
/// the driver spends the entire shift on was one tap in, every launch, all day.
///
/// **Touren** is the old Routen and Verlauf, merged. Finishing a tour is a
/// change of state, not a change of filing cabinet, and two tabs meant two
/// places to look for something that is only ever in one of them — with the
/// second empty on a new phone and thin for weeks after. One list with an
/// "Aktiv" section and an "Erledigt" section is how iOS files things
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

        TabView(selection: $focus.tab) {
            Tab("Heute", systemImage: "checklist", value: RouteFocus.Tab.today) {
                NavigationStack {
                    TodayTab()
                }
            }
            Tab("Karte", systemImage: "map", value: RouteFocus.Tab.map) {
                NavigationStack {
                    MapTab()
                }
            }
            Tab("Touren", systemImage: "calendar", value: RouteFocus.Tab.tours) {
                NavigationStack(path: $focus.toursPath) {
                    ToursTab()
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
