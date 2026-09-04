import SwiftUI
import SwiftData
import MapKit

/// The route on a map. MapKit rather than a tile stack of our own: it is the
/// map the driver already knows, it needs no tile hosting, and its satellite
/// style replaces what the Stadt-Wien aerial layer was there for.
struct MapTab: View {
    @Environment(RouteFocus.self) private var focus
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: \Route.createdAt, order: .reverse) private var routes: [Route]

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: MapStyleChoice = .standard
    @State private var selectedStopID: UUID?
    /// The measured height of the tapped stop's card — see the sheet below.
    @State private var previewHeight: CGFloat = 200

    /// The map's content, built once per change rather than per frame.
    ///
    /// `Map`'s content closure is re-evaluated on every camera change — which,
    /// during the fit animation on first open, is every frame. Deriving from the
    /// model in there meant rebuilding the whole polyline and re-sorting the
    /// stops once per marker per frame: O(n² log n) over a live SwiftData
    /// relationship, sixty times a second. That was the lag.
    @State private var line: [CLLocationCoordinate2D] = []
    @State private var pins: [MapPin] = []

    private var route: Route? {
        routes.first { $0.id == focus.currentRouteID } ?? routes.first
    }

    private var selectedStop: Stop? {
        guard let selectedStopID, let route else { return nil }
        return route.stops.first { $0.id == selectedStopID }
    }

    /// What changes the *shape* of the map — which route, which stops, what
    /// the driven line is. A change here re-fits the camera, because the thing
    /// being shown is genuinely different.
    ///
    /// Kept deliberately cheap to build. `Map(position:)` writes back to its
    /// binding on every frame of a pan or a zoom, so this body — and therefore
    /// this key and `styleKey` below — is rebuilt sixty times a second while
    /// the driver is moving the map. Ordering by `uuidString` is what that
    /// cannot afford: it allocates a 36-character string per comparison, so a
    /// hundred-stop tour spent well over a thousand string allocations per
    /// frame just deciding whether anything had changed. `idOrderedBefore`
    /// compares the raw bytes and allocates nothing.
    private var shapeKey: ShapeKey {
        guard let route else { return ShapeKey(route: nil, stops: [], geometry: []) }
        return ShapeKey(
            route: route.id,
            stops: route.stops
                .map {
                    ShapeKey.StopEntry(
                        id: $0.id,
                        kindRaw: $0.kindRaw,
                        orderIndex: $0.orderIndex,
                        lat: $0.lat,
                        lon: $0.lon,
                        title: $0.kind == .customer ? ($0.kunde ?? "Stopp") : $0.fixedTitle,
                        excluded: $0.excluded)
                }
                .sorted { UUID.idOrderedBefore($0.id, $1.id) },
            geometry: route.geometryFlat)
    }

    /// What changes only the *colour* of a pin: a delivery ticked off, a fixed
    /// stop switched out, an address re-checked into a better precision. These
    /// rebuild the pins but deliberately leave the camera alone — a tick in the
    /// Routen tab must not yank the map the driver is looking at.
    ///
    /// An explicit per-stop key rather than a count, so swapping which stop is
    /// delivered still registers. Reading these properties here is what
    /// subscribes the view to them in the first place, which is why a tick now
    /// reaches the map at all.
    private var styleKey: StyleKey {
        guard let route else { return StyleKey(entries: []) }
        return StyleKey(
            entries: route.stops
                .map {
                    StyleKey.Entry(
                        id: $0.id,
                        delivered: $0.delivered,
                        excluded: $0.excluded,
                        precisionRaw: $0.precisionRaw)
                }
                .sorted { UUID.idOrderedBefore($0.id, $1.id) })
    }

    private struct ShapeKey: Equatable {
        let route: UUID?
        let stops: [StopEntry]
        let geometry: [Double]

        struct StopEntry: Equatable {
            let id: UUID
            let kindRaw: String
            let orderIndex: Int
            let lat: Double
            let lon: Double
            let title: String
            let excluded: Bool
        }
    }

    private struct StyleKey: Equatable {
        let entries: [Entry]

        struct Entry: Equatable {
            let id: UUID
            let delivered: Bool
            let excluded: Bool
            let precisionRaw: String?
        }
    }

    var body: some View {
        Group {
            if let route {
                map(for: route)
            } else {
                ContentUnavailableView(
                    "Keine Tour ausgewählt", systemImage: "map",
                    description: Text("Leg im Tab „Routen“ eine Tour an."))
            }
        }
        .navigationTitle(route?.name ?? "Karte")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title gets its own glass pill rather than relying on the bar
            // background. iOS 26 keeps a map's navigation bar transparent
            // whatever `toolbarBackgroundVisibility` asks for — which is right
            // for the map, but left plain black text sitting directly on the
            // tiles, illegible the moment the driver switched to Satellit.
            ToolbarItem(placement: .principal) {
                if let route {
                    Text(route.name)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Kartenstil", selection: $style) {
                        ForEach(MapStyleChoice.allCases) { s in
                            Label(s.label, systemImage: s.symbol).tag(s)
                        }
                    }
                    if routes.count > 1 {
                        Divider()
                        Picker("Tour", selection: routeBinding) {
                            ForEach(routes) { r in
                                Text(r.name).tag(Optional(r.id))
                            }
                        }
                    }
                } label: {
                    Label("Optionen", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: sheetStop) { stop in
            // Sized to what the stop actually has, not to a fixed guess. A
            // fixed height gave a customer with no Paket and no Notiz the same
            // card as one carrying both, leaving a band of empty material under
            // the button.
            StopPreviewSheet(
                stop: stop,
                number: customerNumber(of: stop),
                onNavigate: { navigate(to: stop) },
                onToggleDelivered: { toggleDelivered(stop) },
                onShowInList: {
                    if let route { focus.reveal(stop: stop, of: route) }
                    selectedStopID = nil
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    previewHeight = height
                }
                .presentationDetents([.height(previewHeight)])
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.visible)
        }
    }

    /// The stop's position among the customers — the number its pin carries, so
    /// the card the pin opens is recognisably about that pin.
    private func customerNumber(of stop: Stop) -> Int? {
        guard stop.kind == .customer, let route else { return nil }
        return route.customerStops.firstIndex { $0.id == stop.id }.map { $0 + 1 }
    }

    private func navigate(to stop: Stop) {
        guard let url = NavigationHandoff.url(for: stop) else { return }
        openURL(url)
    }

    private func toggleDelivered(_ stop: Stop) {
        guard stop.kind == .customer else { return }
        try? RouteStore.setDelivered(stop, !stop.delivered, in: context)
    }

    private var sheetStop: Binding<Stop?> {
        Binding(get: { selectedStop }, set: { if $0 == nil { selectedStopID = nil } })
    }

    private var routeBinding: Binding<UUID?> {
        Binding(
            get: { focus.currentRouteID ?? routes.first?.id },
            set: { focus.currentRouteID = $0 })
    }

    @ViewBuilder
    private func map(for route: Route) -> some View {
        Map(position: $camera, selection: $selectedStopID) {
            UserAnnotation()

            if line.count >= 2 {
                // Casing first, then the line itself on top of it.
                MapPolyline(coordinates: line)
                    .stroke(
                        Color.routeCasing,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line)
                    .stroke(
                        Color.brand,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            ForEach(pins, id: \.annotationID) { pin in
                if let monogram = pin.monogram {
                    Marker(pin.title, monogram: Text(verbatim: monogram), coordinate: pin.coordinate)
                        .tint(pin.tint)
                        .tag(pin.id)
                } else {
                    Marker(pin.title, systemImage: pin.symbol, coordinate: pin.coordinate)
                        .tint(pin.tint)
                        .tag(pin.id)
                }
            }
        }
        .mapStyle(style.mapStyle)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onChange(of: shapeKey, initial: true) { rebuildRoute(route, fitCamera: true) }
        .onChange(of: styleKey) { rebuildPins(for: route) }
        // `onChange` only fires if the body was evaluated, and a tab sitting in
        // the background is not guaranteed to be. Rebuilding on appear is what
        // makes a delivery ticked off in the Routen tab reliably show up green
        // here — the camera is left alone unless there is nothing drawn yet.
        .onAppear {
            if line.isEmpty {
                rebuildRoute(route, fitCamera: true)
            } else {
                rebuildPins(for: route)
            }
        }
        // Once the driver has panned off to look at one corner of the tour
        // there was no way back to the whole route short of leaving the tab and
        // coming back. Bottom-trailing, where Apple Maps keeps its own map
        // controls and where a thumb on a phone held in one hand can reach.
        .overlay(alignment: .bottomTrailing) {
            Button {
                fitCamera()
            } label: {
                // The `contentShape` is the whole 44pt disc, not just the
                // glyph: a miss over a map is a pan, so a control here has to
                // be the size it looks.
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.borderless)
            .glassEffect(.regular, in: .circle)
            .accessibilityLabel("Ganze Route zeigen")
            .padding(.trailing, 14)
            .padding(.bottom, 14)
            .safeAreaPadding(.bottom)
        }
    }

    // MARK: - Building the map content

    /// Derives the polyline and the pins from the route.
    ///
    /// Shape changes are allowed to re-fit the camera. Style-only changes use
    /// `rebuildPins(for:)` so ticking a stop does not re-simplify thousands of
    /// polyline points or move the map underneath the driver.
    private func rebuildRoute(_ route: Route, fitCamera: Bool) {
        rebuildPins(for: route)
        // Simplified for drawing. OSRM's full-overview geometry is ~600 points
        // per leg, so a thirty-stop tour is several thousand in one polyline —
        // and MapKit redraws all of them on every pan and zoom frame. At the
        // zoom levels a route is ever looked at, the discarded points are well
        // under a pixel.
        line = Self.simplified(route.geometry, tolerance: 0.00002)

        if fitCamera { self.fitCamera() }
    }

    /// Frames the whole tour. Prefers the driven line over the pins, so the
    /// view covers the road actually taken rather than just the doors on it.
    ///
    private func fitCamera() {
        let points = line.isEmpty ? pins.map(\.coordinate) : line
        guard let region = MKCoordinateRegion(fitting: points) else { return }
        withAnimation(.easeInOut) { camera = .region(region) }
    }

    /// Derives only the annotations. This is intentionally cheap enough to run
    /// for a delivery tick, address precision change, or tab re-entry.
    private func rebuildPins(for route: Route) {
        let ordered = route.orderedStops

        // Numbered once, up front. Asking each marker for its own index meant
        // re-sorting and re-scanning the whole route per marker.
        var number: [UUID: Int] = [:]
        var n = 0
        for stop in ordered where stop.kind == .customer {
            n += 1
            number[stop.id] = n
        }

        // The destination is dropped when it sits on the depot — which it does
        // on every default route, both being Petritschgasse 24. Two markers on
        // one coordinate gave a single visible pin wearing Ziel's checkered flag
        // under Start's label, which reads as a bug.
        let start = ordered.first { $0.kind == .start && !$0.excluded }
        let end = ordered.first { $0.kind == .end && !$0.excluded }
        let endIsOnStart = start != nil && end != nil && Self.sameSpot(start!, end!)

        var built: [MapPin] = []
        built.reserveCapacity(ordered.count)
        for stop in ordered {
            guard !stop.excluded else { continue }
            if endIsOnStart, stop.kind == .end { continue }

            let title: String
            if stop.kind == .customer {
                title = stop.kunde ?? "Stopp"
            } else if stop.kind == .start, endIsOnStart {
                title = "Start · Ziel"
            } else {
                title = stop.fixedTitle
            }

            built.append(
                MapPin(
                    id: stop.id,
                    visualState: Self.visualState(for: stop),
                    lat: stop.coordinate.latitude,
                    lon: stop.coordinate.longitude,
                    title: title,
                    monogram: number[stop.id].map(String.init),
                    symbol: Self.symbol(for: stop.kind),
                    tint: Self.tint(for: stop)))
        }

        pins = built
    }

    /// Ramer–Douglas–Peucker. Keeps the corners that define the shape of the
    /// route and drops the points that only sit along a straight run.
    ///
    /// Longitude is scaled by the cosine of Vienna's latitude so the tolerance
    /// means the same distance in both directions — unscaled, a degree of
    /// longitude here is only about two thirds of a degree of latitude, and the
    /// line would be simplified more aggressively east-west than north-south.
    ///
    /// Iterative rather than recursive: this runs over several thousand points,
    /// and a pathological input should not be able to blow the stack.
    nonisolated static func simplified(
        _ points: [CLLocationCoordinate2D], tolerance: Double
    ) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }

        let lonScale = cos(48.2 * .pi / 180)
        func x(_ c: CLLocationCoordinate2D) -> Double { c.longitude * lonScale }
        func y(_ c: CLLocationCoordinate2D) -> Double { c.latitude }

        /// Perpendicular distance from `p` to the segment `a`–`b`.
        func distance(
            _ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
            _ b: CLLocationCoordinate2D
        ) -> Double {
            let dx = x(b) - x(a), dy = y(b) - y(a)
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(x(p) - x(a), y(p) - y(a)) }
            // Clamped so a point beyond either end measures to the endpoint
            // rather than to the infinite line.
            var t = ((x(p) - x(a)) * dx + (y(p) - y(a)) * dy) / lengthSquared
            t = min(max(t, 0), 1)
            return hypot(x(p) - (x(a) + t * dx), y(p) - (y(a) + t * dy))
        }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var worst = 0.0
            var index = first
            for i in (first + 1)..<last {
                let d = distance(points[i], points[first], points[last])
                if d > worst { worst = d; index = i }
            }
            guard worst > tolerance else { continue }
            keep[index] = true
            stack.append((first, index))
            stack.append((index, last))
        }

        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// Within about a metre — the precision at which two pins are one pin.
    private static func sameSpot(_ a: Stop, _ b: Stop) -> Bool {
        abs(a.lat - b.lat) < 0.00001 && abs(a.lon - b.lon) < 0.00001
    }

    /// Green once delivered, amber while the location is only approximate,
    /// otherwise the ordinary stop blue. The colour carries the same meaning it
    /// does in the list.
    private static func tint(for stop: Stop) -> Color {
        guard stop.kind == .customer else { return .brand }
        if stop.delivered { return .success }
        if stop.precision != nil { return .warning }
        return .blue
    }

    private static func visualState(for stop: Stop) -> Int {
        guard stop.kind == .customer else { return 0 }
        if stop.delivered { return 2 }
        if stop.precision != nil { return 1 }
        return 0
    }

    private static func symbol(for kind: StopKind) -> String {
        switch kind {
        case .start: "house.fill"
        case .via: "shippingbox.fill"
        case .end: "flag.checkered"
        case .customer: "mappin"
        }
    }
}

/// One marker, as a plain value. MapKit's own balloon rather than a custom
/// circle: a circle marks an area, a balloon marks a *point* — its tip is the
/// coordinate, so the driver can tell which side of the street a stop is on.
private struct MapPin: Identifiable, Equatable {
    let id: UUID
    let visualState: Int
    let lat: Double
    let lon: Double
    let title: String
    /// The stop number, for a customer. `nil` on a fixed point, which carries a
    /// symbol instead.
    let monogram: String?
    let symbol: String
    let tint: Color

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var annotationID: String {
        "\(id.uuidString)-\(visualState)"
    }
}

enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard, hybrid

    var id: String { rawValue }
    var label: String { self == .standard ? "Karte" : "Satellit" }
    var symbol: String { self == .standard ? "map" : "globe.europe.africa.fill" }

    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat)
        case .hybrid: .hybrid(elevation: .flat)
        }
    }
}


/// What a tapped pin shows: who is there, what to carry up, and the two things
/// worth doing about it from the map.
///
/// "Navigation starten" is the primary action, because a driver looking at a pin
/// is almost always about to drive to it. "In der Liste anzeigen" sits beside it
/// for the other reason a pin gets tapped — seeing where this stop falls among
/// the ones either side of it.
struct StopPreviewSheet: View {
    let stop: Stop
    var number: Int?
    let onNavigate: () -> Void
    let onToggleDelivered: () -> Void
    let onShowInList: () -> Void

    private var isCustomer: Bool { stop.kind == .customer }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            details
            actions
        }
        // Room for the drag indicator above and the home indicator below: the
        // sheet is exactly as tall as this view now, so the insets have to come
        // from here rather than from spare height.
        .padding(.horizontal)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .safeAreaPadding(.bottom)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.onBrand)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(stop.delivered ? Color.success : Color.brand))
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isCustomer ? (stop.kunde ?? "Stopp") : stop.fixedTitle)
                    .font(.title3.bold())
                Text(stop.listAddress)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // The same control the list row carries, so ticking a stop off from
            // the map is the same gesture at the same size in the same colours.
            if isCustomer {
                Button(action: onToggleDelivered) {
                    Image(systemName: stop.delivered ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 30))
                        .foregroundStyle(stop.delivered ? Color.success : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    stop.delivered ? "Zustellung zurücknehmen" : "Als zugestellt markieren")
                .sensoryFeedback(.impact(weight: .medium), trigger: stop.delivered)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if hasDetails {
            VStack(alignment: .leading, spacing: 8) {
                if let paket = stop.paket, !paket.isEmpty {
                    Label(paket, systemImage: "shippingbox").font(.subheadline)
                }
                if let notiz = stop.notiz, !notiz.isEmpty {
                    Label(notiz, systemImage: "note.text")
                        .font(.subheadline)
                        .foregroundStyle(Color.warningText)
                }
                if let p = stop.precision {
                    Label(p.label, systemImage: p.symbol)
                        .font(.footnote)
                        .foregroundStyle(Color.warning)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Navigation", systemImage: "arrow.trianglehead.turn.up.right", action: onNavigate)
                .buttonStyle(.borderedProminent)
            Button("In der Liste", systemImage: "list.bullet", action: onShowInList)
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    private var hasDetails: Bool {
        !(stop.paket ?? "").isEmpty || !(stop.notiz ?? "").isEmpty || stop.precision != nil
    }
}

extension MKCoordinateRegion {
    /// The smallest region containing every point, with a little padding so
    /// pins are not flush against the edge of the screen.
    init?(fitting coordinates: [CLLocationCoordinate2D]) {
        let valid = coordinates.filter {
            $0.latitude.isFinite && $0.longitude.isFinite
        }
        guard let first = valid.first else { return nil }

        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in valid {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        self.init(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.35, 0.005),
                longitudeDelta: max((maxLon - minLon) * 1.35, 0.005)))
    }
}
