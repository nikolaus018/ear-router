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
                if let split {
                    TourSplitMapView(state: split) { self.split = nil }
                } else if GourmetCredentialsStore.load() == nil {
                    ContentUnavailableView(
                        "Nicht angemeldet", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text(
                            "Zuerst unter Touren → „Vom Zusteller-Portal“ anmelden."))
                } else {
                    form
                }
            }
            .navigationTitle(split == nil ? "Tour aufteilen" : "")
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
            .interactiveDismissDisabled(busy != nil || split != nil)
            .task {
                if GourmetCredentialsStore.load() != nil { await loadTours() }
            }
            .onChange(of: date) { _, _ in reconcileSelection() }
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

/// Everything a split is, held only for as long as the sheet is open.
struct SplitState {
    static let maxPeople = 8
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .red]

    let tourName: String
    let people: Int
    let stops: [SplitStop]
    /// Delivery id → person index. A stop with no entry is still free.
    var owner: [Int: Int] = [:]
}

/// Point-in-polygon by ray casting, in screen points. The lasso is whatever
/// shape a thumb draws, closed straight back to where it started.
enum Lasso {
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
}

// MARK: - Map

private struct TourSplitMapView: View {
    @State var state: SplitState
    var onBack: () -> Void

    @State private var person = 0
    @State private var camera: MapCameraPosition = .automatic
    @State private var drawing = true
    @State private var lasso: [CGPoint] = []
    @State private var history: [[Int: Int]] = []
    @State private var showingUnplaced = false
    @State private var showingResult = false

    private var color: Color { SplitState.colors[person] }
    private var freeCount: Int { state.stops.count - state.owner.count }
    private var mineCount: Int { state.owner.values.filter { $0 == person }.count }
    private var unplaced: [SplitStop] { state.stops.filter { $0.coordinate == nil } }
    private var isLast: Bool { person == state.people - 1 }

    var body: some View {
        MapReader { proxy in
            ZStack {
                Map(position: $camera) {
                    ForEach(state.stops.filter { $0.coordinate != nil }) { stop in
                        Annotation(stop.name, coordinate: stop.coordinate!) {
                            pin(for: stop)
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))

                if drawing {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("split"))
                                .onChanged { lasso.append($0.location) }
                                .onEnded { _ in finishLasso(proxy) })
                    Path { path in
                        guard let first = lasso.first else { return }
                        path.move(to: first)
                        for point in lasso.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [8, 6]))
                    .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named("split"))
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .top) { header }
        .safeAreaInset(edge: .bottom) { controls }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(state.tourName).font(.headline).lineLimit(1)
            }
        }
        .onAppear(perform: fit)
        .sheet(isPresented: $showingUnplaced) {
            UnplacedSheet(state: $state, person: person)
        }
        .sheet(isPresented: $showingResult) {
            SplitResultSheet(state: state)
        }
    }

    private func pin(for stop: SplitStop) -> some View {
        let owner = state.owner[stop.id]
        let fill: Color = owner.map { $0 == person ? SplitState.colors[$0] : Color.gray } ?? .white
        return ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(owner == nil ? color : .white, lineWidth: 2)
            if let owner {
                Text("\(owner + 1)").font(.caption2.bold()).foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .opacity(owner != nil && owner != person ? 0.5 : 1)
        .onTapGesture { toggle(stop) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 14, height: 14)
            Text("Person \(person + 1) von \(state.people)").font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(mineCount) Stopps · \(freeCount) frei")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .animation(.snappy, value: state.owner.count)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    drawing.toggle()
                } label: {
                    Label(
                        drawing ? "Einkreisen" : "Verschieben",
                        systemImage: drawing ? "lasso" : "hand.draw")
                }
                Button {
                    if let last = history.popLast() { state.owner = last }
                } label: {
                    Label("Rückgängig", systemImage: "arrow.uturn.backward")
                }
                .disabled(history.isEmpty)
                if !unplaced.isEmpty {
                    Button {
                        showingUnplaced = true
                    } label: {
                        Label("\(unplaced.count) ohne Karte", systemImage: "mappin.slash")
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote.weight(.semibold))

            HStack(spacing: 10) {
                Button(person == 0 ? "Zurück" : "Person \(person)") {
                    if person == 0 { onBack() } else { person -= 1 }
                }
                .buttonStyle(.bordered)
                if freeCount > 0 {
                    Button("Rest") { assignRest() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if isLast || freeCount == 0 {
                    Button("Fertig") { showingResult = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Weiter zu Person \(person + 2)") { person += 1 }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func finishLasso(_ proxy: MapProxy) {
        defer { lasso = [] }
        // A tap rather than a circle: the lasso layer sits over the pins, so
        // it toggles whichever one is under the finger itself.
        guard lasso.count >= 8 else {
            guard let tap = lasso.last else { return }
            let hit = state.stops.first { stop in
                guard let coordinate = stop.coordinate,
                    let point = proxy.convert(coordinate, to: .named("split"))
                else { return false }
                return hypot(point.x - tap.x, point.y - tap.y) < 22
            }
            if let hit { toggle(hit) }
            return
        }
        var owner = state.owner
        for stop in state.stops where owner[stop.id] == nil {
            guard let coordinate = stop.coordinate,
                let point = proxy.convert(coordinate, to: .named("split")),
                Lasso.contains(point, in: lasso)
            else { continue }
            owner[stop.id] = person
        }
        guard owner != state.owner else { return }
        history.append(state.owner)
        state.owner = owner
    }

    /// A free stop goes to the current person; one of theirs is freed again.
    /// Someone else's is left alone — go back to that person to change it.
    private func toggle(_ stop: SplitStop) {
        let current = state.owner[stop.id]
        guard current == nil || current == person else { return }
        history.append(state.owner)
        state.owner[stop.id] = current == nil ? person : nil
    }

    private func assignRest() {
        history.append(state.owner)
        for stop in state.stops where state.owner[stop.id] == nil {
            state.owner[stop.id] = person
        }
    }

    private func fit() {
        let points = state.stops.compactMap(\.coordinate)
        if let region = MKCoordinateRegion(fitting: points) { camera = .region(region) }
    }
}

// MARK: - Stops without a pin

private struct UnplacedSheet: View {
    @Binding var state: SplitState
    let person: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(state.stops.filter { $0.coordinate == nil }) { stop in
                let owner = state.owner[stop.id]
                Button {
                    guard owner == nil || owner == person else { return }
                    state.owner[stop.id] = owner == nil ? person : nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stop.name).foregroundStyle(Color.primary)
                            Text(stop.address).font(.subheadline).foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        if let owner {
                            Text("Person \(owner + 1)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(SplitState.colors[owner])
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Ohne Karte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Result

private struct SplitResultSheet: View {
    let state: SplitState
    @Environment(\.dismiss) private var dismiss

    private func stops(of person: Int?) -> [SplitStop] {
        state.stops.filter { state.owner[$0.id] == person }
    }

    private var shareText: String {
        var sections: [String] = []
        for person in 0..<state.people {
            let mine = stops(of: person)
            let lines = mine.map { "• \($0.name) – \($0.address)" }
            sections.append((["Person \(person + 1) (\(mine.count))"] + lines).joined(separator: "\n"))
        }
        let rest = stops(of: nil)
        if !rest.isEmpty {
            sections.append(
                (["Nicht zugeteilt (\(rest.count))"] + rest.map { "• \($0.name) – \($0.address)" })
                    .joined(separator: "\n"))
        }
        return "\(state.tourName)\n\n" + sections.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<state.people, id: \.self) { person in
                    let mine = stops(of: person)
                    Section {
                        ForEach(mine) { row($0) }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(SplitState.colors[person]).frame(width: 10, height: 10)
                            Text("Person \(person + 1) · \(mine.count)")
                        }
                    }
                }
                let rest = stops(of: nil)
                if !rest.isEmpty {
                    Section("Nicht zugeteilt · \(rest.count)") {
                        ForEach(rest) { row($0) }
                    }
                }
            }
            .navigationTitle("Aufteilung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zurück") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareText)
                }
            }
        }
    }

    private func row(_ stop: SplitStop) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stop.name)
            Text(stop.address).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
