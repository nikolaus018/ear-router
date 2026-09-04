import SwiftUI
import SwiftData
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "app")

@main
struct EarRouterApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let store = Store()
    @State private var focus = RouteFocus()

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = store.container {
                    RootView()
                        .environment(focus)
                        .modelContainer(container)
                } else {
                    StoreFailureView(error: store.failure)
                }
            }
            .tint(Color.brand)
        }
        .onChange(of: scenePhase) { _, phase in
            // The geocode cache batches its writes, so a force-quit or a
            // backgrounded app inside that window would lose everything
            // resolved since the last flush — and every one of those is a
            // throttled round trip that would have to be paid again.
            if phase != .active {
                Task { await GeocodeCache.shared.save() }
            }
        }
    }
}

/// Opens the SwiftData store, with one recovery attempt.
///
/// A store that will not open is not a reason to crash on launch in front of a
/// driver holding a van full of meals. If the normal open fails — a schema the
/// binary no longer understands, a half-written file from a device that ran out
/// of space — the existing store is moved aside rather than deleted and a fresh
/// one is created, so the app comes up usable and the old file is still there to
/// recover from. Only if *that* fails does the app show an error, and it says
/// what happened rather than disappearing.
@MainActor
final class Store {
    private(set) var container: ModelContainer?
    private(set) var failure: String?

    init() {
        do {
            container = try ModelContainer(for: Route.self, Stop.self)
            return
        } catch {
            log.error("store did not open: \(error.localizedDescription)")
        }

        do {
            try Self.parkExistingStore()
            container = try ModelContainer(for: Route.self, Stop.self)
            log.warning("opened a fresh store; the previous one was moved aside")
        } catch {
            log.fault("store recovery failed: \(error.localizedDescription)")
            failure = error.localizedDescription
        }
    }

    /// Renames the store files out of the way, keeping them for recovery.
    private static func parkExistingStore() throws {
        let fm = FileManager.default
        let dir = URL.applicationSupportDirectory
        let stamp = Int(Date().timeIntervalSince1970)
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            let url = dir.appending(path: name)
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.moveItem(at: url, to: dir.appending(path: "\(name).broken-\(stamp)"))
        }
    }
}

struct StoreFailureView: View {
    let error: String?

    var body: some View {
        ContentUnavailableView {
            Label("Daten nicht lesbar", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(
                "Die gespeicherten Touren konnten nicht geöffnet werden. Die alten Daten "
                    + "wurden nicht gelöscht — bitte melde dich beim Entwickler, bevor du "
                    + "die App neu installierst."
                    + (error.map { "\n\n\($0)" } ?? ""))
        } actions: {
            Link("Entwickler kontaktieren", destination: URL(string: "mailto:nikolaus.marek@outlook.com")!)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Which route is "in focus" app-wide, shared across tabs — the Karte tab
/// always shows this one regardless of which tab it was opened from.
///
/// `detailOrigin` records *which* tab's list a route was opened from, so the
/// pushed stops-list detail screen only appears in that one tab — the same
/// per-tab navigation-stack behaviour `UITabBarController` gives you for free.
/// Picking a route in the Karte tab's own picker clears it, so browsing the map
/// never leaves a stray detail screen behind in Routen or Verlauf.
@Observable
@MainActor
final class RouteFocus {
    enum Tab: Hashable { case routes, map, history, more }

    var tab: Tab = .routes
    var currentRouteID: UUID?
    var routesPath = NavigationPath()
    var historyPath = NavigationPath()

    /// A stop the list should scroll to and flash as soon as it appears.
    /// Cleared by whoever consumes it, so it fires once rather than on every
    /// redraw of the list.
    var revealStopID: UUID?

    func focus(_ route: Route) {
        currentRouteID = route.id
    }

    /// Opens the route's stop list and scrolls to one stop — what the map's
    /// preview card does when you want to see a pin in context.
    ///
    /// A completed route lives in Verlauf rather than Routen, so the push goes
    /// onto that tab's stack; pushing it onto Routen would land the driver on a
    /// detail screen inside a list the route is not in.
    func reveal(stop: Stop, of route: Route) {
        currentRouteID = route.id
        revealStopID = stop.id
        if route.status == .completed {
            historyPath = NavigationPath([route.id])
            tab = .history
        } else {
            routesPath = NavigationPath([route.id])
            tab = .routes
        }
    }
}
