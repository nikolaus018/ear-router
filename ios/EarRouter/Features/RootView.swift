import SwiftUI
import SwiftData

/// The four destinations. `TabView` on iOS 26 draws its own Liquid Glass tab
/// bar.
///
/// Deliberately *not* `tabBarMinimizeBehavior(.onScrollDown)`: that is meant
/// for immersive, content-first screens (Music, Safari), where chrome getting
/// out of the way is the point. Here the tab bar is the app's primary
/// navigation, and minimizing it collapsed the whole bar into a single pill
/// showing only the active tab's icon — on "Mehr" that is a circle with three
/// dots, which reads as a bug, not as an affordance. Apple's guidance is that
/// persistent navigation stays put.
struct RootView: View {
    @Environment(RouteFocus.self) private var focus

    var body: some View {
        @Bindable var focus = focus

        TabView {
            Tab("Routen", systemImage: "list.bullet") {
                NavigationStack(path: $focus.routesPath) {
                    RoutesTab()
                }
            }
            Tab("Karte", systemImage: "map") {
                NavigationStack {
                    MapTab()
                }
            }
            Tab("Verlauf", systemImage: "clock.arrow.circlepath") {
                NavigationStack(path: $focus.historyPath) {
                    HistoryTab()
                }
            }
            Tab("Mehr", systemImage: "ellipsis") {
                NavigationStack {
                    MoreTab()
                }
            }
        }
    }
}
