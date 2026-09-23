import SwiftData
import SwiftUI

/// Keeps the screen on while a tour still has doors to visit.
///
/// The phone sits in its holder between doors, and auto-lock turned it dark
/// every time — so every stop began with unlocking it again. Only while there
/// is something left to deliver: a phone left on the Mehr tab at home, or on a
/// finished tour, locks as it always did.
///
/// Its own modifier with its own `@Query`, for the reason `LiveActivitySync`
/// is: a query at the root would redraw the whole tab view on every tick.
private struct ScreenAwake: ViewModifier {
    @Query(filter: #Predicate<Route> { $0.statusRaw == "active" })
    private var active: [Route]

    /// The same question `EarRouterApp.launchTab` asks: a door still owed a
    /// visit, not merely a stop without a tick.
    private var working: Bool {
        active.contains { $0.nextOpenStop != nil }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { UIApplication.shared.isIdleTimerDisabled = working }
            .onChange(of: working) { _, now in
                UIApplication.shared.isIdleTimerDisabled = now
            }
    }
}

extension View {
    /// Applied once, at the root.
    func keepingScreenAwakeDuringTour() -> some View {
        modifier(ScreenAwake())
    }
}
