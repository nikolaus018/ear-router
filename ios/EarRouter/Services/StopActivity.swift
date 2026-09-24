import ActivityKit
import Foundation
import OSLog
import SwiftData

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "activity")

/// Keeps the lock screen showing the door the driver is on.
///
/// One activity at a time, for the tour the rest of the app is already talking
/// about: the current one, as `Route.current` decides it. It starts itself when
/// that tour has a door still owed a visit, follows `nextOpen` as the driver
/// ticks along, and ends when the last door is answered for — so the thing on
/// the lock screen is never a stop that is already done.
///
/// Driven from the app rather than from a push: every change it reflects is one
/// the driver made in the app a moment earlier, so there is always a foreground
/// moment to update in, and no server, no APNs certificate, and nothing to keep
/// alive in the background.
@MainActor
enum StopActivity {

    /// Whether to bother at all. Off when the driver has switched Live
    /// Activities off for the app in Settings, which is a real answer and not
    /// an error to log every time a meal is ticked.
    private static var available: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Brings the lock screen back in line with the store: starts, updates or
    /// ends, whichever the tour now calls for.
    ///
    /// Safe to call after anything — a tick, an import, a re-optimize, a
    /// deletion, a launch. It reads the same current tour Jetzt shows — see
    /// `Route.current` — and works out the rest itself, so no call site has to
    /// know which of the three things is about to happen.
    static func refresh(
        in context: ModelContext, working: UUID? = RouteFocus.lastOpenedRouteID
    ) {
        guard available else { return }

        // One snapshot, not two: it walks every stop on the tour, and this
        // runs after every tick.
        guard let route = Route.current(in: context, working: working) else {
            end()
            return
        }
        let snapshot = RouteSnapshot(route)
        guard let stop = snapshot.nextOpen else {
            end()
            return
        }
        // What the app knows about this customer from every previous tour —
        // the floor, and whatever the driver wrote down at the door once. The
        // same lookup the Jetzt tab and Siri do; a stop with nothing stored
        // simply carries neither.
        let info = (try? StockwerkStore.note(for: stop, in: context)) ?? nil
        let state = StopActivityAttributes.ContentState(
            kunde: stop.kunde?.trimmed.nilIfEmpty ?? "Stopp",
            adresse: stop.strasse?.trimmed.nilIfEmpty ?? "",
            // Capped: ActivityKit refuses a state over 4 KB outright, and the
            // widget shows one line of it anyway.
            paket: stop.displayPaket?.trimmed.nilIfEmpty.map { String($0.prefix(300)) },
            notiz: stop.notiz?.trimmed.nilIfEmpty,
            stockwerk: info?.stockwerk?.trimmed.nilIfEmpty.map(Format.floor),
            kundeninfo: info?.notiz?.trimmed.nilIfEmpty,
            number: snapshot.number(stop))
        let tour = route.name

        Task { await sync(tour: tour, state: state) }
    }

    /// Takes the activity down — the tour is finished, deleted, or there is no
    /// longer one running.
    static func end() {
        Task { await sync(tour: nil, state: nil) }
    }

    // MARK: - Private

    /// Every call into ActivityKit, in one `nonisolated` place.
    ///
    /// Not an accident of style. `Activity` is a class, it is not `Sendable`,
    /// and `update` and `end` are `nonisolated async` — so an activity read on
    /// the main actor and awaited on there is a non-`Sendable` object crossing
    /// an isolation boundary, which Swift 6 rejects. Read it here, use it here,
    /// and it never crosses: what goes in is the tour's name and a state struct
    /// of strings and numbers, both of which are `Sendable` on their own.
    private nonisolated static func sync(
        tour: String?, state: StopActivityAttributes.ContentState?
    ) async {
        guard let tour, let state else {
            await endAll()
            return
        }

        if let current = Activity<StopActivityAttributes>.activities
            .first(where: { $0.attributes.tour == tour }) {
            await current.update(ActivityContent(state: state, staleDate: nil))
            return
        }

        // A different tour than the one on the lock screen means the driver
        // moved on: the old activity is replaced rather than updated, because
        // Tuesday's stops under Monday's tour name is worse than a moment with
        // nothing there at all.
        await endAll()
        do {
            _ = try Activity.request(
                attributes: StopActivityAttributes(tour: tour),
                content: ActivityContent(state: state, staleDate: nil))
        } catch {
            // Not surfaced. A Live Activity that will not start is a lock
            // screen that stays as it was; the tour itself is unaffected, and
            // an alert about it would interrupt a driver at a door over
            // something they cannot act on.
            log.error("Live Activity nicht gestartet: \(error.localizedDescription)")
        }
    }

    private nonisolated static func endAll() async {
        for activity in Activity<StopActivityAttributes>.activities {
            // `end(_:dismissalPolicy:)`, with no new content: the older
            // one-argument form has been deprecated since iOS 16.2.
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
