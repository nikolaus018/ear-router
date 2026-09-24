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

    /// The newest fix this launch has seen: the first one, or the one
    /// `currentFix` last waited for.
    private(set) var lastCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var lastFixAt: Date?

    /// `lastCoordinate`, but only if it is no older than `age`.
    func recentFix(within age: TimeInterval) -> CLLocationCoordinate2D? {
        guard let lastFixAt, Date().timeIntervalSince(lastFixAt) <= age else { return nil }
        return lastCoordinate
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<CLLocationCoordinate2D?, Never>] = [:]

    /// Where the driver is *now* — a fix taken for this call, not the one from
    /// launch, which on an app left open overnight is yesterday's. Asks for
    /// permission first if it was never asked. Gives up after `timeout` with
    /// `nil`, so a phone indoors cannot hold up its caller for long.
    @discardableResult
    func currentFix(timeout: Duration = .seconds(8)) async -> CLLocationCoordinate2D? {
        status = manager.authorizationStatus
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: return nil
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.waiting.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    private func answerWaiting(with coordinate: CLLocationCoordinate2D?) {
        let all = waiting
        waiting.removeAll()
        for continuation in all.values { continuation.resume(returning: coordinate) }
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
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            if isDenied { answerWaiting(with: nil) }
            return
        }
        guard !hasFix || !waiting.isEmpty else { return }
        manager.startUpdatingLocation()
    }

    /// The first fix is in: nothing else in the app needs Core Location running.
    private func stopWaiting() {
        manager.stopUpdatingLocation()
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
        guard let location = locations.last else { return }
        // Core Location may first hand back a cached fix from hours ago; one
        // who asked for "now" keeps waiting past it.
        let isFresh = abs(location.timestamp.timeIntervalSinceNow) < 60
        let coordinate = location.coordinate
        let takenAt = location.timestamp
        Task { @MainActor [weak self] in
            guard let self else { return }
            if isFresh || self.lastCoordinate == nil {
                self.lastCoordinate = coordinate
                self.lastFixAt = takenAt
            }
            if !self.waiting.isEmpty {
                guard isFresh else { return }
                self.answerWaiting(with: coordinate)
            }
            self.stopWaiting()
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
