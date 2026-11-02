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

/// One drive to one stop: fetches the route, follows the GPS along it,
/// re-routes when the van leaves it, and says the turns out loud.
@MainActor
@Observable
final class GuidanceSession {
    enum Phase: Equatable {
        case waitingForFix, routing, guiding, arrived, failed(String)
    }

    private(set) var phase: Phase = .waitingForFix
    private(set) var route: GuidanceRoute?
    private(set) var progress: GuidanceProgress?
    private(set) var notice: String?
    var voiceOn = true

    let target: GuidanceTarget
    @ObservationIgnored private let location = GuidanceLocation()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var offRouteFixes = 0
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var announced = Set<String>()
    @ObservationIgnored private var lastFix: CLLocationCoordinate2D?

    /// Consecutive off-the-line fixes before a re-route, and the least time
    /// between two of them.
    private static let offRouteFixesNeeded = 3
    private static let rerouteCooldown: TimeInterval = 10

    init(target: GuidanceTarget) { self.target = target }

    func start() {
        location.onFix = { [weak self] fix in self?.received(fix) }
        location.onDenied = { [weak self] in
            self?.phase = .failed("Kein Zugriff auf den Standort. Erlaube ihn in den Einstellungen.")
        }
        location.start()
    }

    func stop() {
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

    private func received(_ fix: CLLocationCoordinate2D) {
        lastFix = fix
        switch phase {
        case .waitingForFix:
            Task { await fetchRoute(from: fix) }
        case .guiding:
            follow(fix)
        case .routing, .arrived, .failed:
            break
        }
    }

    private func fetchRoute(from fix: CLLocationCoordinate2D) async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        let rerouting = route != nil
        if !rerouting { phase = .routing }
        do {
            let r = try await OSRMClient.shared.guidanceRoute(
                from: (fix.latitude, fix.longitude), to: (target.lat, target.lon))
            route = r
            announced = []
            offRouteFixes = 0
            lastReroute = Date()
            notice = nil
            progress = GuidanceEngine.progress(route: r, at: (fix.latitude, fix.longitude))
            phase = .guiding
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

    private func follow(_ fix: CLLocationCoordinate2D) {
        guard let route else { return }
        let p = GuidanceEngine.progress(
            route: route, at: (fix.latitude, fix.longitude), after: progress?.stepIndex ?? 0)
        progress = p
        if p.arrived {
            phase = .arrived
            say("Ziel erreicht")
            return
        }
        if p.offRoute {
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
        announce(p)
    }

    /// "In 250 Metern …" once, "Jetzt …" once, per manoeuvre.
    private func announce(_ p: GuidanceProgress) {
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

    private func say(_ text: String) {
        guard voiceOn else { return }
        speaker.speak(text)
    }
}

/// A continuous stream of GPS fixes. Separate from `LocationAuthorization`,
/// which stops after one fix on purpose: nothing else in the app tracks the
/// van.
@MainActor
private final class GuidanceLocation: NSObject, CLLocationManagerDelegate {
    var onFix: ((CLLocationCoordinate2D) -> Void)?
    var onDenied: (() -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 5
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: onDenied?()
        }
    }

    func stop() { manager.stopUpdatingLocation() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self?.manager.startUpdatingLocation()
            case .denied, .restricted: self?.onDenied?()
            default: break
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        // A cached fix from before the screen opened is not where the van is.
        guard let fix = locations.last, abs(fix.timestamp.timeIntervalSinceNow) < 15,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy < 100
        else { return }
        let coordinate = fix.coordinate
        Task { @MainActor [weak self] in self?.onFix?(coordinate) }
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
    @State private var camera: MapCameraPosition = .userLocation(
        followsHeading: true, fallback: .automatic)
    @State private var wasIdleDisabled = false

    init(target: GuidanceTarget) {
        self.target = target
        _session = State(initialValue: GuidanceSession(target: target))
    }

    var body: some View {
        Map(position: $camera) {
            if let route = session.route {
                let line = route.geometry.compactMap { c -> CLLocationCoordinate2D? in
                    c.count == 2 ? CLLocationCoordinate2D(latitude: c[0], longitude: c[1]) : nil
                }
                MapPolyline(coordinates: line).stroke(Color.routeCasing, lineWidth: 10)
                MapPolyline(coordinates: line).stroke(Color.accentColor, lineWidth: 6)
            }
            Marker(
                target.title,
                coordinate: CLLocationCoordinate2D(latitude: target.lat, longitude: target.lon))
            UserAnnotation()
        }
        .mapControls { MapUserLocationButton() }
        .safeAreaInset(edge: .top) { banner }
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear {
            wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            session.voiceOn = voiceOn
            session.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled
            session.stop()
        }
        .onChange(of: voiceOn) { _, now in session.voiceOn = now }
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
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let p = session.progress, session.phase == .guiding {
                    Text(ManeuverText.distance(p.metersRemaining) + " bis zum Ziel")
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
}
