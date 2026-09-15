import SwiftData
import SwiftUI

/// Keeps the lock screen's card in step with the store, from one place.
///
/// The alternative was a `StopActivity.refresh` at the bottom of every mutation
/// in `RouteStore` — ticking a meal, resetting the day, importing a tour,
/// editing an address, re-optimizing, finishing, deleting. Ten call sites, and
/// the eleventh, added next year, is a lock screen quietly showing a stop that
/// was delivered an hour ago.
///
/// A `@Query` sees all of it for free: every one of those paths ends in a
/// `context.save()`, and this recomputes what the card would say and only
/// bothers ActivityKit when that text actually changed.
private struct LiveActivitySync: ViewModifier {
    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<Route> { $0.statusRaw == "active" },
        sort: \Route.createdAt, order: .reverse)
    private var active: [Route]

    /// Everything the card draws, flattened — so a change here means the card
    /// would look different, and no change means there is nothing to send.
    /// Cheaper than it looks, and much cheaper than waking ActivityKit on every
    /// save to hand it the values it already has.
    private var signature: String {
        guard let route = active.first else { return "" }
        let snapshot = RouteSnapshot(route)
        guard let stop = snapshot.nextOpen else { return "\(route.id)|fertig" }
        return [
            route.name, stop.id.uuidString, stop.kunde ?? "", stop.listAddress,
            stop.paket ?? "", stop.notiz ?? "",
            String(snapshot.number(stop) ?? 0),
            String(snapshot.settledCount), String(snapshot.customerCount),
        ].joined(separator: "|")
    }

    func body(content: Content) -> some View {
        content
            // On launch as well as on change: the app can be reopened onto a
            // tour whose activity was dismissed, or never started because Live
            // Activities were switched on after the tour was.
            .task { StopActivity.refresh(in: context) }
            .onChange(of: signature) { StopActivity.refresh(in: context) }
    }
}

extension View {
    /// Applied once, at the root. It has no appearance of its own — it is the
    /// tour's own state, shown somewhere the app cannot draw.
    func syncingLiveActivity() -> some View {
        modifier(LiveActivitySync())
    }
}
