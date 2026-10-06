import SwiftUI
import SwiftData

/// Settings, shaped the way Settings.app is: the things used daily at the top,
/// the technical ones behind a disclosure, and credits on their own screen.
///
/// The server URL and its connection test used to sit at this level, which made
/// the app's own settings read like a debug panel. Nothing here is something a
/// driver has to understand to do their job.
struct MoreTab: View {
    @AppStorage(NavigationHandoff.providerKey) private var providerRaw =
        NavigationHandoff.Provider.apple.rawValue

    @AppStorage(CarPlayNavigation.enabledKey) private var carPlayEnabled = false

    @State private var showingTuercode = false
    @State private var showingKilometer = false
    @State private var showingGourmet = false
    @State private var showingCarPlaySetup = false
    @State private var showingSplit = false

    /// The driver's own dispatch portal — the customer list this app's stops
    /// are copied out of in the first place.
    private let gourmetURL = URL(string: "https://zusteller.gourmet-daheim.at/#/customers")!

    var body: some View {
        List {
            // A tint per row, which is what Settings.app does and what makes a
            // settings list findable: after a week the driver reaches for the
            // brown tile, not for the third row down. These were all one colour
            // — defensible when that colour was the app's own indigo and
            // nothing else on the screen wore it, and wrong now that the accent
            // is the system blue every tappable thing in the app is drawn in.
            Section("Zusteller-Tools") {
                Button {
                    showingGourmet = true
                } label: {
                    SettingsRow(
                        icon: "square.grid.2x2.fill", tint: .purple, title: "Gourmet",
                        detail: "Kundenliste öffnen")
                }
                Button {
                    showingSplit = true
                } label: {
                    SettingsRow(
                        icon: "lasso", tint: .orange, title: "Tour aufteilen",
                        detail: "Stopps auf der Karte verteilen")
                }
                Button {
                    showingTuercode = true
                } label: {
                    SettingsRow(
                        icon: "key.fill", tint: .indigo, title: "Türcode",
                        detail: "Buchstaben in Ziffern")
                }
                Button {
                    showingKilometer = true
                } label: {
                    SettingsRow(
                        icon: "gauge.with.dots.needle.bottom.50percent", tint: .teal,
                        title: "Kilometerstand", detail: "Gefahrene Kilometer")
                }
            }

            Section {
                Picker(selection: $providerRaw) {
                    ForEach(NavigationHandoff.Provider.allCases) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                } label: {
                    SettingsRow(
                        icon: "location.fill", tint: .blue, title: "Navigation")
                }
            } footer: {
                Text("Womit „Navigation starten“ öffnet.")
            }

            // Under the navigation picker, because it is the same handover —
            // the same stop, the same maps app — just started by the car
            // instead of by a thumb.
            Section {
                Toggle(isOn: $carPlayEnabled) {
                    SettingsRow(
                        icon: "car.fill", tint: .mint, title: "CarPlay-Navigation",
                        detail: "Beim Anstecken zum nächsten Stopp")
                }
            } footer: {
                Text(
                    "iOS lässt die App das nicht von selbst starten — das übernimmt eine "
                        + "Automation in „Kurzbefehle“, die einmal eingerichtet wird. "
                        + "Dieser Schalter ist der Hauptschalter dafür.")
            }

            Section {
                NavigationLink {
                    StockwerkListView()
                } label: {
                    SettingsRow(
                        icon: "stairs", tint: .brown, title: "Globale Infos",
                        detail: "Stockwerke und Notizen")
                }
                NavigationLink {
                    BackupView()
                } label: {
                    SettingsRow(
                        icon: "externaldrive.fill", tint: .green, title: "Sicherung",
                        detail: "Alle Daten sichern und laden")
                }
            } footer: {
                Text("Touren, Stopps und globale Infos liegen nur auf diesem Gerät.")
            }

            Section {
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    SettingsRow(icon: "gearshape.fill", tint: .gray, title: "Erweitert")
                }
                NavigationLink {
                    AboutView()
                } label: {
                    // `.gray`, not `.secondary`: the hierarchical grey is a
                    // translucent *label* colour, and in dark mode it resolves
                    // to a pale tile the white glyph all but disappears into.
                    SettingsRow(icon: "info.circle.fill", tint: .gray, title: "Über EAR Router")
                }
            }

            if let expiry = SideloadExpiry.expiresAt {
                Section {
                    SideloadExpiryRow(expiry: expiry)
                } footer: {
                    Text(
                        "Diese Version wurde über Xcode installiert und gilt sieben Tage. "
                            + "Am Abend davor meldet sich die App von selbst — danach lässt "
                            + "sie sich nicht mehr öffnen.")
                }
            }
        }
        .navigationTitle("Mehr")
        .sheet(isPresented: $showingTuercode) { TuercodeSheet() }
        .sheet(isPresented: $showingKilometer) { KilometerSheet() }
        .sheet(isPresented: $showingSplit) { TourSplitSheet() }
        .sheet(isPresented: $showingGourmet) {
            SafariView(url: gourmetURL).ignoresSafeArea()
        }
        .sheet(isPresented: $showingCarPlaySetup) { CarPlaySetupSheet() }
        // The switch is the only control here, and switching it on is what
        // brings the instructions up — there is no second row to tap, because
        // there is nothing to set up that turning it on does not already mean.
        // Without the automation the switch does nothing at all, and a driver
        // who turns it on and drives off tomorrow would find that out in the
        // van.
        .onChange(of: carPlayEnabled) { _, on in
            if on { showingCarPlaySetup = true }
        }
    }
}

/// A Settings.app row: a tinted icon tile, a title, and an optional grey
/// detail. The tile is what makes a settings list read as a settings list
/// rather than as a stack of plain text buttons.
struct SettingsRow: View {
    let icon: String
    var tint: Color = .gray
    let title: String
    var detail: String?

    /// The tile grows with the text, the way Settings.app's does. Held at a
    /// fixed 29 it turned into a speck beside 34pt type at an accessibility
    /// size — and the tile is the thing a driver aims at after the first week,
    /// so it is the last part of the row that should shrink away.
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 29

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: tile * 0.52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(tint, in: .rect(cornerRadius: tile * 0.24))

            VStack(alignment: .leading, spacing: 1) {
                // `Color.primary`, not `.primary`. The hierarchical styles
                // resolve against the *current* foreground style, which inside a
                // Button is the accent colour — so a settings row rendered its
                // label in red and its detail in a lighter red. The concrete
                // colours are what make this read as a settings row rather than
                // as a link.
                Text(title).foregroundStyle(Color.primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

/// How long this sideloaded build has left, counting down in place.
///
/// It sits at the top level of Mehr rather than inside Über because it is not a
/// piece of trivia about the build — it is a deadline, and one the driver is the
/// only person who can act on.
///
/// The countdown moves on its own. The Mehr tab is built once and survives every
/// tab switch after that, so a number rendered on Monday would still say "Noch 6
/// Tage" on Thursday; a stale deadline is worse than no deadline, because it is
/// believed.
private struct SideloadExpiryRow: View {
    let expiry: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let left = SideloadExpiry.remaining(until: expiry, now: context.date)

            HStack(spacing: 12) {
                SettingsRow(
                    icon: left.isUrgent ? "exclamationmark.triangle.fill" : "hourglass",
                    tint: left.isUrgent ? .attention : .gray,
                    title: "Läuft ab",
                    detail: expiry.formatted(date: .abbreviated, time: .shortened))

                Spacer(minLength: 8)

                // Secondary either way. The amber that reads as a tinted icon
                // tile is about 2:1 against a list background, which is not a
                // colour to put a number in — the tile beside it is already
                // carrying the urgency.
                Text(left.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            // Combined, so VoiceOver reads "Läuft ab, 11.09.2026, 16:04, Noch 6
            // Tage" as one row instead of three unrelated fragments. Written
            // out rather than overridden, because a hand-written label would
            // have to special-case "Abgelaufen" to avoid "läuft ab in
            // abgelaufen".
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Erweitert

/// Everything technical, on its own screen. A driver never has to come here;
/// it exists for the one day the routing server moves.
struct AdvancedSettingsView: View {
    @AppStorage(Upstreams.Keys.osrmURL) private var osrmURL = ""

    @State private var cacheCount = 0
    @State private var status: ConnectionStatus = .idle
    @State private var confirmingCacheClear = false
    /// The toilets the map can show — see `RestroomUpdater`.
    @State private var restrooms = RestroomCatalog.shared.current
    @State private var updatingRestrooms = false
    @State private var error: AppError?

    enum ConnectionStatus: Equatable {
        case idle, checking, reachable(ms: Int), unreachable

        var label: String? {
            switch self {
            case .idle: nil
            case .checking: "Wird geprüft …"
            case .reachable(let ms): "Erreichbar · \(ms) ms"
            case .unreachable: "Nicht erreichbar"
            }
        }

        var tint: Color {
            switch self {
            case .reachable: .delivered
            case .unreachable: .attention
            default: .secondary
            }
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Server") {
                    Text(effectiveHost)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let label = status.label {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            if status == .checking { ProgressView().controlSize(.small) }
                            Text(label).foregroundStyle(status.tint)
                        }
                    }
                }
                Button("Verbindung testen") { Task { await check() } }
                    .disabled(status == .checking)
            } header: {
                Text("Routenoptimierung")
            } footer: {
                Text(
                    "Geprüft wird genau dieser Server. Ist er nicht erreichbar, weicht die "
                        + "App beim Routen automatisch auf den öffentlichen OSRM-Demoserver "
                        + "aus — die Routenoptimierung funktioniert also weiter.")
            }

            Section {
                TextField(
                    "Eigene Adresse", text: $osrmURL,
                    prompt: Text(Upstreams.defaultOSRM.absoluteString))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onChange(of: osrmURL) { status = .idle }
                if !osrmURL.isEmpty {
                    Button("Auf Standard zurücksetzen", role: .destructive) {
                        osrmURL = ""
                        status = .idle
                    }
                }
            } header: {
                // Without a header this field sat between two titled sections
                // belonging to neither of them.
                Text("Eigener Server")
            } footer: {
                // An address the app cannot parse is silently ignored and the
                // default used instead — correct behaviour, and completely
                // invisible. Typing "osrm.example.com" with no scheme, or
                // fumbling the colon on a phone keyboard, looked exactly like a
                // setting that had been accepted.
                if !osrmURL.isEmpty && !Upstreams.isUsableOverride(osrmURL) {
                    Label(
                        "Keine gültige Adresse — es wird der Standardserver verwendet. "
                            + "Erwartet wird etwas wie https://osrm.example.com",
                        systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(TintedIconLabelStyle(tint: .attention))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Leer lassen für den Standardserver.")
                }
            }

            Section {
                LabeledContent("Gespeicherte Adressen", value: "\(cacheCount)")
                Button("Cache leeren", role: .destructive) { confirmingCacheClear = true }
                    .disabled(cacheCount == 0)
            } header: {
                Text("Adressen")
            } footer: {
                Text(
                    "Gefundene Adressen werden dauerhaft gespeichert, damit dieselbe Tür nie "
                        + "zweimal gesucht werden muss. Nur leeren, wenn eine Adresse "
                        + "tatsächlich umgezogen ist.")
            }

            Section {
                LabeledContent("Standorte", value: "\(restrooms.all.count)")
                LabeledContent(
                    "Stand",
                    value: restrooms.updatedAt.map(Format.date) ?? "Mit der App geliefert")
                Button {
                    Task { await updateRestrooms() }
                } label: {
                    HStack(spacing: 8) {
                        Text("WC-Daten aktualisieren")
                        if updatingRestrooms { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(updatingRestrooms)
            } header: {
                Text("WCs")
            } footer: {
                Text(
                    "Lädt die öffentlichen WCs der Stadt Wien und die öKlos neu. "
                        + "Einmal im Monat reicht – neue kommen selten dazu.")
            }

            // Last, and one level down from Mehr: needed once in a long while.
            Section {
                NavigationLink {
                    PortalExportView()
                } label: {
                    Label("TK-Touren holen", systemImage: "tray.and.arrow.down")
                }
            } header: {
                Text("Rückblick")
            } footer: {
                Text("Ganze TK-Touren vergangener Tage aus dem Portal, als Datei.")
            }
        }
        .errorAlert($error)
        .navigationTitle("Erweitert")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Cache leeren?", isPresented: $confirmingCacheClear, titleVisibility: .visible
        ) {
            Button("Leeren", role: .destructive) {
                Task {
                    await GeocodeCache.shared.clear()
                    cacheCount = await GeocodeCache.shared.count
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("\(cacheCount) Adressen werden beim nächsten Mal neu gesucht.")
        }
        .task { cacheCount = await GeocodeCache.shared.count }
    }

    private func updateRestrooms() async {
        updatingRestrooms = true
        defer { updatingRestrooms = false }
        do {
            try await RestroomUpdater.refresh()
            restrooms = RestroomCatalog.shared.current
        } catch let known as AppError {
            error = known
        } catch {
            self.error = AppError.message("Die WC-Daten konnten nicht geladen werden.")
        }
    }

    private var effectiveHost: String {
        Upstreams.current.osrm.host ?? Upstreams.current.osrm.absoluteString
    }

    /// Tests the server named right above the button, and only that one.
    ///
    /// `OSRMClient.probe` rather than an ordinary routing call: the ordinary
    /// path falls back to the public demo server whenever the configured one
    /// cannot answer, which is right for routing and wrong for a test — it
    /// reported "Erreichbar" for a server that was down, because something else
    /// had replied.
    private func check() async {
        status = .checking
        let started = Date()
        let ok = await OSRMClient.shared.probe(base: Upstreams.current.osrm)
        status = ok
            ? .reachable(ms: Int(Date().timeIntervalSince(started) * 1000))
            : .unreachable
    }
}

// MARK: - Über

struct AboutView: View {
    private let developerEmail = URL(string: "mailto:nikolaus.marek@outlook.com")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("AppMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(.rect(cornerRadius: 17, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(.primary.opacity(0.08), lineWidth: 0.5))

                    VStack(spacing: 3) {
                        Text("EAR Router").font(.title3.weight(.semibold))
                        Text("Version \(version)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Für die Essen-auf-Rädern-Touren des\nArbeiter-Samariter-Bundes Österreichs")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .listRowBackground(Color.clear)
            }

            Section("Entwickelt von") {
                Link(destination: developerEmail) {
                    SettingsRow(
                        icon: "envelope.fill", tint: .blue, title: "Nikolaus Marek",
                        detail: "nikolaus.marek@outlook.com")
                }
            }

            Section {
                LabeledContent("Tourdaten", value: "Zusteller-Portal")
                LabeledContent("Karten", value: "Apple Maps")
                LabeledContent("Adressregister", value: "Stadt Wien")
                LabeledContent("Öffentliche WCs", value: "Stadt Wien, öKlo")
                LabeledContent("Geocoder", value: "Nominatim")
                LabeledContent("Routing", value: "OSRM")
            } header: {
                Text("Daten")
            } footer: {
                Text("Nominatim-Daten © OpenStreetMap-Mitwirkende, ODbL.")
            }

            Section {
                Label("Alles bleibt auf dem Gerät", systemImage: "lock.fill")
                    .font(.footnote.weight(.medium))
            } footer: {
                Text(
                    "Touren, Stopps und Lieferstatus werden nirgends hochgeladen. Internet "
                        + "braucht nur das Laden vom Zusteller-Portal, die Adresssuche und "
                        + "die Routenoptimierung.")
            }
        }
        .navigationTitle("Über")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
