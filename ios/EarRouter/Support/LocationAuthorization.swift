import CoreLocation
import Observation
import UIKit

/// Owns the app's one `CLLocationManager` and, above all, actually asks for
/// permission.
///
/// `UserAnnotation` draws the blue dot and `MapUserLocationButton` toggles the
/// follow mode — but neither of them asks iOS for anything. With nothing
/// requesting authorization the status stays `.notDetermined` for the life of
/// the install: the system never shows its prompt, Core Location never delivers
/// a fix, and the location button sits there spinning at a driver who is trying
/// to work out which side of the street they are on. The `Info.plist` usage
/// string is necessary but does nothing on its own; this is the other half.
///
/// The manager is a stored property rather than a local for the same class of
/// reason: a `CLLocationManager` that goes out of scope takes its pending
/// authorization callback with it, and the prompt answer never arrives.
@MainActor
@Observable
final class LocationAuthorization: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAuthorization()

    private(set) var status: CLAuthorizationStatus = .notDetermined

    @ObservationIgnored private let manager = CLLocationManager()

    private override init() {
        super.init()
        manager.delegate = self
        status = manager.authorizationStatus
    }

    /// Asks, if there is anything to ask. Once the driver has answered — either
    /// way — iOS ignores further requests, so this is safe to call on every
    /// appearance of the map and is deliberately not gated on a flag of our own
    /// that could drift out of step with the real setting.
    func requestIfNeeded() {
        status = manager.authorizationStatus
        guard status == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// The driver said no, or the device will not allow it. Worth saying out
    /// loud on the map, because the alternative is a control that looks
    /// available and silently does nothing.
    var isDenied: Bool { status == .denied || status == .restricted }

    /// Opens this app's page in Settings, which is the only place a denied
    /// permission can be given back.
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // Core Location calls this on the queue the manager was created on — the
    // main queue — but the delegate conformance itself cannot be main-actor
    // isolated, so the hop is explicit.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let updated = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.status = updated
        }
    }
}
