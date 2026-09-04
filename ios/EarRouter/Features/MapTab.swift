import SwiftUI
import SwiftData
import MapKit

/// The route on a map. MapKit rather than a tile stack of our own: it is the
/// map the driver already knows, it needs no tile hosting, and its satellite
/// style replaces what the Stadt-Wien aerial layer was there for.
struct MapTab: View {
    @Environment(RouteFocus.self) private var focus
    @Query(sort: \Route.createdAt, order: .reverse) private var routes: [Route]

    @State private var camera: MapCameraPosition = .automatic
    @State private var style: MapStyleChoice = .standard
    @State private var selected: Stop?

    private var route: Route? {
        routes.first { $0.id == focus.currentRouteID } ?? routes.first
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
        .sheet(item: $selected) { stop in
            StopPreviewSheet(stop: stop)
                .presentationDetents([.height(220), .medium])
                .presentationBackground(.regularMaterial)
        }
    }

    private var routeBinding: Binding<UUID?> {
        Binding(
            get: { focus.currentRouteID ?? routes.first?.id },
            set: { focus.currentRouteID = $0 })
    }

    @ViewBuilder
    private func map(for route: Route) -> some View {
        Map(position: $camera, selection: $selected) {
            UserAnnotation()

            let line = route.geometry
            if line.count >= 2 {
                MapPolyline(coordinates: line)
                    .stroke(
                        Color.brand,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            ForEach(drawnStops(route)) { stop in
                Annotation(label(for: stop, in: route), coordinate: stop.coordinate) {
                    StopPin(stop: stop, number: number(of: stop, in: route))
                }
                .tag(stop)
            }
        }
        .mapStyle(style.mapStyle)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onChange(of: route.id, initial: true) { fit(route) }
        .onChange(of: route.geometryFlat.count) { fit(route) }
    }

    /// Excluded fixed stops are not drawn: the tour does not go there, and a
    /// pin on the map that the route line never touches reads as a bug.
    ///
    /// The destination is also dropped when it sits on the depot — which it does
    /// on every default route, both being Petritschgasse 24. Two annotations on
    /// one coordinate gave one visible pin wearing Ziel's checkered flag under
    /// Start's label. `label(for:)` says "Start · Ziel" on the survivor instead.
    private func drawnStops(_ route: Route) -> [Stop] {
        let visible = route.orderedStops.filter { !$0.excluded }
        guard let start = visible.first(where: { $0.kind == .start }),
              let end = visible.first(where: { $0.kind == .end }),
              sameSpot(start, end)
        else { return visible }
        return visible.filter { $0.id != end.id }
    }

    /// Within about a metre — the precision at which two pins are one pin.
    private func sameSpot(_ a: Stop, _ b: Stop) -> Bool {
        abs(a.lat - b.lat) < 0.00001 && abs(a.lon - b.lon) < 0.00001
    }

    private func label(for stop: Stop, in route: Route) -> String {
        if stop.kind == .customer { return stop.kunde ?? "Stopp" }
        if stop.kind == .start,
           let end = route.stops.first(where: { $0.kind == .end }),
           !end.excluded, sameSpot(stop, end) {
            return "Start · Ziel"
        }
        return stop.fixedTitle
    }

    /// The badge number a customer stop carries — its position among the
    /// customers, not among all stops, so the first delivery is "1" and not "3".
    private func number(of stop: Stop, in route: Route) -> Int? {
        guard stop.kind == .customer else { return nil }
        return route.customerStops.firstIndex(of: stop).map { $0 + 1 }
    }

    private func fit(_ route: Route) {
        let points = route.geometry.isEmpty
            ? drawnStops(route).map(\.coordinate)
            : route.geometry
        guard let region = MKCoordinateRegion(fitting: points) else { return }
        withAnimation(.easeInOut) { camera = .region(region) }
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

struct StopPin: View {
    let stop: Stop
    let number: Int?

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)

            if let number {
                Text("\(number)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            } else {
                Image(systemName: symbol)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
        }
        .opacity(stop.delivered ? 0.55 : 1)
    }

    private var fill: Color {
        if stop.kind != .customer { return .brand }
        if stop.delivered { return .success }
        if stop.precision != nil { return .warning }
        return .blue
    }

    private var symbol: String {
        switch stop.kind {
        case .start: "house.fill"
        case .via: "shippingbox.fill"
        case .end: "flag.checkered"
        case .customer: "circle.fill"
        }
    }
}

/// What a tapped pin shows: who, where, and the one action worth having on a
/// map — start navigating there.
struct StopPreviewSheet: View {
    let stop: Stop
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stop.kind == .customer ? (stop.kunde ?? "Stopp") : stop.fixedTitle)
                .font(.title3.bold())
            Text(stop.fullAddress)
                .foregroundStyle(.secondary)

            if let paket = stop.paket, !paket.isEmpty {
                Label(paket, systemImage: "shippingbox").font(.subheadline)
            }
            if let notiz = stop.notiz, !notiz.isEmpty {
                Label(notiz, systemImage: "note.text").font(.subheadline)
            }
            if let p = stop.precision {
                Label(p.label, systemImage: p.symbol)
                    .font(.footnote).foregroundStyle(.orange)
            }

            Button("Navigation starten", systemImage: "arrow.triangle.turn.up.right.circle.fill") {
                if let url = NavigationHandoff.url(for: stop) {
                    UIApplication.shared.open(url)
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
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
