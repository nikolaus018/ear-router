import SwiftUI
import SwiftData
import MapKit

/// Add or edit one customer stop. Also the way into the pin-drop map, which is
/// what a driver reaches for when the geocoder cannot place an address — or has
/// placed it on the wrong side of a Gemeindebau.
struct StopEditorSheet: View {
    let route: Route
    let stop: Stop?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var kunde = ""
    @State private var strasse = ""
    @State private var plz = ""
    @State private var paket = ""
    @State private var notiz = ""
    @State private var pinned: CLLocationCoordinate2D?
    @State private var showingPinDrop = false
    @State private var saving = false
    @State private var error: AppError?

    private var isEditing: Bool { stop != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Kunde") {
                    TextField("Name", text: $kunde)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Straße und Hausnummer", text: $strasse)
                        .autocorrectionDisabled()
                    Picker("Bezirk", selection: $plz) {
                        Text("Bitte wählen").tag("")
                        ForEach(Districts.all) { d in
                            Text("\(d.plz) — \(d.label)").tag(d.plz)
                        }
                    }
                } header: {
                    Text("Adresse")
                } footer: {
                    if pinned != nil {
                        Label(
                            "Pin von Hand gesetzt — die Adresse wird nicht neu gesucht.",
                            systemImage: "hand.point.up.left.fill")
                    } else if let p = stop?.precision {
                        Label(p.label, systemImage: p.symbol).foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("Paket (z. B. 2x Menü)", text: $paket)
                        // Both fields carry door codes, Stiege numbers and
                        // shorthand that no dictionary knows. Autocorrect
                        // silently rewrote a typed "Tuercode ENVV" to "Zürcher
                        // ENVV" — and a quietly corrupted door code is a driver
                        // standing outside a building they cannot get into.
                        .autocorrectionDisabled()
                    TextField("Notiz", text: $notiz, axis: .vertical)
                        .lineLimit(2...6)
                        .autocorrectionDisabled()
                } header: {
                    Text("Lieferung")
                } footer: {
                    Text("Autokorrektur ist hier aus — Türcodes und Stiegen bleiben, wie du sie tippst.")
                }

                Section {
                    Button("Pin auf der Karte setzen", systemImage: "mappin.and.ellipse") {
                        showingPinDrop = true
                    }
                    if pinned != nil {
                        Button("Pin verwerfen, Adresse suchen", systemImage: "arrow.uturn.backward", role: .destructive) {
                            pinned = nil
                        }
                    }
                }

                if let stop, stop.kind == .customer {
                    Section {
                        Button("In Karten öffnen", systemImage: "arrow.triangle.turn.up.right.circle") {
                            if let url = NavigationHandoff.url(for: stop) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Stopp bearbeiten" : "Neuer Stopp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // The confirm button becomes the progress indicator, which
                    // is how Apple shows in-flight work in a sheet — a scrim
                    // over the whole form told the driver less and blocked the
                    // Abbrechen they might well want.
                    if saving {
                        ProgressView()
                    } else {
                        Button(isEditing ? "Speichern" : "Hinzufügen") {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $showingPinDrop) {
                PinDropSheet(
                    initial: pinned
                        ?? stop?.coordinate
                        ?? Districts.byPlz[plz].map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        }
                        ?? CLLocationCoordinate2D(
                            latitude: Coordinates.viennaCenter.lat,
                            longitude: Coordinates.viennaCenter.lon),
                    label: kunde.isEmpty ? strasse : kunde
                ) { coordinate in
                    pinned = coordinate
                }
            }
            .errorAlert($error) { correctedPlz in
                // The geocoder found the address, just in another district —
                // one tap moves it there and the driver can save again.
                plz = correctedPlz
            }
            .onAppear(perform: load)
        }
    }

    private var canSave: Bool {
        !kunde.trimmed.isEmpty && !strasse.trimmed.isEmpty && Districts.isValid(plz)
    }

    private func load() {
        guard let stop else {
            // A new stop starts in whatever district the last one was in — a
            // tour is usually a handful of neighbouring districts, so this is
            // right far more often than not.
            plz = route.customerStops.last?.plz ?? ""
            return
        }
        kunde = stop.kunde ?? ""
        strasse = stop.strasse ?? ""
        plz = stop.plz ?? ""
        paket = stop.paket ?? ""
        notiz = stop.notiz ?? ""
    }

    private func save() async {
        saving = true
        defer { saving = false }

        let coordinate = pinned.map { (lat: $0.latitude, lon: $0.longitude) }
        do {
            if let stop {
                try await RouteStore.updateStop(
                    stop, kunde: kunde, strasse: strasse, plz: plz,
                    paket: paket, notiz: notiz, coordinate: coordinate, in: context)
            } else {
                try await RouteStore.addStop(
                    to: route, kunde: kunde, strasse: strasse, plz: plz,
                    paket: paket, notiz: notiz, coordinate: coordinate, in: context)
            }
            dismiss()
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Konnte den Stopp nicht speichern.")
        }
    }
}

/// Drop a pin by hand. The crosshair stays fixed in the centre and the map
/// moves under it — the same interaction Apple Maps uses for "Mark My
/// Location", and much easier to aim one-handed at a van door than dragging a
/// pin with a thumb that covers it.
struct PinDropSheet: View {
    let initial: CLLocationCoordinate2D
    let label: String
    let onPick: (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            ZStack {
                MapReader { _ in
                    Map(position: $camera)
                        .mapStyle(.standard(elevation: .flat))
                        .onMapCameraChange(frequency: .continuous) { ctx in
                            center = ctx.camera.centerCoordinate
                        }
                }

                // The crosshair. Offset up by half its own height so the point
                // of the pin, not the middle of the glyph, sits on the map
                // centre the camera reports.
                Image(systemName: "mappin")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .shadow(radius: 3)
                    .offset(y: -17)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .navigationTitle(label.isEmpty ? "Pin setzen" : label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hier setzen") {
                        if let center { onPick(center) }
                        dismiss()
                    }
                    .disabled(!isPlausible)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(coordinateLabel)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 8)
            }
            .onAppear {
                camera = .region(
                    MKCoordinateRegion(
                        center: initial,
                        span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
                center = initial
            }
        }
    }

    private var isPlausible: Bool {
        guard let center else { return false }
        return Coordinates.isPlausible(lat: center.latitude, lon: center.longitude)
    }

    private var coordinateLabel: String {
        guard let center else { return "—" }
        return String(format: "%.5f, %.5f", center.latitude, center.longitude)
    }
}
