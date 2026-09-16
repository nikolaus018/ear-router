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

    /// Core Location has answered at least once this launch.
    ///
    /// The map needs this and not just `status`. A `.userLocation` camera
    /// position resolves once, against whatever Core Location can say at that
    /// instant — and the instant the driver taps "Allow While Using App" there
    /// is no fix yet, so the camera quietly settles on its fallback and stays
    /// there. Granting the permission is not the moment there is somewhere to
    /// point the map; the first fix is.
    private(set) var hasFix = false

    @ObservationIgnored private let manager = CLLocationManager()

    /// Where the driver is, kept current only while the Karte is following
    /// them — see `startFollowing`. Seeded from Core Location's last fix.
    private(set) var liveLocation: CLLocation?
    /// Which way the phone is pointing, in degrees from north. `nil` until the
    /// compass answers, and on a device without one.
    private(set) var heading: Double?

    @ObservationIgnored private var following = false

    /// Position and compass updates for the Karte's close-in follow. Stopped
    /// again as soon as the map stops following, so nothing runs in the
    /// background of a tour.
    func startFollowing() {
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        following = true
        liveLocation = manager.location
        manager.distanceFilter = 2
        manager.headingFilter = 3
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func stopFollowing() {
        guard following else { return }
        following = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.distanceFilter = kCLDistanceFilterNone
    }

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
        guard status == .notDetermined else {
            askForAFix()
            return
        }
        manager.requestWhenInUseAuthorization()
    }

    /// One fix, not a stream. Nothing in this app tracks the driver as they
    /// drive — `UserAnnotation` keeps the dot current on its own — this exists
    /// only so that something is known to be *there*, for the map to point at.
    ///
    /// `startUpdatingLocation` and an immediate stop, rather than the
    /// one-shot `requestLocation`: asked in the same breath as the permission
    /// was granted, `requestLocation` regularly answers `locationUnknown`
    /// instead of a fix and does not try again, so `hasFix` stayed false for
    /// the whole session that needed it most.
    private func askForAFix() {
        guard !hasFix else { return }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        manager.startUpdatingLocation()
    }

    /// The first fix is in: nothing else in the app needs Core Location running.
    private func stopWaiting() {
        if !following { manager.stopUpdatingLocation() }
        hasFix = true
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
            self?.askForAFix()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let last = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.following { self.liveLocation = last }
            self.stopWaiting()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading
    ) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor [weak self] in
            guard let self, self.following else { return }
            self.heading = degrees
        }
    }

    /// Required alongside `requestLocation()`, and deliberately silent. A fix
    /// that does not arrive leaves `hasFix` false, which is exactly what the
    /// map should act on — there is nothing to say to the driver that the
    /// location button does not already say by refusing to light up.
    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {}
}
