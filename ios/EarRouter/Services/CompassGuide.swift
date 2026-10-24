import CoreLocation
import Foundation

/// The arithmetic behind the lock screen's arrow, kept apart from Core
/// Location so it can be tested without a phone.
enum CompassMath {
    /// The arrow appears inside this, and goes away beyond `hideBeyond`. Two
    /// numbers rather than one so that a driver hovering at the edge — GPS
    /// wobble, a one-way loop round the block — does not see it blink on and
    /// off. Close enough to be useful, far enough that the driver is out of the
    /// car or about to be: further out the road decides, and the navigation app
    /// already knows it.
    static let showWithin = 250.0
    static let hideBeyond = 300.0
    /// Inside this the arrow is noise — GPS is no better than this — so it is
    /// replaced by "da".
    static let arrivedWithin = 25.0

    /// Degrees clockwise from north, in 0..<360.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    static func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Where the target is relative to the way the driver faces, clockwise,
    /// 0..<360.
    static func relative(bearing: Double, facing: Double) -> Double {
        var d = (bearing - facing).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// To the nearest `step` degrees: a state that changes for every degree is
    /// an update ActivityKit has to be asked for several times a second.
    static func quantized(_ degrees: Double, step: Int = 15) -> Int {
        (Int((degrees / Double(step)).rounded()) * step) % 360
    }

    /// Tens of metres when it is near enough for tens to matter, then twenty-
    /// fives.
    static func roundedMeters(_ m: Double) -> Int {
        m < 100 ? Int((m / 10).rounded()) * 10 : Int((m / 25).rounded()) * 25
    }

    /// What the card should show, or `nil` for nothing. `facing` is the way the
    /// phone is pointing or the car is going; without it there is a distance
    /// but nothing to turn an arrow by, and a wrong arrow is worse than none.
    static func hint(
        distance: Double, bearing: Double, facing: Double?, wasShown: Bool
    ) -> StopActivityAttributes.Kompass? {
        guard distance <= (wasShown ? hideBeyond : showWithin) else { return nil }
        if distance <= arrivedWithin {
            return .init(grad: 0, meter: roundedMeters(distance), da: true)
        }
        guard let facing else { return nil }
        return .init(
            grad: quantized(relative(bearing: bearing, facing: facing)),
            meter: roundedMeters(distance), da: false)
    }
}

/// Watches the driver's position while a door is open, and gives the lock
/// screen an arrow for the last few hundred metres.
///
/// Until now nothing in the app followed the driver; this does, and only for
/// as long as a tour has a door still owed a visit. It runs in the background
/// (the lock screen is exactly where it is wanted), so iOS shows its blue
/// location indicator, and it takes care to ask for little until it is near:
/// coarse and rare while the door is far off, fine and frequent in the last
/// 600 m.
///
/// Which way "ahead" is: the direction of travel while moving, since a phone in
/// a cradle or a pocket says nothing about the car; the phone's own compass
/// once the driver is on foot.
@MainActor
final class CompassGuide: NSObject, CLLocationManagerDelegate {
    static let shared = CompassGuide()

    private(set) var hint: StopActivityAttributes.Kompass?

    private let manager = CLLocationManager()
    private var targetID: UUID?
    private var target: CLLocationCoordinate2D?
    private var location: CLLocation?
    private var heading: Double?
    /// The last direction of travel seen, kept for the moment the car stops and
    /// the GPS course turns invalid.
    private var lastCourse: Double?
    private var fine = false
    private var lastPush = Date.distantPast

    /// Faster than this, the GPS course is trusted over the phone's compass.
    private let drivingSpeed = 2.0
    /// Closer than this the finer, hungrier settings take over.
    private let fineWithin = 600.0
    private let minimumPushGap: TimeInterval = 2

    private override init() {
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// The point the arrow aims at: the same one the navigation app is sent to
    /// — the pin, then the house's entrance — and the stop's stored point
    /// otherwise. `nil` when there is no usable one, in which case there is no
    /// arrow rather than one pointing at the middle of Vienna.
    static func point(for stop: Stop) -> CLLocationCoordinate2D? {
        if case .point(let lat, let lon) = NavigationHandoff.destination(for: stop) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard Coordinates.isPlausible(lat: stop.lat, lon: stop.lon, forPlz: stop.plz ?? "")
        else { return nil }
        return CLLocationCoordinate2D(latitude: stop.lat, longitude: stop.lon)
    }

    /// Aims at a door, or at nothing — which stops listening altogether.
    func setTarget(id: UUID?, coordinate: CLLocationCoordinate2D?) {
        if id != targetID { hint = nil }
        targetID = id
        target = coordinate
        guard id != nil, coordinate != nil else {
            stop()
            return
        }
        start()
        update()
    }

    private var authorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
    }

    private func start() {
        guard authorized else { return }
        manager.allowsBackgroundLocationUpdates = true
        applyAccuracy(fine: fine)
        manager.startUpdatingLocation()
        if fine { manager.startUpdatingHeading() }
    }

    private func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        location = nil
        fine = false
        hint = nil
    }

    private func applyAccuracy(fine: Bool) {
        if fine {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 5
            manager.headingFilter = 10
        } else {
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 100
        }
    }

    private func update() {
        guard let target, let location else { return }
        let here = location.coordinate
        let distance = CompassMath.meters(from: here, to: target)

        let wantFine = distance < fineWithin
        if wantFine != fine {
            fine = wantFine
            applyAccuracy(fine: wantFine)
            if wantFine { manager.startUpdatingHeading() } else { manager.stopUpdatingHeading() }
        }

        let moving = location.speed >= drivingSpeed && location.course >= 0
        let facing = moving ? location.course : (heading ?? lastCourse)
        let next = CompassMath.hint(
            distance: distance,
            bearing: CompassMath.bearing(from: here, to: target),
            facing: facing, wasShown: hint != nil)
        guard next != hint else { return }

        // An arrow turning is cheap to skip and the next fix repeats it; an
        // arrow appearing or going away is not.
        let appearsOrVanishes = (next == nil) != (hint == nil)
        let now = Date()
        guard appearsOrVanishes || now.timeIntervalSince(lastPush) >= minimumPushGap else { return }
        hint = next
        lastPush = now
        StopActivity.setKompass(next)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.target != nil else { return }
            self.start()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        // The newest usable fix: a negative accuracy is no fix, and a hundred
        // metres of doubt is more than the arrow's whole range of interest.
        guard let fix = locations.last(where: {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100
                && abs($0.timestamp.timeIntervalSinceNow) < 30
        }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.location = fix
            if fix.speed >= self.drivingSpeed, fix.course >= 0 { self.lastCourse = fix.course }
            self.update()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard degrees >= 0, newHeading.headingAccuracy >= 0 else { return }
        Task { @MainActor [weak self] in
            self?.heading = degrees
            self?.update()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
