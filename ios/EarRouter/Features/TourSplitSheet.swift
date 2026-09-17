import SwiftUI
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
            .safeAreaInset(edge: .bottom) {
                if let busy {
                    BusyBanner(text: busy).padding(.bottom, 8)
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
        .fullScreenCover(item: $split) { TourSplitMapView(state: $0) }
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
            let (_, deliveries) = try await GourmetPortal.matchingDeliveries(
                tour: tour, date: date, credentials: credentials
            ) { progress in
                Task { @MainActor in busy = progress }
            }
            guard !deliveries.isEmpty else {
                error = AppError.message(
                    "Für „\(tour.name)“ wurden an diesem Tag keine offenen Lieferungen gefunden.")
                return
            }
            let stops = try await Self.place(deliveries) { done, total in
                Task { @MainActor in busy = "Adresse \(done) von \(total) wird gesucht …" }
            }
            split = SplitState(tourName: tour.name, people: people, stops: stops)
        } catch is CancellationError {
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Lieferungen konnten nicht geladen werden.")
        }
    }

    /// A few lookups at a time: the city register is unthrottled and most of
    /// a regular tour is cached, while the geocoder itself still spaces out
    /// any Nominatim fallback. An address nobody can place is kept, without a
    /// pin, rather than dropped from the split.
    private static func place(
        _ deliveries: [GourmetPortal.Delivery],
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [SplitStop] {
        let inputs = deliveries.map { delivery in
            let (name, address) = GourmetPortal.summary(delivery)
            return (
                id: delivery.id, name: name, address: address,
                plz: delivery.deliveryAddress.zip?.trimmed ?? "")
        }
        var placed: [Int: CLLocationCoordinate2D] = [:]
        try await withThrowingTaskGroup(of: (Int, CLLocationCoordinate2D?).self) { group in
            var next = 0
            var done = 0
            func enqueue() {
                guard next < inputs.count else { return }
                let input = inputs[next]
                next += 1
                group.addTask {
                    do {
                        let hit = try await Geocoder.shared.geocode(
                            strasse: input.address, plz: input.plz)
                        return (input.id, CLLocationCoordinate2D(latitude: hit.lat, longitude: hit.lon))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (input.id, nil)
                    }
                }
            }
            for _ in 0..<4 { enqueue() }
            while let (id, coordinate) = try await group.next() {
                done += 1
                onProgress(done, inputs.count)
                if let coordinate { placed[id] = coordinate }
                enqueue()
            }
        }
        return inputs.map { input in
            SplitStop(
                id: input.id, name: input.name.isEmpty ? "Ohne Namen" : input.name,
                address: input.address, coordinate: placed[input.id])
        }
    }
}

// MARK: - State

struct SplitStop: Identifiable {
    let id: Int
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D?
}

/// Everything a split is, held only for as long as the screen is open.
struct SplitState: Identifiable {
    static let maxPeople = 8
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red]

    let id = UUID()
    let tourName: String
    let people: Int
    let stops: [SplitStop]
    /// Delivery id → person index. A stop with no entry is still free.
    private(set) var owner: [Int: Int] = [:]
    private var history: [[Int: Int]] = []

    init(tourName: String, people: Int, stops: [SplitStop]) {
        self.tourName = tourName
        self.people = people
        self.stops = stops
    }

    var canUndo: Bool { !history.isEmpty }
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

    mutating func undo() {
        if let last = history.popLast() { owner = last }
    }

    mutating func reset() {
        guard !owner.isEmpty else { return }
        history.append(owner)
        owner = [:]
    }

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

private struct TourSplitMapView: View {
    @State var state: SplitState
    @Environment(\.dismiss) private var dismiss

    @State private var person = 0
    @State private var drawing = true
    @State private var lassoActive = false
    @State private var showingResult = false
    @State private var detent: PresentationDetent = SplitPanel.collapsed
    @State private var fitToken = 0
    @State private var focus: SplitFocus?
    @State private var tapTick = 0
    @State private var confirmingClose = false
    @State private var lassoTick = 0

    private var color: Color { SplitState.colors[person] }

    var body: some View {
        NavigationStack {
            SplitMapView(
                stops: state.stops, owner: state.owner, person: person, drawing: drawing,
                fitToken: fitToken, focus: focus,
                onTap: { id in
                    withAnimation(.snappy) { state.toggle(id, for: person) }
                    tapTick += 1
                },
                onLasso: { ids in
                    let added = withAnimation(.snappy) { state.claim(ids, for: person) }
                    if added > 0 { lassoTick += 1 }
                },
                onLassoActive: { lassoActive = $0 }
            )
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) { mapButtons }
            .overlay(alignment: .top) { hint }
            .navigationTitle(state.tourName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") {
                        // Nothing here is saved, so a split that is half done
                        // is not closed on one stray tap.
                        if state.owner.isEmpty { dismiss() } else { confirmingClose = true }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: tapTick)
            .sensoryFeedback(.impact(weight: .medium), trigger: lassoTick)
        }
        .sheet(isPresented: .constant(true)) {
            SplitPanel(
                state: $state, person: $person, showingResult: $showingResult,
                confirmingClose: $confirmingClose,
                onClose: { dismiss() },
                onFocus: { stop in
                    focus = SplitFocus(id: stop.id, sequence: (focus?.sequence ?? 0) + 1)
                }
            )
            .presentationDetents([SplitPanel.collapsed, .medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled)
            .interactiveDismissDisabled()
        }
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            mapButton(
                "lasso", label: drawing ? "Einkreisen aus" : "Einkreisen an",
                tint: drawing ? color : nil
            ) {
                drawing.toggle()
            }
            mapButton("arrow.uturn.backward", label: "Rückgängig") {
                withAnimation(.snappy) { state.undo() }
            }
            .disabled(!state.canUndo)
            .opacity(state.canUndo ? 1 : 0.4)
            mapButton("arrow.down.left.and.arrow.up.right", label: "Alle Stopps zeigen") {
                fitToken += 1
            }
        }
        .padding(.trailing, 12)
        .padding(.top, 8)
    }

    private func mapButton(
        _ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.primary : Color.white)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(
            tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var hint: some View {
        if !lassoActive {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(
                    drawing
                        ? "Person \(person + 1): einkreisen oder antippen"
                        : "Person \(person + 1): Stopps antippen")
                    .font(.subheadline.weight(.medium))
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 8)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .animation(.snappy, value: person)
        }
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
    let drawing: Bool
    let fitToken: Int
    let focus: SplitFocus?
    var onTap: (Int) -> Void
    var onLasso: ([Int]) -> Void
    var onLassoActive: (Bool) -> Void

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
        coordinator.setDrawing(drawing)
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
        private var drawing: Bool?
        private var stroke: [CGPoint] = []
        private var pending: Set<Int> = []

        private var color: UIColor { UIColor(SplitState.colors[parent.person]) }

        // MARK: Drawing

        /// In drawing mode the map's own panning is moved to two fingers, so
        /// a single finger is free for the lasso.
        func setDrawing(_ on: Bool) {
            guard drawing != on, let map else { return }
            drawing = on
            lassoRecognizer.isEnabled = on
            for recognizer in Self.recognizers(in: map) where recognizer !== lassoRecognizer {
                if let pan = recognizer as? UIPanGestureRecognizer, pan.maximumNumberOfTouches > 1 {
                    pan.minimumNumberOfTouches = on ? 2 : 1
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
                lassoLayer.opacity = 1
                parent.onLassoActive(true)
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
            return annotations.values.compactMap { annotation in
                guard parent.owner[annotation.id] == nil else { return nil }
                var point = map.convert(annotation.coordinate, toPointTo: map)
                if let offset = offsets[annotation.id] {
                    point.x += offset.x
                    point.y += offset.y
                }
                return Lasso.catches(point, in: stroke, radius: SplitPinView.disc / 2)
                    ? annotation.id : nil
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
            parent.onLassoActive(false)
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
        DispatchQueue.main.async(execute: first)
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

// MARK: - Panel

/// Apple Maps' kind of sheet: always there, the map stays usable behind it,
/// and it lists — by name — what the current person has so far.
private struct SplitPanel: View {
    static let collapsed = PresentationDetent.height(150)

    @Binding var state: SplitState
    @Binding var person: Int
    @Binding var showingResult: Bool
    /// Asked from here rather than from the map underneath: this panel is the
    /// screen in front, and only the one in front can present anything.
    @Binding var confirmingClose: Bool
    var onClose: () -> Void
    var onFocus: (SplitStop) -> Void

    private var isLast: Bool { person == state.people - 1 }
    private var color: Color { SplitState.colors[person] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let mine = state.stops(of: person)
                    if mine.isEmpty {
                        Text("Noch keine Stopps — auf der Karte einkreisen oder antippen.")
                            .foregroundStyle(.secondary)
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
                } header: {
                    Text("Person \(person + 1) · \(Format.stops(state.stops(of: person).count))")
                }

                let unplaced = state.stops.filter { $0.coordinate == nil }
                if !unplaced.isEmpty {
                    Section {
                        ForEach(unplaced) { stop in
                            let owner = state.owner(of: stop)
                            let mine = owner == person
                            Button {
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
                    } header: {
                        Text("Nicht auf der Karte")
                    } footer: {
                        Text("Adresse nicht gefunden — hier antippen, um sie zuzuteilen.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showingResult) {
            SplitResultSheet(state: state)
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

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aufteilen").font(.title3.bold())
                    Text(state.freeCount == 0 ? "Alle Stopps verteilt" : "\(state.freeCount) von \(state.stops.count) noch frei")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Menu {
                    Button("Rest an Person \(person + 1)", systemImage: "tray.and.arrow.down") {
                        withAnimation {
                            state.claim(state.stops(of: nil).map(\.id), for: person)
                        }
                    }
                    .disabled(state.freeCount == 0)
                    Button("Übersicht", systemImage: "list.bullet") { showingResult = true }
                    Button("Alles zurücksetzen", systemImage: "arrow.counterclockwise", role: .destructive) {
                        withAnimation { state.reset() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)

                if isLast || state.freeCount == 0 {
                    Button("Fertig") { showingResult = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        withAnimation(.snappy) { person += 1 }
                    } label: {
                        Label("Person \(person + 2)", systemImage: "chevron.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SplitState.colors[person + 1])
                }
            }

            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<state.people, id: \.self) { index in
                            chip(index).id(index)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)
                .onChange(of: person) { _, index in
                    withAnimation { scroller.scrollTo(index) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 4)
        .animation(.snappy, value: state.freeCount)
    }

    private func chip(_ index: Int) -> some View {
        let selected = index == person
        let tint = SplitState.colors[index]
        return Button {
            withAnimation(.snappy) { person = index }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selected ? Color.white : tint)
                    .frame(width: 8, height: 8)
                Text("Person \(index + 1)")
                Text("\(state.stops(of: index).count)")
                    .monospacedDigit()
                    .opacity(0.75)
                    .contentTransition(.numericText())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? tint : Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.footnote.weight(.bold))
        }
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

// MARK: - Result

private struct SplitResultSheet: View {
    let state: SplitState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<state.people, id: \.self) { person in
                    let mine = state.stops(of: person)
                    Section {
                        if mine.isEmpty {
                            Text("Keine Stopps").foregroundStyle(.secondary)
                        }
                        ForEach(mine) { StopLine(stop: $0) }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(SplitState.colors[person]).frame(width: 10, height: 10)
                            Text("Person \(person + 1) · \(mine.count)")
                            Spacer()
                            ShareLink(item: state.shareText(for: person)) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Person \(person + 1) teilen")
                        }
                    }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zurück") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: state.shareText) {
                        Label("Alle teilen", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
