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
    @State private var telefon = ""
    /// A pin dropped in *this* editing session.
    @State private var droppedPin: CLLocationCoordinate2D?
    /// Set by "Pin verwerfen": on save the address is looked up again even
    /// though it has not changed, which is the only way back from a hand-placed
    /// pin to whatever the register says.
    @State private var discardStoredPin = false
    @State private var showingPinDrop = false
    @State private var saving = false
    /// The in-flight save, kept so "Abbrechen" can call it off.
    ///
    /// Looking an address up is not quick and is not bounded by anything the
    /// driver can see: the cascade is the register, then the register again
    /// without the district, then up to two throttled Nominatim calls, and only
    /// then the re-optimization of the whole tour. An address none of them can
    /// place walks the entire chain — over a minute, measured, on a good
    /// connection — and a van on bad LTE is worse. That has to be interruptible.
    @State private var saveTask: Task<Void, Never>?
    /// Set by the watchdog in `save()` just before it cancels, so the catch can
    /// tell "this ran out of time" from "the driver pressed Abbrechen".
    @State private var budgetExpired = false
    @State private var confirmingDelete = false
    @State private var error: AppError?
    @State private var loaded = false

    /// The five fields as they were when the sheet opened, so "Abbrechen" can
    /// tell a look from an edit.
    private struct Draft: Equatable {
        var kunde = "", strasse = "", plz = "", paket = "", notiz = "", telefon = ""
    }
    @State private var original = Draft()
    @State private var confirmingDiscard = false

    @FocusState private var focusedField: Field?
    /// What the postcode field held when the driver tapped into it — see
    /// `plzField`.
    @State private var plzBeforeEditing = ""

    private enum Field: Hashable { case kunde, telefon, strasse, plz, paket, notiz }

    private var isEditing: Bool { stop != nil }

    /// True when this stop will keep a hand-placed position — either one just
    /// dropped, or one already stored and not discarded.
    private var hasManualPin: Bool {
        droppedPin != nil || (stop?.pinned == true && !discardStoredPin)
    }

    /// What the fields say now. The postcode as it was before the field was
    /// emptied for typing — see `plzField` — so tapping into it is not itself
    /// an edit.
    private var draft: Draft {
        Draft(
            kunde: kunde, strasse: strasse,
            plz: focusedField == .plz && plz.isEmpty ? plzBeforeEditing : plz,
            paket: paket, notiz: notiz, telefon: telefon)
    }

    /// Anything typed or placed that closing the sheet would throw away.
    private var hasChanges: Bool {
        loaded && (draft != original || droppedPin != nil || discardStoredPin)
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
                        .onSubmit { focusedField = .telefon }
                        .limited(to: FieldLimits.kunde, text: $kunde)
                    TextField("Telefon", text: $telefon)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .telefon)
                        .onSubmit { focusedField = .strasse }
                        .limited(to: FieldLimits.telefon, text: $telefon)
                }

                Section {
                    TextField("Straße und Hausnummer", text: $strasse)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .strasse)
                        .onSubmit { focusedField = .plz }
                        .limited(to: FieldLimits.strasse, text: $strasse)
                    plzField
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
                        Button(role: .destructive) {
                            droppedPin = nil
                            // A pin already on the stop needs the *lookup* to be
                            // forced on save; simply forgetting it here would
                            // leave the hand-placed coordinates in place with
                            // nothing having changed to trigger a re-geocode.
                            if stop?.pinned == true { discardStoredPin = true }
                        } label: {
                            // Red on the glyph too — see "Stopp löschen" below.
                            Label("Pin verwerfen, Adresse suchen", systemImage: "arrow.uturn.backward")
                                .foregroundStyle(.red)
                        }
                    }
                }

                if let stop, stop.kind == .customer {
                    Section {
                        // "Navigation starten", as it is everywhere else in the
                        // app. "In Karten öffnen" named Apple's app — and on a
                        // phone set to Waze it opened Waze.
                        Button(
                            "Navigation starten",
                            systemImage: "arrow.trianglehead.turn.up.right"
                        ) {
                            if let url = NavigationHandoff.url(for: stop) { openURL(url) }
                        }
                        // Off the field being typed here, not off the stored
                        // value — so a number just corrected can be called
                        // straight away, before the field is even saved.
                        if let url = PhoneNumbers.dialURL(for: telefon) {
                            Button("Anrufen", systemImage: "phone") { openURL(url) }
                        }
                    }
                }

                if isEditing, let onDelete {
                    Section {
                        // The role colours the *title* red and leaves the glyph
                        // on the sheet's accent, so the destructive button came
                        // out half blue and half red. `.tint(.red)` was the old
                        // cure and no longer reaches the icon on iOS 26; a
                        // foreground style on the label itself colours both.
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Stopp löschen", systemImage: "trash")
                                .foregroundStyle(.red)
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
            // Locks the fields — they must not change under a lookup already
            // using them — and sits here, under the toolbar in the chain,
            // rather than over it, so that it does not also reach Abbrechen.
            .disabled(saving)
            // Short on purpose. "Stopp bearbeiten" between the two glass toolbar
            // buttons truncated to "Stopp bearb…", which looks like a bug in a
            // screen whose whole job is careful data entry.
            .navigationTitle(isEditing ? "Stopp" : "Neuer Stopp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Stays live while a save is in flight, and calls it off.
                    // `.disabled(saving)` used to cover this button too, which
                    // left the sheet with no way out at all for as long as the
                    // lookup took — the driver's only remaining move was to
                    // force-quit the app.
                    //
                    // And asks before throwing work away, the question every
                    // editing sheet on this phone asks. A Notiz can be a
                    // paragraph typed at a door with one thumb, and it went
                    // with a single tap on the button nearest that thumb.
                    Button("Abbrechen") {
                        if saving {
                            saveTask?.cancel()
                            dismiss()
                        } else if hasChanges {
                            confirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                    .confirmationDialog(
                        "Änderungen verwerfen?", isPresented: $confirmingDiscard,
                        titleVisibility: .visible
                    ) {
                        Button("Änderungen verwerfen", role: .destructive) { dismiss() }
                        Button("Weiter bearbeiten", role: .cancel) {}
                    }
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
                            saveTask = Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            // A swipe would leave the work running with nothing left to report
            // to. Abbrechen is the deliberate way out, and it cancels. Held
            // too while there is anything unsaved, for the same reason
            // Abbrechen asks: a swipe is the easiest gesture there is to make
            // by accident.
            .interactiveDismissDisabled(saving || hasChanges)
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
                    label: kunde.isEmpty ? strasse : kunde,
                    plz: plz
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
            // Loaded once. `onAppear` can fire again when a sheet presented
            // over this one goes away — and the sheet presented over this one is
            // the pin-drop map, so re-running this would throw away everything
            // the driver had typed before they went to place the pin.
            .task {
                guard !loaded else { return }
                loaded = true
                load()
            }
        }
    }

    /// The postcode: typed, with the 23 Vienna districts one tap away.
    ///
    /// This was a `Picker` over those 23 and nothing else, which is what made
    /// the app Vienna-only from the driver's side — there was no way to *enter*
    /// a Gerasdorf address, whatever the geocoder might have done with one. A
    /// plain field takes any Austrian postcode, and the menu keeps the tour's
    /// everyday districts to a single tap rather than four digits.
    ///
    /// The district's name is echoed beside the field rather than left to the
    /// footer: a mistyped "1120" for "1210" is two real districts on opposite
    /// sides of the city, and "12. Meidling" appearing where the driver
    /// expected Floridsdorf is the only thing on this screen that catches it.
    private var plzField: some View {
        LabeledContent("PLZ") {
            HStack(spacing: 10) {
                if let name = Districts.name(for: plz) {
                    Text(name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                TextField("1210", text: $plz)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .plz)
                    .limited(to: 4, text: $plz)
                    .frame(width: 58)
                    // Emptied on focus, put back if nothing was typed.
                    //
                    // The field arrives prefilled with four digits and is
                    // capped at four, so tapping it and typing "2201" did
                    // nothing at all — every keystroke was over the limit, and
                    // the driver had to work out that four backspaces came
                    // first. Clearing on focus is what a stepper-sized numeric
                    // field does everywhere else; restoring on an untouched
                    // blur is what keeps a stray tap from wiping the district.
                    .onChange(of: focusedField) { was, now in
                        if now == .plz {
                            plzBeforeEditing = plz
                            plz = ""
                        } else if was == .plz, plz.isEmpty {
                            plz = plzBeforeEditing
                        }
                    }
                Menu {
                    ForEach(Districts.all) { d in
                        Button("\(d.plz) — \(d.label)") { plz = d.plz }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(width: 30, height: 30)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Wiener Bezirk wählen")
            }
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
            Label(p.label, systemImage: p.symbol)
                .labelStyle(TintedIconLabelStyle(tint: .attention))
        }
    }

    private var canSave: Bool {
        !kunde.trimmed.isEmpty && !strasse.trimmed.isEmpty && Postcodes.isValid(plz)
    }

    private func load() {
        guard let stop else {
            // A new stop starts in whatever district the last one was in — a
            // tour is usually a handful of neighbouring districts, so this is
            // right far more often than not.
            plz = route.customerStops.last?.plz ?? ""
            original = draft
            return
        }
        kunde = stop.kunde ?? ""
        strasse = stop.strasse ?? ""
        plz = stop.plz ?? ""
        paket = stop.paket ?? ""
        notiz = stop.notiz ?? ""
        telefon = stop.telefon ?? ""
        original = draft
    }

    /// How long a driver is asked to wait for an address before the app gives
    /// up and offers the pin instead.
    ///
    /// A findable address costs one register call, or nothing at all when it is
    /// cached. This budget only ever runs out on an address the register does
    /// not have, where the rest of the cascade behind it — the register again
    /// without the district, two throttled Nominatim calls, a district-centre
    /// fallback, and then the re-optimization of the whole tour — measured at
    /// over a minute end to end on a good connection. That is a bad trade for
    /// someone standing at a van with a route to drive, and the answer it
    /// eventually arrives at is a district-centre guess the driver would place
    /// better by hand anyway.
    private static let saveBudgetSeconds = 30

    private func save() async {
        saving = true
        budgetExpired = false

        // Cancels the save from the outside once the budget is spent. A
        // watchdog rather than a deadline threaded through the services: the
        // budget is a property of *this screen* — the import behind the same
        // geocoder is right to be patient — and cancellation is what the
        // services already understand.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(Self.saveBudgetSeconds))
            guard !Task.isCancelled else { return }
            budgetExpired = true
            saveTask?.cancel()
        }
        defer {
            watchdog.cancel()
            saving = false
        }

        let coordinate = droppedPin.map { (lat: $0.latitude, lon: $0.longitude) }
        do {
            if let stop {
                try await RouteStore.updateStop(
                    stop, kunde: kunde, strasse: strasse, plz: plz,
                    paket: paket, notiz: notiz, telefon: telefon, coordinate: coordinate,
                    forceGeocode: discardStoredPin, in: context)
            } else {
                try await RouteStore.addStop(
                    to: route, kunde: kunde, strasse: strasse, plz: plz,
                    paket: paket, notiz: notiz, telefon: telefon, coordinate: coordinate,
                    in: context)
            }
            dismiss()
        } catch {
            // Checked before the error itself, because a cancelled lookup does
            // not always surface as `CancellationError` — the geocoder reports
            // an unreachable service for anything its URL session throws, and
            // "der Geocoder ist nicht erreichbar" is the wrong thing to tell a
            // driver whose address simply took too long.
            if budgetExpired {
                self.error = AppError.message(
                    "„\(strasse.trimmed)“ konnte in \(Self.saveBudgetSeconds) Sekunden nicht "
                        + "gefunden werden. Prüf die Schreibweise und den Bezirk — oder setz "
                        + "den Pin von Hand auf der Karte.")
            } else if error is CancellationError {
                // Abbrechen. The sheet is already on its way out and the driver
                // knows what they did; an alert here would be the app arguing
                // with them.
                return
            } else if let e = error as? AppError {
                self.error = e
            } else {
                self.error = AppError.message("Konnte den Stopp nicht speichern.")
            }
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
    /// The stop's postcode, which is what decides how far the pin may be
    /// dropped from it — the same rule `RouteStore.checkPin` applies on save.
    /// Passed in so "Hier setzen" greys out where the save would refuse,
    /// rather than taking the pin and failing a screen later.
    var plz: String = ""
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
                    .foregroundStyle(Color.accentColor)
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
        return Coordinates.isPlausible(
            lat: center.latitude, lon: center.longitude, forPlz: plz)
    }

    private var coordinateLabel: String {
        guard let center else { return "—" }
        return String(
            format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
            center.latitude, center.longitude)
    }
}
