import SwiftUI
import WidgetKit

/// The extension's entry point. Only the Live Activity lives here — there is no
/// home screen widget, because everything a driver wants at a glance is about
/// the door they are on, and that is what an activity is for.
@main
struct EarRouterWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StopLiveActivity()
    }
}
