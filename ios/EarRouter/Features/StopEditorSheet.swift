import SwiftUI
import SwiftData
import MapKit

/// Add or edit one customer stop. Also the way into the pin-drop map, which is
/// what a driver reaches for when the geocoder cannot place an address — or has
/// placed it on the wrong side of a Gemeindebau.
struct StopEditorSheet: View {
    let route: Route
    let stop: Stop?
    /// Supplied by the presenting screen, which owns both the deletion and the
    /// dismissal. Deleting the model object from in here while this sheet is
    /// still bound to it would leave the sheet rendering a row that no longer
    /// exists.
    var onDelete: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var kunde = ""
    @State private var strasse = ""
    @State private var plz = ""
    @State private var paket = ""
    @State private var notiz = ""
    /// A pin dropped in *this* editing session.
    @State private var droppedPin: CLLocationCoordinate2D?
    /// Set by "Pin verwerfen": on save the address is looked up again even
    /// though it has not changed, which is the only way back from a hand-placed
    /// pin to whatever the register says.
    @State private var discardStoredPin = false
    @State private var showingPinDrop = false
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: AppError?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case kunde, strasse, paket, notiz }

    private var isEditing: Bool { stop != nil }

    /// True when this stop will keep a hand-placed position — either one just
    /// dropped, or one already stored and not discarded.
    private var hasManualPin: Bool {
        droppedPin != nil || (stop?.pinned == true && !discardStoredPin)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Kunde") {
                    TextField("Name", text: $kunde)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .kunde)
                        .onSubmit { focusedField = .strasse }
                        .limited(to: FieldLimits.kunde, text: $kunde)
                }

                Section {
                    TextField("Straße und Hausnummer", text: $strasse)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .strasse)
                        .onSubmit { focusedField = .paket }
                        .limited(to: FieldLimits.strasse, text: $strasse)
                    Picker("Bezirk", selection: $plz) {
                        Text("Bitte wählen").tag("")
                        ForEach(Districts.all) { d in
                            Text("\(d.plz) — \(d.label)").tag(d.plz)
                        }
                    }
                } header: {
                    Text("Adresse")
                } footer: {
                    addressFooter
                }

                Section {
                    TextField("Paket (z. B. 2x Menü)", text: $paket)
                        // Both fields carry door codes, Stiege numbers and
                        // shorthand that no dictionary knows. Autocorrect
                        // silently rewrote a typed "Tuercode ENVV" to "Zürcher
                        // ENVV" — and a quietly corrupted door code is a driver
                        // standing outside a building they cannot get into.
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .paket)
                        .onSubmit { focusedField = .notiz }
                        .limited(to: FieldLimits.paket, text: $paket)
                    TextField("Notiz", text: $notiz, axis: .vertical)
                        .lineLimit(2...6)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .notiz)
                        .limited(to: FieldLimits.notiz, text: $notiz)
                } header: {
                    Text("Lieferung")
                } footer: {
                    Text("Autokorrektur ist hier aus — Türcodes und Stiegen bleiben, wie du sie tippst.")
                }

                Section {
                    Button("Pin auf der Karte setzen", systemImage: "mappin.and.ellipse") {
                        showingPinDrop = true
                    }
                    if hasManualPin {
                        Button(
                            "Pin verwerfen, Adresse suchen",
                            systemImage: "arrow.uturn.backward", role: .destructive
                        ) {
                            droppedPin = nil
                            // A pin already on the stop needs the *lookup* to be
                            // forced on save; simply forgetting it here would
                            // leave the hand-placed coordinates in place with
                            // nothing having changed to trigger a re-geocode.
                            if stop?.pinned == true { discardStoredPin = true }
                        }
                    }
                }

                if let stop, stop.kind == .customer {
                    Section {
                        Button(
                            "In Karten öffnen",
                            systemImage: "arrow.trianglehead.turn.up.right"
                        ) {
                            if let url = NavigationHandoff.url(for: stop) { openURL(url) }
                        }
                    }
                }

                if isEditing, let onDelete {
                    Section {
                        Button("Stopp löschen", systemImage: "trash", role: .destructive) {
                            confirmingDelete = true
                        }
                        .frame(maxWidth: .infinity)
                        .confirmationDialog(
                            "Stopp löschen?", isPresented: $confirmingDelete,
                            titleVisibility: .visible
                        ) {
                            Button("Löschen", role: .destructive, action: onDelete)
                            Button("Abbrechen", role: .cancel) {}
                        } message: {
                            Text("„\(kunde.isEmpty ? "Dieser Stopp" : kunde)“ wird aus der Tour entfernt.")
                        }
                    }
                }
            }
            // Short on purpose. "Stopp bearbeiten" between the two glass toolbar
            // buttons truncated to "Stopp bearb…", which looks like a bug in a
            // screen whose whole job is careful data entry.
            .navigationTitle(isEditing ? "Stopp" : "Neuer Stopp")
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
                    initial: droppedPin
                        ?? stop?.coordinate
                        ?? Districts.byPlz[plz].map {
                            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                        }
                        ?? CLLocationCoordinate2D(
                            latitude: Coordinates.viennaCenter.lat,
                            longitude: Coordinates.viennaCenter.lon),
                    label: kunde.isEmpty ? strasse : kunde
                ) { coordinate in
                    droppedPin = coordinate
                    discardStoredPin = false
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

    @ViewBuilder
    private var addressFooter: some View {
        if droppedPin != nil {
            Label(
                "Pin von Hand gesetzt — die Adresse wird nicht neu gesucht.",
                systemImage: "hand.point.up.left.fill")
        } else if stop?.pinned == true && !discardStoredPin {
            Label(
                "Position von Hand gesetzt — die Adresse wird nicht neu gesucht.",
                systemImage: "hand.point.up.left.fill")
        } else if discardStoredPin {
            Label(
                "Der Pin wird beim Sichern verworfen und die Adresse neu gesucht.",
                systemImage: "magnifyingglass")
        } else if let p = stop?.precision {
            Label(p.label, systemImage: p.symbol).foregroundStyle(Color.warning)
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

        let coordinate = droppedPin.map { (lat: $0.latitude, lon: $0.longitude) }
        do {
            if let stop {
                try await RouteStore.updateStop(
                    stop, kunde: kunde, strasse: strasse, plz: plz,
                    paket: paket, notiz: notiz, coordinate: coordinate,
                    forceGeocode: discardStoredPin, in: context)
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

extension View {
    /// Stops a field growing past what the store and the upstream services
    /// accept, while it is being typed rather than after a round trip — which
    /// is what `FieldLimits` was always documented to do.
    ///
    /// Truncation is silent by design: the limits are far past any real
    /// customer name or door note, so anything that hits one is a paste
    /// accident, and an alert about it would be noise.
    func limited(to max: Int, text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, new in
            if new.count > max { text.wrappedValue = String(new.prefix(max)) }
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
                Map(position: $camera)
                    .mapStyle(.standard(elevation: .flat))
                    .onMapCameraChange(frequency: .continuous) { ctx in
                        center = ctx.camera.centerCoordinate
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
                VStack(spacing: 2) {
                    Text("Die Karte unter dem Pin bewegen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(coordinateLabel)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
        return String(
            format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
            center.latitude, center.longitude)
    }
}
