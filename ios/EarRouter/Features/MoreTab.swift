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

    @State private var showingTuercode = false
    @State private var showingGourmet = false

    /// The driver's own dispatch portal — the customer list this app's stops
    /// are copied out of in the first place.
    private let gourmetURL = URL(string: "https://zusteller.gourmet-daheim.at/#/customers")!

    var body: some View {
        List {
            Section("Zusteller-Tools") {
                Button {
                    showingGourmet = true
                } label: {
                    SettingsRow(
                        icon: "square.grid.2x2.fill", tint: .brand, title: "Gourmet",
                        detail: "Kundenliste öffnen")
                }
                Button {
                    showingTuercode = true
                } label: {
                    SettingsRow(
                        icon: "key.fill", tint: .indigo, title: "Türcode",
                        detail: "Buchstaben in Ziffern")
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

            Section {
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    SettingsRow(icon: "gearshape.fill", tint: .gray, title: "Erweitert")
                }
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRow(icon: "info.circle.fill", tint: .secondary, title: "Über EAR Router")
                }
            }
        }
        .navigationTitle("Mehr")
        .sheet(isPresented: $showingTuercode) { TuercodeSheet() }
        .sheet(isPresented: $showingGourmet) {
            SafariView(url: gourmetURL).ignoresSafeArea()
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint, in: .rect(cornerRadius: 7))

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

// MARK: - Erweitert

/// Everything technical, on its own screen. A driver never has to come here;
/// it exists for the one day the routing server moves.
struct AdvancedSettingsView: View {
    @AppStorage(Upstreams.Keys.osrmURL) private var osrmURL = ""

    @State private var cacheCount = 0
    @State private var status: ConnectionStatus = .idle
    @State private var confirmingCacheClear = false

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
            case .reachable: .success
            case .unreachable: .warning
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
                    "Ist der Server nicht erreichbar, weicht die App automatisch auf den "
                        + "öffentlichen OSRM-Demoserver aus.")
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
            } footer: {
                Text("Leer lassen für den Standardserver.")
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
        }
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

    private var effectiveHost: String {
        Upstreams.current.osrm.host ?? Upstreams.current.osrm.absoluteString
    }

    private func check() async {
        status = .checking
        let started = Date()
        do {
            // Two points on the Ring — a query every OSRM build can answer.
            _ = try await OSRMClient.shared.routeLeg(
                from: (48.2082, 16.3738), to: (48.2170, 16.3919))
            status = .reachable(ms: Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            status = .unreachable
        }
    }
}

// MARK: - Über

struct AboutView: View {
    private let developerEmail = URL(string: "mailto:nikolaus.marek@outlook.com")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image("ASBOLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(.rect(cornerRadius: 17))
                        .overlay(
                            RoundedRectangle(cornerRadius: 17)
                                .stroke(.primary.opacity(0.08), lineWidth: 0.5))

                    VStack(spacing: 3) {
                        Text("EAR Router").font(.title3.weight(.semibold))
                        Text("Version \(version)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("Ein Service des Arbeiter-Samariter-Bundes Österreichs")
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
                LabeledContent("Karten", value: "Apple Maps")
                LabeledContent("Adressregister", value: "Stadt Wien")
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
                        + "braucht nur die Adresssuche und die Routenoptimierung.")
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
