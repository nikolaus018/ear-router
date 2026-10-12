import AppIntents
import Foundation
import SwiftData

/// Starting the navigation to the next door without the driver touching the
/// phone — what should happen when the van is plugged in and the engine goes on.
///
/// Why this is a switch plus an intent rather than something the app does by
/// itself is worth writing down, because from the outside it looks like an
/// oversight. iOS launches an app when CarPlay connects only for apps holding a
/// CarPlay scene entitlement, which Apple grants by application and which this
/// build — signed by a free personal team on a seven-day profile — cannot carry
/// at all. And an app that is not in the foreground may not open another app's
/// URL, so even one kept alive in the background could not hand the stop over.
///
/// What *is* allowed is iOS's own "CarPlay verbindet sich" automation, which
/// runs an App Intent immediately, with the phone locked and in a pocket. So
/// the app supplies the intent and explains the automation once, in
/// `CarPlaySetupSheet`.
///
/// This switch is the arming key for it. It exists because the automation lives
/// in Kurzbefehle, where a driver handing the phone over for a day, or driving
/// somebody else's round, would otherwise have to go and take the automation
/// apart to stop it — and put it back together afterwards.
enum CarPlayNavigation {
    /// Also read directly by `@AppStorage` in the settings screen, so it lives
    /// here rather than being spelled out twice.
    static let enabledKey = "carplay.autonavigate"

    /// Off until the driver turns it on. A feature that opens a navigation app
    /// on its own is not one to switch on behind somebody's back.
    ///
    /// Written only by the `@AppStorage` switch in Mehr and by a restored
    /// backup, so there is a reader here and no writer. The `defaults`
    /// parameter is for tests: this is global mutable state, and two of them
    /// racing on the standard suite is a test that passes alone and fails in a
    /// full run.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Why there was nothing to navigate to.
    ///
    /// Spoken sentences rather than error codes: an automation that fails shows
    /// its reason on the lock screen, which is the only place the driver will
    /// ever see this — "Alle Stopps sind erledigt" is then a useful thing to be
    /// told at the wheel, and "Fehler 3" is not.
    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case disabled
        case noStore
        case noTour
        case allDone
        case noAddress

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .disabled: "CarPlay-Navigation ist in EAR Router ausgeschaltet."
            case .noStore: "Die Tourdaten lassen sich gerade nicht öffnen."
            case .noTour: "Es läuft gerade keine Tour."
            case .allDone: "Alle Stopps sind erledigt."
            case .noAddress: "Der nächste Stopp hat keine Adresse zum Navigieren."
            }
        }
    }

    /// The next door on the current tour, and where to send the navigation app
    /// for it.
    ///
    /// The same tour and the same `nextOpen` the Jetzt tab shows — see
    /// `Route.current` — so a stop the driver has already answered for is not
    /// driven to again, whichever way they answered, and a second active tour
    /// does not take over the car from the one being driven. `working` is only
    /// ever passed by tests; the app's own answer is the tour last worked.
    ///
    /// Split out of the intent because an intent's `perform` cannot be reached
    /// from a test, and this is the part that can be wrong in a way that costs
    /// a morning: navigating to yesterday's tour, or to a door already done.
    @MainActor
    static func destination(
        in context: ModelContext, working: UUID? = RouteFocus.lastOpenedRouteID
    ) throws -> (stop: Stop, url: URL) {
        guard let route = Route.current(in: context, working: working) else {
            throw Failure.noTour
        }
        guard let stop = RouteSnapshot(route).nextOpen else { throw Failure.allDone }
        guard let url = NavigationHandoff.url(for: stop) else { throw Failure.noAddress }
        return (stop, url)
    }
}

/// The intent the CarPlay automation runs — and the one a driver can say out
/// loud on a morning they have not plugged the phone in.
///
/// Read-only, like `NextStopIntent`, and for the same reason: it looks at the
/// tour and opens a map. It cannot tick anything off, so the worst it can do on
/// a misfire is offer directions to a door that is already done — which is a
/// glance at the windscreen, not a meal written off as delivered.
struct NavigateNextStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Zum nächsten Stopp navigieren"
    static let description = IntentDescription(
        "Startet die Navigation zum nächsten offenen Stopp der laufenden Tour, in der App, die unter „Navigation“ eingestellt ist.")

    /// The app stays closed. What the driver needs on the screen is the
    /// navigation app; bringing EAR Router up first would put a tour list in
    /// front of the turn they are about to miss.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & OpensIntent {
        guard CarPlayNavigation.isEnabled() else { throw CarPlayNavigation.Failure.disabled }
        guard let container = try? AppSchema.container() else {
            throw CarPlayNavigation.Failure.noStore
        }
        let (stop, url) = try CarPlayNavigation.destination(in: ModelContext(container))
        // Plugging the phone in at the depot is leaving for the Lager, too.
        TourDeparture.noteNavigation(to: stop)
        return .result(opensIntent: OpenURLIntent(url))
    }
}
