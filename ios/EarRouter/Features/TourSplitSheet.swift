import SwiftUI
import SwiftData
import MapKit

/// Splits one Zusteller-Portal tour between several drivers, by drawing round
/// their stops on a map.
///
/// Deliberately not a tour: nothing here is saved, no route is created, and
/// closing the sheet forgets all of it. The question it answers is "who takes
/// which doors today", said out loud in the depot in a minute — and the answer
/// is a list of names each driver then loads for themselves.
///
/// One person at a time. Whatever is circled goes to the person whose turn it
/// is, and stays greyed out under everyone after them, so the map always shows
/// what is still to hand out.
struct TourSplitSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var tours: [GourmetPortal.Tour] = []
    @State private var selectedTourID: Int?
    @State private var loadingTours = false
    @State private var people = 2

    @State private var busy: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var error: AppError?
    @State private var split: SplitState?
    /// Read once, not in `body`: every redraw of this screen was a Keychain
    /// query, and signing in here has to be able to flip it.
    @State private var signedIn = GourmetCredentialsStore.load() != nil

    var body: some View {
        NavigationStack {
            Group {
                if signedIn {
                    form
                } else {
                    // Right here, rather than a pointer to the import screen
                    // in another tab: splitting a tour is often the first
                    // thing anybody does with the portal on this phone.
                    GourmetLoginForm {
                        signedIn = true
                        Task { await loadTours() }
                    }
                }
            }
            .navigationTitle("Tour aufteilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if busy != nil {
                        Button("Stoppen") { loadTask?.cancel() }
                    } else {
                        Button("Schließen") { dismiss() }
                    }
                }
            }
            .floatingBanner {
                if let busy {
                    BusyBanner(text: busy)
                }
            }
            .animation(.snappy, value: busy)
            .errorAlert($error)
            .interactiveDismissDisabled(busy != nil)
            .task {
                if signedIn { await loadTours() }
            }
            .onChange(of: date) { _, _ in reconcileSelection() }
        }
        // Full screen, not a sheet: a sheet's own swipe-to-dismiss claims any
        // downward stroke, which cancelled the circle half-way round and left
        // nothing picked.
        .fullScreenCover(item: $split) { state in
            TourSplitMapView(state: state) {
                // A share became a tour: this whole screen steps out of the
                // way so the driver lands on it under Touren.
                //
                // `dismiss()` alone, and it has to be alone: clearing `split`
                // first starts the cover's own dismissal, and the sheet's
                // dismiss arriving mid-animation was swallowed — the map went
                // away and the driver was left sitting on the setup form.
                // Dismissing the sheet takes the cover with it anyway.
                dismiss()
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                DatePicker("Datum", selection: $date, displayedComponents: .date)
                if loadingTours {
                    HStack {
                        ProgressView()
                        Text("Touren werden geladen …").foregroundStyle(.secondary)
                    }
                } else if candidateTours.isEmpty {
                    Text("Keine Tour für diesen Tag gefunden.").foregroundStyle(.secondary)
                } else {
                    Picker("Tour", selection: $selectedTourID) {
                        Text("Bitte wählen").tag(Int?.none)
                        ForEach(candidateTours) { tour in
                            Text(tour.name).tag(Int?.some(tour.id))
                        }
                    }
                }
            }
            Section {
                Stepper("Personen: \(people)", value: $people, in: 2...SplitState.maxPeople)
            } footer: {
                Text("Wird nicht gespeichert — nur zum schnellen Aufteilen.")
            }
            Section {
                Button("Auf der Karte aufteilen") { loadTask = Task { await load() } }
                    .disabled(selectedTourID == nil || busy != nil)
            }
        }
    }

    private var candidateTours: [GourmetPortal.Tour] {
        tours.filter { GourmetPortal.runs($0, on: date) }
    }

    private func reconcileSelection() {
        let candidates = candidateTours
        if let id = selectedTourID, candidates.contains(where: { $0.id == id }) { return }
        selectedTourID = candidates.count == 1 ? candidates[0].id : nil
    }

    private func loadTours() async {
        guard let credentials = GourmetCredentialsStore.load() else { return }
        loadingTours = true
        defer { loadingTours = false }
        do {
            let token = try await GourmetPortal.login(credentials)
            tours = try await GourmetPortal.tours(token: token)
            reconcileSelection()
        } catch is CancellationError {
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Tourenliste konnte nicht geladen werden.")
        }
    }

    /// The list data only — names and addresses are all a split needs, so the
    /// slow one-request-per-stop Paket fetch is skipped entirely. Each address
    /// is then placed through the same geocoder a tour uses, which serves the
    /// driver's regular doors straight from its cache.
    private func load() async {
        guard let selectedTourID, let tour = tours.first(where: { $0.id == selectedTourID }),
            let credentials = GourmetCredentialsStore.load()
        else { return }
        busy = "Anmelden …"
        defer { busy = nil }
        do {
            let (token, deliveries) = try await GourmetPortal.matchingDeliveries(
                tour: tour, date: date, credentials: credentials
            ) { progress in
                Task { @MainActor in busy = progress }
            }
            guard !deliveries.isEmpty else {
                error = AppError.message(
                    "Für „\(tour.name)“ wurden an diesem Tag keine offenen Lieferungen gefunden.")
                return
            }
            let stops = try await PortalPlacement.place(deliveries) { done, total in
                Task { @MainActor in busy = "Adresse \(done) von \(total) wird gesucht …" }
            }
            // One table call, for the fair split and for every person's
            // "ca. 4 h 05". Never fails: without OSRM it is the straight line.
            busy = "Fahrzeiten werden berechnet …"
            let durations = await SplitDurations.load(for: stops)
            try Task.checkCancellation()
            // The token and the deliveries are kept: a share that becomes a
            // tour needs its Paket and phone numbers, and those are one
            // detail call per stop away.
            split = SplitState(
                tourName: tour.name, tourID: tour.id, date: date, people: people, stops: stops,
                token: token,
                deliveries: Dictionary(deliveries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                durations: durations)
        } catch is CancellationError {
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Lieferungen konnten nicht geladen werden.")
        }
    }
}

// MARK: - State

struct SplitStop: Identifiable {
    /// The portal's delivery id, which is also how the Paket and the phone
    /// number are fetched later if this stop becomes a real tour.
    let id: Int
    let name: String
    let address: String
    let plz: String
    let coordinate: CLLocationCoordinate2D?
    /// The geocoder found this very door, not only the street — so another
    /// stop at the same point is the same building. See `fairSplitInput`.
    var exactPoint = false

    /// The stop as an import entry, with only what the tour list carried.
    /// Used when the detail fetch is not available or did not answer.
    var plainEntry: CustomerJSON {
        CustomerJSON(kunde: name, strasse: address, plz: plz, paket: nil, notiz: nil)
    }
}

/// Everything a split is, held only for as long as the screen is open.
struct SplitState: Identifiable {
    static let maxPeople = 8
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red]

    let id = UUID()
    let tourName: String
    /// The portal's id for the tour, so a share that becomes a route can say
    /// which tour it came from — see `PortalTourLink`.
    let tourID: Int?
    let date: Date
    let people: Int
    let stops: [SplitStop]
    /// The login this split was loaded with, kept so a share can be turned
    /// into a tour without signing in again.
    let token: String?
    /// The delivery behind each stop, for that same detail fetch.
    let deliveries: [Int: GourmetPortal.Delivery]
    /// The drive between every two stops, for the fair split and the day
    /// each person has. `nil` until it is known.
    var durations: SplitDurations?
    /// Delivery id → person index. A stop with no entry is still free.
    private(set) var owner: [Int: Int] = [:]
    private var history: [[Int: Int]] = []

    init(
        tourName: String, tourID: Int? = nil, date: Date = Date(), people: Int,
        stops: [SplitStop], token: String? = nil,
        deliveries: [Int: GourmetPortal.Delivery] = [:], durations: SplitDurations? = nil
    ) {
        self.tourName = tourName
        self.tourID = tourID
        self.date = date
        self.people = people
        self.stops = stops
        self.token = token
        self.deliveries = deliveries
        self.durations = durations
    }

    var canUndo: Bool { !history.isEmpty }
    /// Whether the fair split has anything to share out.
    var hasFreePlacedStops: Bool {
        stops.contains { $0.coordinate != nil && owner[$0.id] == nil }
    }
    var freeCount: Int { stops.count - owner.count }

    func owner(of stop: SplitStop) -> Int? { owner[stop.id] }

    func stops(of person: Int?) -> [SplitStop] {
        stops.filter { owner[$0.id] == person }
    }

    /// Gives every free stop among `ids` to `person`. Stops that already
    /// belong to someone stay theirs. Returns how many were added.
    @discardableResult
    mutating func claim(_ ids: [Int], for person: Int) -> Int {
        let free = ids.filter { owner[$0] == nil }
        guard !free.isEmpty else { return 0 }
        history.append(owner)
        for id in free { owner[id] = person }
        return free.count
    }

    /// A tap: one of `person`'s stops is freed again, and any other — free
    /// or someone else's — becomes theirs. The precise way to fix up what a
    /// circle caught.
    mutating func toggle(_ id: Int, for person: Int) {
        history.append(owner)
        owner[id] = owner[id] == person ? nil : person
    }

    /// The fair split's answer, as one step "Rückgängig" takes back whole.
    /// Returns how many stops changed hands.
    @discardableResult
    mutating func assign(_ owners: [Int: Int]) -> Int {
        let changed = owners.filter { owner[$0.key] != $0.value && (0..<people).contains($0.value) }
        guard !changed.isEmpty else { return 0 }
        history.append(owner)
        for (id, person) in changed { owner[id] = person }
        return changed.count
    }

    mutating func undo() {
        if let last = history.popLast() { owner = last }
    }

    mutating func reset() {
        guard !owner.isEmpty else { return }
        history.append(owner)
        owner = [:]
    }

    // MARK: Becoming a tour

    /// What one person's share looks like as import entries.
    ///
    /// The Paket and the phone number are on the portal's *detail* call, one
    /// request per stop — deliberately skipped while splitting, because a
    /// split needs neither and thirty of them is a minute nobody is waiting
    /// for. They are fetched here instead, for one share, at the moment that
    /// share is about to become a tour somebody drives: without the Paket the
    /// Ladeliste is empty and "Anrufen" has no number.
    ///
    /// A fetch that fails falls back to the name and address already on
    /// screen. A tour missing its Paket is worth having; a tour that could not
    /// be created at all is not.
    func entries(
        for person: Int, onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> [CustomerJSON] {
        let mine = stops(of: person)
        let wanted = mine.compactMap { deliveries[$0.id] }
        guard let token, !wanted.isEmpty else { return mine.map(\.plainEntry) }
        do {
            return try await GourmetPortal.fetchDetails(
                for: wanted, token: token, onProgress: onProgress)
        } catch {
            return mine.map(\.plainEntry)
        }
    }

    /// "VM 4 DO Vormittag · P2", with the date added only when a tour of that
    /// name is already open — the same rule the portal import follows.
    ///
    /// "· P2" rather than "– Person 2": the tour's own name is already most of
    /// a large title, and the screens a driver reads it on — Touren, Jetzt,
    /// the Karte — cut what does not fit. Four characters say which share this
    /// is; eleven push the tour's own name off the screen.
    func routeName(for person: Int, taken: Set<String> = []) -> String {
        let base = "\(tourName.trimmed) · P\(person + 1)"
        guard taken.contains(base) else { return base }
        return "\(base) – \(Self.dayFormatter.string(from: date))"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_AT")
        f.dateFormat = "dd.MM."
        return f
    }()

    // MARK: Sharing

    func shareText(for person: Int) -> String {
        let mine = stops(of: person)
        return (["Person \(person + 1) (\(mine.count))"]
            + mine.map { "• \($0.name) – \($0.address)" })
            .joined(separator: "\n")
    }

    var shareText: String {
        var sections = (0..<people).map(shareText(for:))
        let rest = stops(of: nil)
        if !rest.isEmpty {
            sections.append(
                (["Nicht zugeteilt (\(rest.count))"] + rest.map { "• \($0.name) – \($0.address)" })
                    .joined(separator: "\n"))
        }
        return "\(tourName)\n\n" + sections.joined(separator: "\n\n")
    }
}

/// What a finger drew round, in screen points.
enum Lasso {
    /// Ray casting, with the shape closed straight back to where it started.
    static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Inside, or touched by the line itself. A circle drawn tight round a pin
    /// usually clips the pin's edge, and the driver meant it.
    static func catches(_ point: CGPoint, in polygon: [CGPoint], radius: CGFloat) -> Bool {
        if contains(point, in: polygon) { return true }
        guard polygon.count >= 2 else { return false }
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if distance(from: point, toSegment: a, b) <= radius { return true }
        }
        return false
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Map

/// "Put the camera on this stop" — the sequence makes asking twice a change.
private struct SplitFocus: Equatable {
    let id: Int
    let sequence: Int
}

/// The splitting screen: a map with a sheet over it, the way Karten shows a
/// place. Everything that used to float over the map in glass — the tool
/// buttons, the hint pill, the person chips — is back where iOS puts it: the
/// navigation bar for the screen's own actions, the sheet for the current
/// person and their stops.
private struct TourSplitMapView: View {
    @State var state: SplitState
    /// Called after a share has become a tour and the driver asked to open
    /// it: the whole splitting screen steps out of the way.
    var onOpenedTour: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var person = 0
    @State private var detent: PresentationDetent = SplitPanel.collapsed
    @State private var fitToken = 0
    @State private var focus: SplitFocus?
    @State private var confirmingClose = false
    @State private var tapTick = 0
    @State private var lassoTick = 0
    /// Asks the panel for the fair split: the panel is the screen in front,
    /// and the one that can show it working and what it came to.
    @State private var fairRequest = 0

    var body: some View {
        NavigationStack {
            SplitMapView(
                stops: state.stops, owner: state.owner, person: person,
                fitToken: fitToken, focus: focus,
                onTap: { id in
                    withAnimation(.snappy) { state.toggle(id, for: person) }
                    tapTick += 1
                },
                onLasso: { ids in
                    let added = withAnimation(.snappy) { state.claim(ids, for: person) }
                    if added > 0 { lassoTick += 1 }
                }
            )
            .ignoresSafeArea()
            .navigationTitle(state.tourName)
            .navigationSubtitle(subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") {
                        // Nothing here is saved, so a split that is half done
                        // is not closed on one stray tap.
                        if state.owner.isEmpty { dismiss() } else { confirmingClose = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Fair aufteilen", systemImage: "wand.and.stars") {
                            fairRequest += 1
                        }
                        .disabled(!state.hasFreePlacedStops)
                        Button("Rückgängig", systemImage: "arrow.uturn.backward") {
                            withAnimation(.snappy) { state.undo() }
                        }
                        .disabled(!state.canUndo)
                        Button("Rest an Person \(person + 1)", systemImage: "tray.and.arrow.down") {
                            let free = state.stops(of: nil).map(\.id)
                            withAnimation(.snappy) { _ = state.claim(free, for: person) }
                        }
                        .disabled(state.freeCount == 0)
                        Divider()
                        Button("Alle Stopps zeigen", systemImage: "arrow.down.left.and.arrow.up.right") {
                            fitToken += 1
                        }
                        Button("Alles zurücksetzen", systemImage: "arrow.counterclockwise", role: .destructive) {
                            withAnimation(.snappy) { state.reset() }
                        }
                        .disabled(state.owner.isEmpty)
                    } label: {
                        Label("Mehr", systemImage: "ellipsis")
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: tapTick)
            .sensoryFeedback(.impact(weight: .medium), trigger: lassoTick)
        }
        .sheet(isPresented: .constant(true)) {
            SplitPanel(
                state: $state, person: $person, detent: $detent,
                confirmingClose: $confirmingClose,
                fairRequest: fairRequest,
                onClose: { dismiss() },
                onOpenedTour: onOpenedTour,
                onFocus: { stop in
                    focus = SplitFocus(id: stop.id, sequence: (focus?.sequence ?? 0) + 1)
                }
            )
            .presentationDetents([SplitPanel.collapsed, .medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
    }

    /// Under the tour's name, where every other screen in this app puts the
    /// line saying how far along it is.
    private var subtitle: String {
        state.freeCount == 0
            ? "Alle Stopps verteilt"
            : "\(state.freeCount) von \(state.stops.count) noch frei"
    }
}

/// MapKit's own map view underneath, because SwiftUI's `Map` cannot share a
/// screen between drawing and moving: an overlay that catches a finger for
/// the lasso catches every finger. Here one finger draws, two fingers move
/// and zoom, and a pin takes its own taps — no mode to be in the wrong one of.
private struct SplitMapView: UIViewRepresentable {
    let stops: [SplitStop]
    let owner: [Int: Int]
    let person: Int
    let fitToken: Int
    let focus: SplitFocus?
    var onTap: (Int) -> Void
    var onLasso: ([Int]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SplitMKMapView {
        let coordinator = context.coordinator
        coordinator.parent = self

        let map = SplitMKMapView()
        map.delegate = coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsUserLocation = true
        map.showsCompass = false
        map.isPitchEnabled = false
        map.register(SplitPinView.self, forAnnotationViewWithReuseIdentifier: SplitPinView.reuseID)
        coordinator.map = map

        let lasso = UIPanGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handleLasso(_:)))
        lasso.maximumNumberOfTouches = 1
        map.addGestureRecognizer(lasso)
        coordinator.lassoRecognizer = lasso

        let overlay = UIView()
        overlay.isUserInteractionEnabled = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: map.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: map.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: map.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: map.bottomAnchor),
        ])
        coordinator.lassoLayer.lineWidth = 3
        coordinator.lassoLayer.lineJoin = .round
        coordinator.lassoLayer.lineCap = .round
        overlay.layer.addSublayer(coordinator.lassoLayer)

        let annotations = stops.compactMap { stop in
            stop.coordinate.map { SplitAnnotation(id: stop.id, name: stop.name, coordinate: $0) }
        }
        coordinator.annotations = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })
        coordinator.offsets = Self.fanOut(annotations)
        map.addAnnotations(annotations)

        map.onFirstLayout = { [weak coordinator] in coordinator?.fit(animated: false) }
        coordinator.lastFit = fitToken
        return map
    }

    /// Customers at the very same point — two flats in one Gemeindebau — are
    /// spread into a small ring, so each has a pin of its own to tap instead
    /// of one hiding under the other.
    static func fanOut(_ annotations: [SplitAnnotation]) -> [Int: CGPoint] {
        var groups: [String: [SplitAnnotation]] = [:]
        for annotation in annotations {
            let key = String(
                format: "%.5f,%.5f", annotation.coordinate.latitude, annotation.coordinate.longitude)
            groups[key, default: []].append(annotation)
        }
        var out: [Int: CGPoint] = [:]
        for group in groups.values where group.count > 1 {
            let radius = SplitPinView.disc * 0.6 + CGFloat(group.count) * 2
            for (i, annotation) in group.sorted(by: { $0.id < $1.id }).enumerated() {
                let angle = 2 * Double.pi * Double(i) / Double(group.count) - Double.pi / 2
                out[annotation.id] = CGPoint(
                    x: radius * CGFloat(cos(angle)), y: radius * CGFloat(sin(angle)))
            }
        }
        return out
    }

    func updateUIView(_ map: SplitMKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.armLasso()
        coordinator.refreshPins()
        if fitToken != coordinator.lastFit {
            coordinator.lastFit = fitToken
            coordinator.fit(animated: true)
        }
        if let focus, focus != coordinator.lastFocus {
            coordinator.lastFocus = focus
            coordinator.zoom(to: focus.id)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SplitMapView!
        weak var map: MKMapView?
        var annotations: [Int: SplitAnnotation] = [:]
        /// Screen offsets for pins that share a point — see `fanOut`.
        var offsets: [Int: CGPoint] = [:]
        var lassoRecognizer: UIPanGestureRecognizer!
        let lassoLayer = CAShapeLayer()
        var lastFit = 0
        var lastFocus: SplitFocus?
        private var armed = false
        private var stroke: [CGPoint] = []
        private var pending: Set<Int> = []

        private var color: UIColor { UIColor(SplitState.colors[parent.person]) }

        // MARK: Drawing

        /// One finger draws, two move the map — so the map's own panning is
        /// handed to two fingers and the single finger is left free for the
        /// lasso. There is no mode to be in the wrong one of, which is why
        /// there is no control for it either.
        func armLasso() {
            guard !armed, let map else { return }
            armed = true
            lassoRecognizer.isEnabled = true
            for recognizer in Self.recognizers(in: map) where recognizer !== lassoRecognizer {
                if let pan = recognizer as? UIPanGestureRecognizer, pan.maximumNumberOfTouches > 1 {
                    pan.minimumNumberOfTouches = 2
                }
            }
        }

        private static func recognizers(in view: UIView) -> [UIGestureRecognizer] {
            (view.gestureRecognizers ?? []) + view.subviews.flatMap(recognizers(in:))
        }

        @objc func handleLasso(_ recognizer: UIPanGestureRecognizer) {
            guard let map else { return }
            let point = recognizer.location(in: map)
            switch recognizer.state {
            case .began:
                // The recogniser only begins once the finger has moved, so
                // the stroke starts where the finger first came down.
                let moved = recognizer.translation(in: map)
                stroke = [CGPoint(x: point.x - moved.x, y: point.y - moved.y), point]
                // The last stroke may still be fading out; without this the
                // new one inherits that animation and draws itself away.
                lassoLayer.removeAnimation(forKey: "fade")
                lassoLayer.opacity = 1
                redraw()
            case .changed:
                stroke.append(point)
                redraw()
                updatePending()
            case .ended:
                stroke.append(point)
                let caught = caughtStops()
                endStroke()
                if !caught.isEmpty { parent.onLasso(caught) }
            default:
                endStroke()
            }
        }

        private func redraw() {
            let path = UIBezierPath()
            guard let first = stroke.first else { return }
            path.move(to: first)
            for point in stroke.dropFirst() { path.addLine(to: point) }
            lassoLayer.strokeColor = color.cgColor
            lassoLayer.fillColor = color.withAlphaComponent(0.14).cgColor
            lassoLayer.path = path.cgPath
        }

        /// Only free stops: a circle drawn across someone else's never takes
        /// theirs. Tapping a pin does — that is the deliberate way.
        private func caughtStops() -> [Int] {
            guard let map, stroke.count > 2 else { return [] }
            // The stroke's own box first: this runs on every touch move, and
            // measuring every stop against every segment of a long circle is
            // work almost all of them lose on the first comparison. A tour's
            // stops are spread over a district; the circle covers a corner of
            // it.
            let reach = SplitPinView.disc / 2
            var box = CGRect(origin: stroke[0], size: .zero)
            for point in stroke.dropFirst() {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            box = box.insetBy(dx: -reach, dy: -reach)

            return annotations.values.compactMap { annotation in
                guard parent.owner[annotation.id] == nil else { return nil }
                var point = map.convert(annotation.coordinate, toPointTo: map)
                if let offset = offsets[annotation.id] {
                    point.x += offset.x
                    point.y += offset.y
                }
                guard box.contains(point) else { return nil }
                return Lasso.catches(point, in: stroke, radius: reach) ? annotation.id : nil
            }
        }

        private func updatePending() {
            let now = Set(caughtStops())
            guard now != pending else { return }
            let changed = now.symmetricDifference(pending)
            pending = now
            for id in changed { configure(id) }
        }

        private func endStroke() {
            stroke = []
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.2
            lassoLayer.add(fade, forKey: "fade")
            lassoLayer.opacity = 0
            let wasPending = pending
            pending = []
            for id in wasPending { configure(id) }
        }

        // MARK: Pins

        func refreshPins() {
            for id in annotations.keys { configure(id) }
        }

        private func configure(_ id: Int) {
            guard let map, let annotation = annotations[id],
                let view = map.view(for: annotation) as? SplitPinView
            else { return }
            view.configure(
                owner: parent.owner[id], person: parent.person, pending: pending.contains(id))
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? SplitAnnotation else { return nil }
            let view =
                mapView.dequeueReusableAnnotationView(
                    withIdentifier: SplitPinView.reuseID, for: annotation) as! SplitPinView
            view.onTap = { [weak self] in self?.parent.onTap(annotation.id) }
            view.centerOffset = offsets[annotation.id] ?? .zero
            view.configure(
                owner: parent.owner[annotation.id], person: parent.person,
                pending: pending.contains(annotation.id), animated: false)
            return view
        }

        // MARK: Camera

        /// Every pin, clear of the title bar above and the panel below.
        func fit(animated: Bool) {
            guard let map, !annotations.isEmpty else { return }
            var rect = MKMapRect.null
            for annotation in annotations.values {
                let point = MKMapPoint(annotation.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            let minimum = 1_500.0
            if rect.size.width < minimum {
                rect = rect.insetBy(dx: -(minimum - rect.size.width) / 2, dy: 0)
            }
            if rect.size.height < minimum {
                rect = rect.insetBy(dx: 0, dy: -(minimum - rect.size.height) / 2)
            }
            let insets = map.safeAreaInsets
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(
                    top: insets.top + 70, left: 36, bottom: 190, right: 76),
                animated: animated)
        }

        func zoom(to id: Int) {
            guard let map, let annotation = annotations[id] else { return }
            let region = MKCoordinateRegion(
                center: annotation.coordinate, latitudinalMeters: 700, longitudinalMeters: 700)
            let rect = MKMapRect(region)
            // Into the top half, which the panel never covers however far it
            // has been pulled up.
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(
                    top: map.safeAreaInsets.top + 60, left: 0, bottom: map.bounds.height * 0.5,
                    right: 0),
                animated: true)
            (map.view(for: annotation) as? SplitPinView)?.pulse()
        }
    }
}

extension MKMapRect {
    fileprivate init(_ region: MKCoordinateRegion) {
        let a = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude + region.span.latitudeDelta / 2,
                longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let b = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2,
                longitude: region.center.longitude + region.span.longitudeDelta / 2))
        self.init(
            x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

private final class SplitMKMapView: MKMapView {
    var onFirstLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, let first = onFirstLayout else { return }
        onFirstLayout = nil
        // Through a `Task` on the main actor rather than `DispatchQueue`: the
        // closure comes from a `@MainActor` view, and handing a non-`Sendable`
        // function to GCD is exactly the hole Swift 6 concurrency checking is
        // there to close.
        Task { @MainActor in first() }
    }
}

private final class SplitAnnotation: NSObject, MKAnnotation {
    let id: Int
    let name: String
    let coordinate: CLLocationCoordinate2D
    var title: String? { name }

    init(id: Int, name: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
}

/// A stop on the split map. The visible disc is small, so neighbours stay
/// apart; the view around it is a full fingertip, so a tap does not miss.
private final class SplitPinView: MKAnnotationView {
    static let reuseID = "split-pin"
    static let disc: CGFloat = 26
    private static let touch: CGFloat = 40

    var onTap: (() -> Void)?

    private let circle = UIView()
    private let number = UILabel()
    private let dot = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.touch, height: Self.touch)
        backgroundColor = .clear
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle

        circle.frame = CGRect(
            x: (Self.touch - Self.disc) / 2, y: (Self.touch - Self.disc) / 2,
            width: Self.disc, height: Self.disc)
        circle.layer.cornerRadius = Self.disc / 2
        circle.layer.borderColor = UIColor.white.cgColor
        circle.layer.borderWidth = 2
        circle.layer.shadowColor = UIColor.black.cgColor
        circle.layer.shadowOpacity = 0.3
        circle.layer.shadowRadius = 2
        circle.layer.shadowOffset = CGSize(width: 0, height: 1)
        circle.isUserInteractionEnabled = false
        addSubview(circle)

        number.frame = circle.bounds
        number.textAlignment = .center
        number.font = .systemFont(ofSize: 12, weight: .bold).rounded
        number.textColor = .white
        circle.addSubview(number)

        dot.frame = CGRect(x: Self.disc / 2 - 4, y: Self.disc / 2 - 4, width: 8, height: 8)
        dot.layer.cornerRadius = 4
        dot.backgroundColor = .systemGray2
        circle.addSubview(dot)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }

    @objc private func tapped() { onTap?() }

    func configure(owner: Int?, person: Int, pending: Bool, animated: Bool = true) {
        let mine = owner == person
        let current = UIColor(SplitState.colors[person])
        accessibilityLabel = (annotation as? SplitAnnotation)?.name
        accessibilityValue = owner.map { "Person \($0 + 1)" } ?? "Frei"

        let apply = { [self] in
            if let owner {
                circle.backgroundColor = UIColor(SplitState.colors[owner])
                circle.layer.borderColor = UIColor.white.cgColor
                number.text = "\(owner + 1)"
                dot.alpha = 0
                circle.alpha = mine ? 1 : 0.4
                circle.transform = mine ? CGAffineTransform(scaleX: 1.1, y: 1.1)
                    : CGAffineTransform(scaleX: 0.85, y: 0.85)
            } else if pending {
                circle.backgroundColor = current.withAlphaComponent(0.35)
                circle.layer.borderColor = current.cgColor
                number.text = nil
                dot.alpha = 0
                circle.alpha = 1
                circle.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
            } else {
                circle.backgroundColor = .white
                circle.layer.borderColor = UIColor.white.cgColor
                number.text = nil
                dot.alpha = 1
                circle.alpha = 1
                circle.transform = .identity
            }
        }
        circle.layer.borderWidth = pending && owner == nil ? 3 : 2
        zPriority = mine ? .max : owner == nil ? .defaultSelected : .min
        if animated {
            UIView.animate(
                withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.7,
                initialSpringVelocity: 0, options: [.allowUserInteraction], animations: apply)
        } else {
            apply()
        }
    }

    func pulse() {
        UIView.animate(withDuration: 0.15, animations: {
            self.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        }) { _ in
            UIView.animate(
                withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.5,
                initialSpringVelocity: 0, options: [], animations: { self.transform = .identity })
        }
    }
}

extension UIFont {
    fileprivate var rounded: UIFont {
        fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

// MARK: - The sheet over the map

/// What Karten puts in its sheet: who this is about, and the list belonging to
/// them. The mode switch is a segmented control rather than a floating tool
/// button, which also says out loud what the two gestures do; the person is a
/// pop-up button, which holds eight people as comfortably as two.
private struct SplitPanel: View {
    /// Tall enough for the person, the button and two whole rows — at 210 the
    /// list was a sliver with a row sliced through the middle by the button
    /// pinned under it, which reads as a layout that broke rather than as a
    /// list that continues.
    static let collapsed = PresentationDetent.height(290)

    @Binding var state: SplitState
    @Binding var person: Int
    @Binding var detent: PresentationDetent
    /// Asked from here rather than from the map underneath: this sheet is the
    /// screen in front, and only the one in front can present anything.
    @Binding var confirmingClose: Bool
    /// Bumped by "Fair aufteilen" in the map's menu.
    var fairRequest: Int
    var onClose: () -> Void
    var onOpenedTour: () -> Void
    var onFocus: (SplitStop) -> Void

    @State private var showingOverview = false
    @State private var busy: String?
    @State private var fairSummary: String?

    private var color: Color { SplitState.colors[person] }
    private var mine: [SplitStop] { state.stops(of: person) }

    var body: some View {
        // Once per redraw: every person's day is a short route worked out.
        let days = state.days()
        NavigationStack {
            List {
                Section {
                    if mine.isEmpty {
                        Text("Noch keine Stopps — einkreisen oder antippen.")
                            .foregroundStyle(.secondary)
                        if state.hasFreePlacedStops {
                            Button {
                                startFairSplit()
                            } label: {
                                Label("Automatisch fair aufteilen", systemImage: "wand.and.stars")
                            }
                            .disabled(busy != nil)
                        }
                    }
                    ForEach(mine) { stop in
                        Button {
                            if stop.coordinate != nil { onFocus(stop) }
                        } label: {
                            StopLine(stop: stop).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Entfernen", role: .destructive) {
                                withAnimation { state.toggle(stop.id, for: person) }
                            }
                        }
                    }
                }

                let unplaced = state.stops.filter { $0.coordinate == nil }
                if !unplaced.isEmpty {
                    Section {
                        ForEach(unplaced) { stop in
                            unplacedRow(stop)
                        }
                    } header: {
                        Text("Nicht auf der Karte")
                    } footer: {
                        Text("Adresse nicht gefunden — hier antippen, um sie zuzuteilen.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The person and the way out of this screen are pinned above and
            // below the list rather than scrolling away inside it: at the
            // smallest detent the list is two rows tall, and both of them are
            // needed from there.
            .safeAreaInset(edge: .top, spacing: 0) { personBar(days: days) }
            .safeAreaInset(edge: .bottom, spacing: 0) { finishBar }
            .floatingBanner {
                if let busy {
                    BusyBanner(text: busy)
                }
            }
            .animation(.snappy, value: busy)
            .navigationTitle("Aufteilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingOverview) {
                SplitOverview(state: $state, onOpenedTour: onOpenedTour)
            }
        }
        .onChange(of: showingOverview) { _, open in
            // The overview is a list of everyone's share; it wants the room.
            if open { detent = .large }
        }
        .onChange(of: fairRequest) { _, _ in startFairSplit() }
        .alert(
            "Fair aufgeteilt",
            isPresented: Binding(
                get: { fairSummary != nil }, set: { if !$0 { fairSummary = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(fairSummary ?? "")
        }
        .confirmationDialog(
            "Aufteilung verwerfen?", isPresented: $confirmingClose, titleVisibility: .visible
        ) {
            Button("Verwerfen", role: .destructive, action: onClose)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Aufteilung wird nicht gespeichert. Vorher über die Übersicht teilen.")
        }
    }

    /// Whose turn it is, as a pop-up button — the control iOS uses for one of
    /// several, and the one that holds eight people as comfortably as two —
    /// with "Weiter" beside it for the way a split is actually done: one
    /// person, then the next.
    private func personBar(days: [SplitDay]?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    Picker("Person", selection: $person) {
                        ForEach(0..<state.people, id: \.self) { index in
                            Text(pickerLine(for: index, days: days)).tag(index)
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text("Person \(person + 1)").fontWeight(.semibold)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.primary)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                Text(dayLine(days))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                Spacer(minLength: 4)

                if person < state.people - 1 {
                    Button("Weiter") { withAnimation(.snappy) { person += 1 } }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }

            Text("Mit einem Finger einkreisen, mit zwei die Karte bewegen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .animation(.snappy, value: state.owner.count)
    }

    /// The way on: everyone's share, and the button that turns one into a
    /// tour. Pinned, because it is the point of the screen and the list above
    /// it can be thirty rows long.
    private var finishBar: some View {
        Button {
            showingOverview = true
        } label: {
            WideButtonLabel("Übersicht und Touren", systemImage: "list.bullet.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// "21 Stopps an 16 Adressen · ca. 4 h 05": the person's day as "Tour
    /// vorbereiten" would count it, so a split drawn by hand can be seen to
    /// be fair or not — and six customers at one address read as the one
    /// stop they are to drive to.
    private func dayLine(_ days: [SplitDay]?) -> String {
        let count = Format.stops(mine.count)
        guard let days, days.indices.contains(person), days[person].stops > 0 else { return count }
        var day = days[person]
        // The stops off the map are the person's too, each its own address.
        let unplaced = mine.count - day.stops
        day.stops += unplaced
        day.addresses += unplaced
        return "\(day.stopsLine) · ca. \(day.clock)"
    }

    private func pickerLine(for index: Int, days: [SplitDay]?) -> String {
        let line = "Person \(index + 1) · \(Format.stops(state.stops(of: index).count))"
        guard let days, days.indices.contains(index), days[index].stops > 0 else { return line }
        return "\(line) · \(days[index].clock)"
    }

    private func startFairSplit() {
        guard busy == nil, state.hasFreePlacedStops else { return }
        Task { await fairSplit() }
    }

    /// The free stops shared out so everybody's day is as long as anybody's
    /// — see `SplitPlanner`. What was handed out by hand stays where it is.
    private func fairSplit() async {
        busy = "Wird fair aufgeteilt …"
        defer { busy = nil }
        // Asked again when the first time had no OSRM: the signal may be back.
        if state.durations?.estimated != false {
            busy = "Fahrzeiten werden berechnet …"
            let fresh = await SplitDurations.load(for: state.stops)
            if state.durations == nil || !fresh.estimated { state.durations = fresh }
            busy = "Wird fair aufgeteilt …"
        }
        guard let input = state.fairSplitInput(history: .current) else { return }
        let planned = await Task.detached(priority: .userInitiated) {
            SplitPlanner.plan(
                doors: input.doors, people: input.people, durations: input.durations.seconds,
                deadline: Date().addingTimeInterval(SplitPlanner.thinkingTime))
        }.value
        // Only what is still free: the map stays in use while this thinks,
        // and a door tapped meanwhile was a decision.
        let owners = input.owners(planned).filter { state.owner[$0.key] == nil }
        withAnimation(.snappy) { _ = state.assign(owners) }
        let unplaced = state.stops.filter { $0.coordinate == nil && state.owner(of: $0) == nil }
        fairSummary = FairSplitInput.summary(
            input.days(planned), estimated: input.durations.estimated, unplacedFree: unplaced.count)
    }

    private func unplacedRow(_ stop: SplitStop) -> some View {
        let owner = state.owner(of: stop)
        let mine = owner == person
        return Button {
            withAnimation { state.toggle(stop.id, for: person) }
        } label: {
            HStack {
                StopLine(stop: stop)
                Spacer()
                if let owner, !mine {
                    Text("Person \(owner + 1)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SplitState.colors[owner])
                } else {
                    Image(systemName: mine ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(mine ? color : .secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct StopLine: View {
    let stop: SplitStop

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stop.name)
            Text(stop.address.isEmpty ? "Keine Adresse" : stop.address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Übersicht, and turning a share into a tour

/// Everyone's share on one screen — and the one thing this feature could not
/// do until now: hand a share to the app itself.
///
/// "Als Tour anlegen" goes through exactly what every other bulk import goes
/// through: the entries are fetched, a route is created, and `ImportReviewView`
/// shows them for checking before a single stop is written. A review the driver
/// backs out of takes the empty route with it.
private struct SplitOverview: View {
    @Binding var state: SplitState
    var onOpenedTour: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @State private var busy: String?
    @State private var task: Task<Void, Never>?
    @State private var error: AppError?
    @State private var review: ReviewContext?
    /// The same context, kept across the dismissal: `sheet(item:)` clears its
    /// own binding *before* `onDismiss` runs, so reading `review` in there
    /// found nothing — and the screen then neither recorded the tour it had
    /// just created nor cleaned up after a review that saved nothing.
    @State private var pending: ReviewContext?
    @State private var imported = false

    struct ReviewContext: Identifiable {
        let id = UUID()
        let route: Route
        let entries: [CustomerJSON]
        let person: Int
    }

    var body: some View {
        let days = state.days()
        List {
            ForEach(0..<state.people, id: \.self) { person in
                section(for: person, day: days.flatMap { $0.indices.contains(person) ? $0[person] : nil })
            }
            let rest = state.stops(of: nil)
            if !rest.isEmpty {
                Section("Nicht zugeteilt · \(rest.count)") {
                    ForEach(rest) { StopLine(stop: $0) }
                }
            }
        }
        .navigationTitle("Übersicht")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: state.shareText) {
                    Label("Alle teilen", systemImage: "square.and.arrow.up")
                }
            }
        }
        .floatingBanner {
            if let busy {
                BusyBanner(text: busy, onCancel: { task?.cancel() })
            }
        }
        .animation(.snappy, value: busy)
        .errorAlert($error)
        .sheet(item: $review, onDismiss: reviewDismissed) { ctx in
            ImportReviewView(route: ctx.route, entries: ctx.entries) { imported = true }
        }
    }

    @ViewBuilder
    private func section(for person: Int, day: SplitDay?) -> some View {
        let mine = state.stops(of: person)
        Section {
            if mine.isEmpty {
                Text("Keine Stopps").foregroundStyle(.secondary)
            }
            ForEach(mine) { StopLine(stop: $0) }

            if !mine.isEmpty {
                Button {
                    task = Task { await createTour(for: person) }
                } label: {
                    Label("Als Tour anlegen", systemImage: "plus.circle")
                }
                .disabled(busy != nil)
            }
        } header: {
            HStack(spacing: 6) {
                Circle().fill(SplitState.colors[person]).frame(width: 10, height: 10)
                Text("Person \(person + 1) · \(mine.count)")
                if let day, day.stops > 0 {
                    Text("· ca. \(day.clock)").foregroundStyle(.secondary)
                }
                Spacer()
                if !mine.isEmpty {
                    ShareLink(item: state.shareText(for: person)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Person \(person + 1) teilen")
                }
            }
            .textCase(nil)
        }
    }

    // MARK: Actions

    private func createTour(for person: Int) async {
        busy = "Paket wird geladen …"
        defer { busy = nil }

        let entries = await state.entries(for: person) { done, total in
            Task { @MainActor in busy = "Paket \(done) von \(total) wird geladen …" }
        }
        guard !entries.isEmpty, !Task.isCancelled else { return }

        do {
            let open = FetchDescriptor<Route>(predicate: #Predicate { $0.statusRaw == "active" })
            let taken = Set(((try? context.fetch(open)) ?? []).map(\.name))
            let route = try RouteStore.createRoute(
                name: state.routeName(for: person, taken: taken), in: context)
            if let tourID = state.tourID {
                PortalTourLink(tourID: tourID, tourName: state.tourName, date: state.date)
                    .save(for: route.id)
            }
            let ctx = ReviewContext(route: route, entries: entries, person: person)
            pending = ctx
            review = ctx
        } catch {
            self.error = AppError.message("Die Tour konnte nicht angelegt werden.")
        }
    }

    /// Runs once the review is gone, whichever way it went.
    ///
    /// A share that became a tour hands the driver straight over to it under
    /// Touren — that tour is the thing they are about to drive, and staying
    /// behind on a splitting screen whose work is now done was a dead end they
    /// had to find their own way out of. A review that saved nothing takes its
    /// empty route with it instead, the same bargain the portal import makes.
    private func reviewDismissed() {
        guard let ctx = pending else { return }
        pending = nil
        defer { imported = false }
        guard imported else {
            try? RouteStore.delete(ctx.route, in: context)
            return
        }
        focus.open(ctx.route)
        onOpenedTour()
    }
}
