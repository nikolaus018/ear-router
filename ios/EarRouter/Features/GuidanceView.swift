import AVFoundation
import CoreLocation
import MapKit
import Observation
import SwiftUI

/// Turn-by-turn guidance inside the app, on OSRM's own route — the line the
/// tour was planned and drawn with, so the way to stop 5 cannot quietly pass
/// stop 6 on a road the planner never saw. Chosen with "In der App" under
/// Mehr → Navigation; the other choices still hand the stop to a maps app.
///
/// No traffic, on purpose: OSRM knows the road network, not the jams.

struct GuidanceTarget: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let lat: Double
    let lon: Double
}

/// Where `NavigationHandoff.start` puts the stop it was asked to guide to;
/// `RootView` presents the screen when it is set.
@MainActor
@Observable
final class GuidanceCoordinator {
    static let shared = GuidanceCoordinator()
    var target: GuidanceTarget?
}

private struct GuidingInApp: ViewModifier {
    @State private var coordinator = GuidanceCoordinator.shared

    func body(content: Content) -> some View {
        @Bindable var coordinator = coordinator
        content.fullScreenCover(item: $coordinator.target) { target in
            GuidanceView(target: target)
        }
    }
}

extension View {
    func guidingInApp() -> some View { modifier(GuidingInApp()) }
}

// MARK: - Session

/// One GPS reading, with what the camera and the dead reckoning need of it.
struct GuidanceFix: Equatable {
    var coordinate: CLLocationCoordinate2D
    /// Metres per second; negative when Core Location has none.
    var speed: Double
    /// Degrees clockwise from north; negative when the van is not moving.
    var course: Double
    static func == (a: Self, b: Self) -> Bool {
        a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.speed == b.speed && a.course == b.course
    }
}

/// Where the van is drawn: on the route while it follows it, on the raw fix
/// when it has left it.
struct GuidancePuck: Equatable {
    var lat: Double
    var lon: Double
    var heading: Double
    var speed: Double
    var onRoute: Bool
}

/// One drive to one stop: fetches the route, follows the GPS along it,
/// re-routes when the van leaves it, and says the turns out loud.
///
/// Done the way Apple Maps, Google Maps and Waze do it:
/// - the position is **snapped to the route** while the van is on it;
/// - between fixes, and when the signal goes (tunnels, the Gürtel's cuttings),
///   it is **dead-reckoned** along the route at the last speed;
/// - the heading is the **road's**, not the phone's compass.
@MainActor
@Observable
final class GuidanceSession {
    enum Phase: Equatable {
        case waitingForFix, routing, guiding, arrived, failed(String)
    }

    private(set) var phase: Phase = .waitingForFix
    private(set) var route: GuidanceRoute?
    private(set) var progress: GuidanceProgress?
    private(set) var puck: GuidancePuck?
    private(set) var notice: String?
    private(set) var limits: SpeedLimitProfile?
    private(set) var cameras: SpeedCameraProfile?
    /// Smoothed, metres per second.
    private(set) var speed = 0.0
    var voiceOn = true

    let target: GuidanceTarget
    @ObservationIgnored private let location = GuidanceLocation()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var offRouteFixes = 0
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var announced = Set<String>()
    @ObservationIgnored private var lastFix: GuidanceFix?
    @ObservationIgnored private var lastFixAt = Date()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Consecutive off-the-line fixes before a re-route, and the least time
    /// between two of them.
    private static let offRouteFixesNeeded = 3
    private static let rerouteCooldown: TimeInterval = 10
    /// Silence from the GPS that dead reckoning covers, and how long the
    /// last speed is held before it is let down towards a stop. A tunnel on
    /// the Gürtel is a minute or two; beyond that the guess is worse than
    /// saying so.
    private static let reckonAfter: TimeInterval = 1.5
    private static let holdSpeedFor: TimeInterval = 40
    private static let giveUpAfter: TimeInterval = 150
    private static let tick: TimeInterval = 0.2

    init(target: GuidanceTarget) { self.target = target }

    /// The next speed camera on the route within 800 m, when warnings are on.
    var cameraAhead: (distance: Double, kmh: Int?)? {
        guard let p = progress, !p.offRoute, let hit = cameras?.next(
            step: p.stepIndex, along: p.along, within: 800)
        else { return nil }
        return (hit.distance, hit.kmh)
    }

    /// The posted limit where the van is, in km/h, when OSM has one.
    var speedLimit: Int? {
        guard let p = progress, !p.offRoute else { return nil }
        return limits?.limit(step: p.stepIndex, along: p.along)
    }

    func start() {
        location.onFix = { [weak self] fix in self?.received(fix) }
        location.onDenied = { [weak self] in
            self?.phase = .failed("Kein Zugriff auf den Standort. Erlaube ihn in den Einstellungen.")
        }
        location.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tick))
                self?.reckon()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        location.stop()
        speaker.stop()
    }

    func retry() {
        guard let lastFix else {
            phase = .waitingForFix
            return
        }
        Task { await fetchRoute(from: lastFix) }
    }

    private func received(_ fix: GuidanceFix) {
        lastFix = fix
        lastFixAt = Date()
        if fix.speed >= 0 { speed = speed == 0 ? fix.speed : speed * 0.4 + fix.speed * 0.6 }
        switch phase {
        case .waitingForFix:
            Task { await fetchRoute(from: fix) }
        case .guiding:
            follow(fix)
        case .routing, .arrived, .failed:
            break
        }
    }

    private func fetchRoute(from fix: GuidanceFix) async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        let rerouting = route != nil
        if !rerouting { phase = .routing }
        let at = (lat: fix.coordinate.latitude, lon: fix.coordinate.longitude)
        do {
            let r = try await OSRMClient.shared.guidanceRoute(
                from: at, to: (target.lat, target.lon))
            route = r
            announced = []
            offRouteFixes = 0
            lastReroute = Date()
            notice = nil
            let p = GuidanceEngine.progress(route: r, at: at)
            progress = p
            puck = GuidancePuck(
                lat: p.lat, lon: p.lon, heading: p.bearing, speed: speed, onRoute: true)
            phase = .guiding
            limits = nil
            cameras = nil
            if SpeedCameras.isEnabled {
                Task { [r] in
                    let found = await Task.detached { SpeedCameras.profile(route: r) }.value
                    if route == r { cameras = found }
                }
            }
            Task {
                let found = await SpeedLimits.fetch(for: r)
                if route == r { limits = found }
            }
        } catch is CancellationError {
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if rerouting {
                notice = "Neue Route nicht möglich – weiter auf der alten Linie."
            } else {
                phase = .failed(message)
            }
        }
    }

    private func follow(_ fix: GuidanceFix) {
        guard let route else { return }
        let at = (lat: fix.coordinate.latitude, lon: fix.coordinate.longitude)
        let p = GuidanceEngine.progress(
            route: route, at: at, after: progress?.stepIndex ?? 0)
        progress = p
        if p.arrived {
            phase = .arrived
            puck = GuidancePuck(lat: p.lat, lon: p.lon, heading: p.bearing, speed: 0, onRoute: true)
            say("Ziel erreicht")
            return
        }
        if p.offRoute {
            // Drawn where the GPS says it is, heading as it drives.
            puck = GuidancePuck(
                lat: at.lat, lon: at.lon,
                heading: fix.course >= 0 ? fix.course : (puck?.heading ?? 0),
                speed: speed, onRoute: false)
            offRouteFixes += 1
            if offRouteFixes >= Self.offRouteFixesNeeded,
               Date().timeIntervalSince(lastReroute) > Self.rerouteCooldown
            {
                notice = "Route wird neu berechnet …"
                Task { await fetchRoute(from: fix) }
            }
            return
        }
        offRouteFixes = 0
        notice = nil
        puck = GuidancePuck(
            lat: p.lat, lon: p.lon, heading: p.bearing, speed: speed, onRoute: true)
        announce(p)
    }

    /// Between fixes: keep driving along the route at the last speed.
    private func reckon() {
        guard phase == .guiding, let route, let p = progress, !p.offRoute else { return }
        let silent = Date().timeIntervalSince(lastFixAt)
        guard silent > Self.reckonAfter else { return }
        if silent > Self.giveUpAfter {
            notice = "GPS-Signal verloren."
            speed = 0
            return
        }
        if silent > Self.holdSpeedFor { speed *= 0.97 }
        notice = silent > 8 ? "Kein GPS – Position wird geschätzt." : nil
        let q = GuidanceEngine.advanced(p, on: route, by: speed * Self.tick)
        progress = q
        puck = GuidancePuck(lat: q.lat, lon: q.lon, heading: q.bearing, speed: speed, onRoute: true)
        if q.arrived {
            phase = .arrived
            say("Ziel erreicht")
        } else {
            announce(q)
        }
    }

    /// "In 250 Metern …" once, "Jetzt …" once, per manoeuvre.
    private func announce(_ p: GuidanceProgress) {
        announceCamera(p)
        guard let route, p.stepIndex + 1 < route.steps.count else { return }
        let next = route.steps[p.stepIndex + 1]
        let far = "\(p.stepIndex)-far", near = "\(p.stepIndex)-near"
        if p.metersToManeuver <= 50, !announced.contains(near) {
            announced.insert(near)
            announced.insert(far)
            say(ManeuverText.instruction(next))
        } else if p.metersToManeuver <= 300, !announced.contains(far) {
            announced.insert(far)
            say(ManeuverText.spoken(next, in: p.metersToManeuver))
        }
    }

    /// Once, at 500 m: "Radarkontrolle in 500 Metern, 50".
    private func announceCamera(_ p: GuidanceProgress) {
        guard let hit = cameras?.next(step: p.stepIndex, along: p.along, within: 500),
              !announced.contains("cam-\(hit.index)")
        else { return }
        announced.insert("cam-\(hit.index)")
        let limit = hit.kmh.map { ", erlaubt \($0)" } ?? ""
        say("Radarkontrolle in \(Int((hit.distance / 50).rounded()) * 50) Metern\(limit)")
    }

    private func say(_ text: String) {
        guard voiceOn else { return }
        speaker.speak(text)
    }
}

/// A continuous stream of GPS fixes. Separate from `LocationAuthorization`,
/// which stops after one fix on purpose: nothing else in the app tracks the
/// van. Keeps running with the screen locked or another app in front — the
/// blue pill in the status bar says so — which is what lets a phone in a
/// holder carry on talking while the driver has Mail open.
@MainActor
private final class GuidanceLocation: NSObject, CLLocationManagerDelegate {
    var onFix: ((GuidanceFix) -> Void)?
    var onDenied: (() -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: begin()
        default: onDenied?()
        }
    }

    private func begin() {
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self?.begin()
            case .denied, .restricted: self?.onDenied?()
            default: break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        // A cached fix from before the screen opened is not where the van is,
        // and a fix hundreds of metres wide is not worth snapping to a street.
        guard let fix = locations.last, abs(fix.timestamp.timeIntervalSinceNow) < 15,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 65
        else { return }
        let result = GuidanceFix(
            coordinate: fix.coordinate, speed: fix.speed,
            course: fix.courseAccuracy >= 0 && fix.speed > 1 ? fix.course : -1)
        Task { @MainActor [weak self] in self?.onFix?(result) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// German turn announcements over whatever else is playing, which they quiet
/// for the moment they are spoken.
@MainActor
private final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "de-AT")
        ?? AVSpeechSynthesisVoice(language: "de-DE")

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Screen

struct GuidanceView: View {
    let target: GuidanceTarget

    @Environment(\.dismiss) private var dismiss
    @State private var session: GuidanceSession
    @AppStorage("guidance.voice") private var voiceOn = true
    @State private var camera: MapCameraPosition = .automatic
    @State private var wasIdleDisabled = false

    /// Whether the camera is driving. A drag, pinch or twist on the map hands
    /// it back to the driver, and it returns on its own after a few seconds —
    /// or at once from the button.
    @State private var following = true
    @State private var resumeTask: Task<Void, Never>?
    /// What the camera is doing now, smoothed so it glides instead of snaps.
    @State private var camHeading = 0.0
    @State private var camDistance = 450.0
    @State private var reportedHeading = 0.0
    @State private var firstFrame = true
    @State private var remainingLine: [CLLocationCoordinate2D] = []

    private static let pitch = 58.0
    private static let tick = 0.2

    init(target: GuidanceTarget) {
        self.target = target
        _session = State(initialValue: GuidanceSession(target: target))
    }

    var body: some View {
        Map(position: $camera) {
            if !remainingLine.isEmpty {
                MapPolyline(coordinates: remainingLine).stroke(Color.routeCasing, lineWidth: 12)
                MapPolyline(coordinates: remainingLine).stroke(Color.accentColor, lineWidth: 7)
            }
            Marker(
                target.title,
                coordinate: CLLocationCoordinate2D(latitude: target.lat, longitude: target.lon))
            if let puck = session.puck {
                Annotation("", coordinate: CLLocationCoordinate2D(
                    latitude: puck.lat, longitude: puck.lon), anchor: .center
                ) {
                    puckView(puck)
                }
            }
        }
        .mapControls {}
        .onMapCameraChange(frequency: .continuous) { reportedHeading = $0.camera.heading }
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in release() })
        .simultaneousGesture(MagnifyGesture().onChanged { _ in release() })
        .simultaneousGesture(RotateGesture().onChanged { _ in release() })
        .safeAreaInset(edge: .top) { banner }
        .safeAreaInset(edge: .bottom) { footer }
        .overlay(alignment: .bottomTrailing) { recenterButton }
        .onAppear {
            wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            session.voiceOn = voiceOn
            session.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled
            resumeTask?.cancel()
            session.stop()
        }
        .onChange(of: voiceOn) { _, now in session.voiceOn = now }
        .onChange(of: session.puck) { _, _ in steerCamera() }
        .onChange(of: session.progress?.stepIndex) { _, _ in rebuildLine() }
        .onChange(of: session.route) { _, _ in rebuildLine() }
    }

    // MARK: Camera

    private func release() {
        guard session.phase == .guiding else { return }
        following = false
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { resume() }
        }
    }

    private func resume() {
        resumeTask?.cancel()
        following = true
        firstFrame = true
        steerCamera()
    }

    /// Course-up, tilted, the van in the lower third with the road ahead
    /// showing — and further out the faster it goes, closer in at a turn.
    private func steerCamera() {
        guard following, let puck = session.puck else { return }
        if firstFrame { camHeading = puck.heading }
        else if puck.speed > 0.5 || !puck.onRoute {
            camHeading += GuidanceEngine.angleDelta(from: camHeading, to: puck.heading) * 0.3
        }
        let toTurn = session.progress?.metersToManeuver ?? 1000
        var wanted = min(1100, max(320, 260 + puck.speed * 16))
        if toTurn < 150 { wanted = min(wanted, 300) }
        camDistance = firstFrame ? wanted : camDistance + (wanted - camDistance) * 0.12
        camHeading = camHeading.truncatingRemainder(dividingBy: 360)
        if camHeading < 0 { camHeading += 360 }

        // Looking ahead of the van, so it sits low on the screen.
        let ahead = camDistance * 0.28
        let rad = camHeading * .pi / 180
        let center = CLLocationCoordinate2D(
            latitude: puck.lat + cos(rad) * ahead / 110_540,
            longitude: puck.lon + sin(rad) * ahead
                / (111_320 * max(0.2, cos(puck.lat * .pi / 180))))
        let cam = MapCamera(
            centerCoordinate: center, distance: camDistance, heading: camHeading,
            pitch: Self.pitch)
        if firstFrame {
            camera = .camera(cam)
            firstFrame = false
        } else {
            withAnimation(.linear(duration: Self.tick)) { camera = .camera(cam) }
        }
    }

    private func rebuildLine() {
        guard let route = session.route else {
            remainingLine = []
            return
        }
        let from = session.progress?.stepIndex ?? 0
        remainingLine = route.steps.dropFirst(min(from, max(0, route.steps.count - 1)))
            .flatMap(\.geometry)
            .compactMap { c in
                c.count == 2 ? CLLocationCoordinate2D(latitude: c[0], longitude: c[1]) : nil
            }
    }

    // MARK: Puck

    private func puckView(_ puck: GuidancePuck) -> some View {
        // Pointing along the road, relative to how the map is turned now.
        let angle = GuidanceEngine.angleDelta(from: reportedHeading, to: puck.heading)
        return ZStack {
            Circle().fill(.white).frame(width: 40, height: 40).shadow(radius: 3)
            Image(systemName: "location.north.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .rotationEffect(.degrees(angle))
        }
        .animation(.linear(duration: Self.tick), value: angle)
    }

    @ViewBuilder
    private var recenterButton: some View {
        if !following, session.phase == .guiding {
            Button {
                resume()
            } label: {
                Label("Fortsetzen", systemImage: "location.north.line.fill")
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.trailing).padding(.bottom, 110)
        }
    }

    // MARK: Banner

    @ViewBuilder
    private var banner: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch session.phase {
            case .waitingForFix:
                Label("Standort wird gesucht …", systemImage: "location")
            case .routing:
                Label("Route wird berechnet …", systemImage: "arrow.triangle.turn.up.right.diamond")
            case .failed(let message):
                Text(message).font(.headline)
                Button("Nochmal versuchen") { session.retry() }
                    .buttonStyle(.borderedProminent)
            case .arrived:
                Label("Angekommen", systemImage: "flag.checkered").font(.title2.bold())
                Text(target.title).foregroundStyle(.secondary)
            case .guiding:
                guidingBanner
            }
            if let notice = session.notice {
                Text(notice).font(.footnote).foregroundStyle(Color.attention)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var guidingBanner: some View {
        if let route = session.route, let p = session.progress, p.stepIndex + 1 < route.steps.count {
            let next = route.steps[p.stepIndex + 1]
            HStack(spacing: 14) {
                Image(systemName: ManeuverText.symbol(next))
                    .font(.system(size: 44, weight: .bold))
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ManeuverText.distance(p.metersToManeuver)).font(.largeTitle.bold())
                    Text(ManeuverText.instruction(next)).font(.headline)
                }
            }
            if p.metersToManeuver < 600, LaneStrip.worthShowing(next.lanes) {
                LaneStrip(lanes: next.lanes).padding(.top, 6)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if session.phase == .guiding {
                if let cam = session.cameraAhead { CameraBadge(distance: cam.distance) }
                if let limit = session.speedLimit { LimitSign(kmh: limit) }
                Text("\(Int((session.speed * 3.6).rounded()))")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(
                        session.speedLimit.map { session.speed * 3.6 > Double($0) + 3 } == true
                            ? Color.red : Color.primary)
                    .frame(width: 52, height: 52)
                    .background(.thinMaterial, in: Circle())
                    .accessibilityLabel("\(Int((session.speed * 3.6).rounded())) Kilometer pro Stunde")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let p = session.progress, let route = session.route, session.phase == .guiding {
                    Text(remainingText(p, route))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                voiceOn.toggle()
            } label: {
                Image(systemName: voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(voiceOn ? "Ansagen ausschalten" : "Ansagen einschalten")
            Button(session.phase == .arrived ? "Fertig" : "Beenden") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func remainingText(_ p: GuidanceProgress, _ route: GuidanceRoute) -> String {
        let share = route.distance > 0 ? p.metersRemaining / route.distance : 0
        let minutes = max(1, Int((route.duration * share / 60).rounded()))
        return "\(minutes) min · \(ManeuverText.distance(p.metersRemaining))"
    }
}

/// The posted limit, drawn as the Austrian sign: white disc, red ring.
private struct LimitSign: View {
    let kmh: Int
    var body: some View {
        Text("\(kmh)")
            .font(.title3.bold().monospacedDigit())
            .foregroundStyle(.black)
            .frame(width: 52, height: 52)
            .background(Circle().fill(.white))
            .overlay(Circle().strokeBorder(.red, lineWidth: 5))
            .accessibilityLabel("Tempolimit \(kmh)")
    }
}

/// The lanes at the next junction, left to right, the ones the route wants
/// bright and the others dimmed.
private struct LaneStrip: View {
    let lanes: [GuidanceLane]

    static func worthShowing(_ lanes: [GuidanceLane]) -> Bool {
        lanes.count >= 2 && lanes.contains { $0.indications.contains { $0 != "none" } }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                HStack(spacing: 1) {
                    ForEach(Array(lane.indications.filter { $0 != "none" }.enumerated()), id: \.offset) { _, ind in
                        Image(systemName: Self.symbol(ind))
                    }
                }
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(lane.valid ? Color.primary : Color.secondary.opacity(0.45))
                .frame(minWidth: 30, minHeight: 34)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(lane.valid ? Color.accentColor.opacity(0.25) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
            }
        }
        .accessibilityLabel("Fahrstreifen")
    }

    static func symbol(_ indication: String) -> String {
        switch indication {
        case "uturn": "arrow.uturn.left"
        case "sharp left", "left": "arrow.turn.up.left"
        case "slight left": "arrow.up.left"
        case "sharp right", "right": "arrow.turn.up.right"
        case "slight right": "arrow.up.right"
        default: "arrow.up"
        }
    }
}

/// A speed camera ahead on the route, and how far.
private struct CameraBadge: View {
    let distance: Double
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "camera.fill").font(.footnote)
            Text(ManeuverText.distance(distance)).font(.caption2.bold().monospacedDigit())
        }
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .background(Circle().fill(Color.red))
        .accessibilityLabel("Radarkontrolle in \(Int(distance)) Metern")
    }
}
