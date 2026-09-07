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
            // Rearmed on every launch, which is exactly when the expiry date
            // can have moved: reinstalling from Xcode is what resets the seven
            // days, and it always launches the app.
            .task {
                // Before the reminders, and deliberately not awaited: this is
                // main-thread work that wants the first idle moment after the
                // window is up, not a slot behind a notification round trip.
                MapWarmup.run()
                await SideloadExpiry.scheduleReminders()
            }
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
            container = try AppSchema.container()
            return
        } catch {
            log.error("store did not open: \(error.localizedDescription)")
        }

        do {
            try Self.parkExistingStore()
            container = try AppSchema.container()
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

    /// Built outside the view builder. Concatenated inline it was four string
    /// operands and an optional inside a `ContentUnavailableView`, which is
    /// enough for the type checker to give up on the whole body.
    private var explanation: String {
        let base =
            "Die gespeicherten Touren konnten nicht geöffnet werden. Die alten Daten "
            + "wurden nicht gelöscht — bitte melde dich beim Entwickler, bevor du "
            + "die App neu installierst."
        guard let error else { return base }
        return base + "\n\n" + error
    }

    var body: some View {
        ContentUnavailableView {
            Label("Daten nicht lesbar", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(explanation)
        } actions: {
            Link("Entwickler kontaktieren",
                 destination: URL(string: "mailto:nikolaus.marek@outlook.com")!)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Which route is "in focus" app-wide, shared across tabs — Heute and Karte
/// both show this one, whichever tab it was chosen from.
///
/// There is one navigation path now rather than two. Routen and Verlauf used to
/// keep a stack each so that a tour pushed from one list did not appear on top
/// of the other; they are one list with two sections now, so there is one stack
/// and nothing to keep apart.
@Observable
@MainActor
final class RouteFocus {
    enum Tab: Hashable { case today, map, tours, more }

    /// Heute, because that is the tour being driven. The app used to open on
    /// the list of tours, which put a document browser in front of a driver who
    /// has exactly one document.
    var tab: Tab = .today
    var currentRouteID: UUID?
    var toursPath = NavigationPath()

    /// A stop the list should scroll to and flash as soon as it appears.
    /// Cleared by whoever consumes it, so it fires once rather than on every
    /// redraw of the list.
    var revealStopID: UUID?

    /// A stop the map should centre on and select. The same handshake as
    /// `revealStopID`, in the other direction, and cleared the same way.
    var mapStopID: UUID?

    func focus(_ route: Route) {
        currentRouteID = route.id
    }

    /// Takes the driver from a row in the stop list to that stop's pin on the
    /// map — the other half of `reveal(stop:of:)`.
    ///
    /// The map could always send you to the list; nothing could send you the
    /// other way, so "which side of the street is this one on, and what is
    /// around it" meant switching tabs and then hunting for the right pin among
    /// thirty identical ones.
    func showOnMap(stop: Stop, of route: Route) {
        currentRouteID = route.id
        mapStopID = stop.id
        tab = .map
    }

    /// Opens the route's stop list and scrolls to one stop — what the map's
    /// preview card does when you want to see a pin in context.
    ///
    /// An active tour is the one Heute is already showing, so that is where it
    /// goes, with no stack to push. A finished tour has no home but the archive,
    /// so that one is pushed onto Touren.
    func reveal(stop: Stop, of route: Route) {
        currentRouteID = route.id
        revealStopID = stop.id
        if route.status == .completed {
            toursPath = NavigationPath([route.id])
            tab = .tours
        } else {
            // Cleared, not pushed. Heute renders the focused active tour at the
            // root of its own tab; leaving a stale detail screen on the Touren
            // stack would mean the driver's Back button led somewhere they had
            // never been.
            tab = .today
        }
    }
}
