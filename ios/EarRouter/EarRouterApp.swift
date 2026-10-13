import SwiftUI
import SwiftData
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "app")

@main
struct EarRouterApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let store: Store
    @State private var focus: RouteFocus

    init() {
        let store = Store()
        self.store = store
        _focus = State(initialValue: RouteFocus(tab: Self.launchTab(store.container)))
    }

    /// Jetzt when a delivery is waiting, Touren otherwise.
    ///
    /// Picked up mid-shift, the app is opened to see the next door, and that is
    /// what Jetzt is. Opened with nothing to deliver — a new install, a day off,
    /// a tour already done — Jetzt would only say there is nothing to do, and
    /// the next thing to do is in Touren.
    private static func launchTab(_ container: ModelContainer?) -> RouteFocus.Tab {
        guard let container else { return .tours }
        let open = FetchDescriptor<Route>(predicate: #Predicate { $0.statusRaw == "active" })
        let routes = (try? container.mainContext.fetch(open)) ?? []
        // A door still owed a visit, not merely one without a tick. A customer
        // nobody was home for leaves `delivered` false for good, and counting
        // that as waiting opened the app on Jetzt to tell the driver there was
        // nothing to do — on every launch, for the rest of the day.
        let waiting = routes.contains { route in
            route.nextOpenStop != nil
        }
        return waiting ? .now : .tours
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = store.container {
                    RootView()
                        .environment(focus)
                        .modelContainer(container)
                        // What the finished tours say about the next one's
                        // door times, before the first screen asks for an
                        // arrival time.
                        .task {
                            RouteStore.correctLagerPostcode(in: container.mainContext)
                            PaceHistory.refresh(in: container.mainContext)
                        }
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

/// Which route is "in focus" app-wide — the Karte tab shows this one, and the
/// app reopens on the last active one of them.
///
/// There is one navigation path rather than two. Routen and Verlauf used to
/// keep a stack each so that a tour pushed from one list did not appear on top
/// of the other; they are one list with two sections now, so there is one stack
/// and nothing to keep apart.
@Observable
@MainActor
final class RouteFocus {
    enum Tab: Hashable { case now, tours, map, more }

    var tab: Tab

    /// Seeded from the tour the app was last working, so a relaunch — iOS
    /// ending the app in the background mid-shift, while the navigation app
    /// had the screen — comes back to that tour rather than to whichever
    /// happens to be newest. Jetzt used to reopen on the newest until the
    /// driver next happened to visit Touren, which was the only screen that
    /// remembered.
    init(tab: Tab = .tours) {
        self.tab = tab
        let remembered = Self.lastOpenedRouteID
        self.currentRouteID = remembered
        self.workingRouteID = remembered
    }

    /// The tour on screen: what Karte shows, and what Touren last opened. Any
    /// tour, a finished one included — looking at yesterday is allowed.
    private(set) var currentRouteID: UUID?

    /// The tour being worked: the last *active* tour opened. What Jetzt, the
    /// lock screen, Siri and the car's navigation all mean by the current tour
    /// — see `Route.current`. Kept apart from `currentRouteID` so that opening
    /// a finished tour to read its report does not move all four of them off
    /// the tour still being driven.
    private(set) var workingRouteID: UUID?

    var toursPath = NavigationPath()

    /// What the tab bar writes to, instead of `tab` directly.
    func select(_ newTab: Tab) {
        tab = newTab
    }

    /// A stop the list should scroll to and flash as soon as it appears.
    /// Cleared by whoever consumes it, so it fires once rather than on every
    /// redraw of the list.
    var revealStopID: UUID?

    /// A stop the map should centre on and select. The same handshake as
    /// `revealStopID`, in the other direction, and cleared the same way.
    var mapStopID: UUID?

    func focus(_ route: Route) {
        currentRouteID = route.id
        guard route.status == .active else { return }
        workingRouteID = route.id
        UserDefaults.standard.set(route.id.uuidString, forKey: Self.lastOpenedKey)
    }

    /// Lets go of both tours — a restore that replaces everything is about to
    /// delete whatever they were.
    func forget() {
        currentRouteID = nil
        workingRouteID = nil
        UserDefaults.standard.removeObject(forKey: Self.lastOpenedKey)
    }

    /// The tour the app was last working, remembered across launches. Only an
    /// active one is ever written here; see `focus(_:)`.
    ///
    /// This is what makes a second tab unnecessary. The app used to forget, so
    /// every launch put the driver on a list of tours with one row on it and
    /// charged them a tap to get to the screen they spend the shift on — and
    /// the answer to that was briefly a whole "Heute" tab, which rendered the
    /// same view as tapping that row and so was two tabs for one screen. What
    /// was actually missing was not a destination. It was the app remembering
    /// where it was.
    static var lastOpenedRouteID: UUID? {
        UserDefaults.standard.string(forKey: lastOpenedKey)
            .flatMap(UUID.init(uuidString:))
    }

    private static let lastOpenedKey = "lastOpenedRouteID"

    /// Takes the driver from a row in the stop list to that stop's pin on the
    /// map — the other half of `reveal(stop:of:)`.
    ///
    /// The map could always send you to the list; nothing could send you the
    /// other way, so "which side of the street is this one on, and what is
    /// around it" meant switching tabs and then hunting for the right pin among
    /// thirty identical ones.
    func showOnMap(stop: Stop, of route: Route) {
        focus(route)
        mapStopID = stop.id
        tab = .map
    }

    /// Opens the route's stop list and scrolls to one stop — what the map's
    /// preview card does when you want to see a pin in context.
    ///
    /// Assigned rather than appended: the stack may already be showing a
    /// different tour, and pushing a second one onto it would put two tour
    /// screens in a row behind one Back button.
    func reveal(stop: Stop, of route: Route) {
        focus(route)
        revealStopID = stop.id
        toursPath = NavigationPath([route.id])
        tab = .tours
    }

    /// Opens a tour's stop list — what Jetzt's "Zur Tour" does for a tour with
    /// no stops on it yet.
    /// Assigned rather than appended, for the reason `reveal` gives.
    func open(_ route: Route) {
        focus(route)
        toursPath = NavigationPath([route.id])
        tab = .tours
    }
}
