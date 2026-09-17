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

    var body: some View {
        NavigationStack {
            Group {
                if GourmetCredentialsStore.load() == nil {
                    ContentUnavailableView(
                        "Nicht angemeldet", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text(
                            "Zuerst unter Touren → „Vom Zusteller-Portal“ anmelden."))
                } else {
                    form
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
                if GourmetCredentialsStore.load() != nil { await loadTours() }
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

    /// A free stop goes to `person`; one of theirs is freed again. Someone
    /// else's is left alone.
    mutating func toggle(_ id: Int, for person: Int) {
        let current = owner[id]
        guard current == nil || current == person else { return }
        history.append(owner)
        owner[id] = current == nil ? person : nil
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

private struct TourSplitMapView: View {
    @State var state: SplitState
    @Environment(\.dismiss) private var dismiss

    @State private var person = 0
    @State private var camera: MapCameraPosition = .automatic
    @State private var drawing = true
    @State private var lasso: [CGPoint] = []
    @State private var claimed = 0
    @State private var showingResult = false
    @State private var detent: PresentationDetent = SplitPanel.collapsed

    private static let space = "split-map"
    private static let pinSize: CGFloat = 28

    private var color: Color { SplitState.colors[person] }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                ZStack {
                    map
                    if drawing {
                        lassoLayer(proxy)
                    }
                }
                .coordinateSpace(.named(Self.space))
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) { mapButtons }
            .overlay(alignment: .top) { hint }
            .navigationTitle(state.tourName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: claimed)
            .onAppear(perform: fit)
        }
        .sheet(isPresented: .constant(true)) {
            SplitPanel(
                state: $state, person: $person, showingResult: $showingResult)
                .presentationDetents(
                    [SplitPanel.collapsed, .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            ForEach(state.stops.filter { $0.coordinate != nil }) { stop in
                Annotation(stop.name, coordinate: stop.coordinate!, anchor: .center) {
                    SplitPin(owner: state.owner(of: stop), current: person, size: Self.pinSize)
                        .onTapGesture { toggle(stop) }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {}
    }

    private func lassoLayer(_ proxy: MapProxy) -> some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { lasso.append($0.location) }
                        .onEnded { _ in finishLasso(proxy) })
            if lasso.count > 1 {
                Path { path in
                    path.addLines(lasso)
                    path.closeSubpath()
                }
                .fill(color.opacity(0.15))
                Path { path in path.addLines(lasso) }
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.2), radius: 2)
            }
        }
        .allowsHitTesting(true)
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            mapButton(
                drawing ? "lasso" : "hand.point.up.left",
                label: drawing ? "Einkreisen aktiv" : "Karte bewegen",
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
                fit()
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
        .glassEffect(tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var hint: some View {
        if lasso.isEmpty {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(
                    drawing
                        ? "Stopps für Person \(person + 1) einkreisen"
                        : "Karte bewegen — zum Einkreisen \(Image(systemName: "lasso")) tippen")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func finishLasso(_ proxy: MapProxy) {
        let stroke = lasso
        withAnimation(.easeOut(duration: 0.2)) { lasso = [] }

        func screenPoint(_ stop: SplitStop) -> CGPoint? {
            stop.coordinate.flatMap { proxy.convert($0, to: .named(Self.space)) }
        }

        // Barely moved: a tap. The lasso layer sits over the pins, so it
        // hands the tap to the pin under the finger itself.
        let span = stroke.reduce(into: CGRect.null) { $0 = $0.union(CGRect(origin: $1, size: .zero)) }
        guard span.width > 20 || span.height > 20 else {
            guard let tap = stroke.last else { return }
            let nearest = state.stops
                .compactMap { stop in screenPoint(stop).map { (stop, hypot($0.x - tap.x, $0.y - tap.y)) } }
                .filter { $0.1 <= Self.pinSize }
                .min { $0.1 < $1.1 }
            if let nearest { toggle(nearest.0) }
            return
        }

        let caught = state.stops.compactMap { stop -> Int? in
            guard let point = screenPoint(stop),
                Lasso.catches(point, in: stroke, radius: Self.pinSize / 2)
            else { return nil }
            return stop.id
        }
        let added = withAnimation(.snappy) { state.claim(caught, for: person) }
        if added > 0 { claimed += 1 }
    }

    private func toggle(_ stop: SplitStop) {
        let before = state.owner(of: stop)
        withAnimation(.snappy) { state.toggle(stop.id, for: person) }
        if state.owner(of: stop) != before { claimed += 1 }
    }

    /// Frames every pin, kept clear of the panel along the bottom.
    private func fit() {
        let points = state.stops.compactMap(\.coordinate)
        guard var region = MKCoordinateRegion(fitting: points) else { return }
        region.span.latitudeDelta *= 1.8
        region.span.longitudeDelta *= 1.3
        region.center.latitude -= region.span.latitudeDelta * 0.18
        withAnimation(.easeInOut) { camera = .region(region) }
    }
}

private struct SplitPin: View {
    let owner: Int?
    let current: Int
    let size: CGFloat

    var body: some View {
        let mine = owner == current
        ZStack {
            if let owner {
                Circle().fill(SplitState.colors[owner])
                Text("\(owner + 1)")
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            } else {
                Circle().fill(.white)
                Circle().fill(Color.gray.opacity(0.55)).padding(size * 0.3)
            }
            Circle().strokeBorder(.white, lineWidth: 2)
        }
        .frame(width: size, height: size)
        .opacity(owner == nil || mine ? 1 : 0.45)
        .scaleEffect(mine ? 1.12 : 1)
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .animation(.snappy, value: owner)
        .animation(.snappy, value: current)
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

    private var isLast: Bool { person == state.people - 1 }
    private var color: Color { SplitState.colors[person] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let mine = state.stops(of: person)
                    if mine.isEmpty {
                        Text("Noch keine Stopps — auf der Karte einkreisen.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(mine) { stop in
                        StopLine(stop: stop)
                            .swipeActions {
                                Button("Entfernen", role: .destructive) {
                                    withAnimation { state.toggle(stop.id, for: person) }
                                }
                            }
                    }
                } header: {
                    Text("Person \(person + 1) · \(state.stops(of: person).count) Stopps")
                }

                let unplaced = state.stops.filter {
                    $0.coordinate == nil && (state.owner(of: $0) == nil || state.owner(of: $0) == person)
                }
                if !unplaced.isEmpty {
                    Section {
                        ForEach(unplaced) { stop in
                            let mine = state.owner(of: stop) == person
                            Button {
                                withAnimation { state.toggle(stop.id, for: person) }
                            } label: {
                                HStack {
                                    StopLine(stop: stop)
                                    Spacer()
                                    Image(systemName: mine ? "checkmark.circle.fill" : "plus.circle")
                                        .font(.title3)
                                        .foregroundStyle(mine ? color : .secondary)
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
                    withAnimation { scroller.scrollTo(index, anchor: .center) }
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
