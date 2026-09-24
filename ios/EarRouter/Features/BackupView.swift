import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Sicherung — the whole store out to a file, and back in from one.
///
/// This app keeps everything on the phone and sends none of it anywhere, which
/// is the right trade for a list of customers' names and addresses. The cost of
/// that trade is that a dropped phone takes the lot: every tour ever driven and
/// — now that the app remembers them — every floor ever learned. This is the
/// other half of the deal.
struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(RouteFocus.self) private var focus

    @Query private var routes: [Route]
    @Query private var stockwerkNotes: [StockwerkNote]

    /// The written backup file, waiting for the share sheet.
    @State private var sharing: SharedFile?
    @State private var importing = false
    /// True while the store is being read and written out.
    @State private var busy = false
    /// A decoded file waiting for the driver to say how it should be applied.
    @State private var pending: BackupArchive?
    @State private var confirmingReplace = false
    @State private var result: String?
    @State private var error: AppError?

    private var stopCount: Int { routes.reduce(0) { $0 + $1.stops.count } }

    var body: some View {
        List {
            Section {
                LabeledContent("Touren", value: "\(routes.count)")
                LabeledContent("Stopps", value: "\(stopCount)")
                LabeledContent("Stockwerke", value: "\(stockwerkNotes.count)")
            } header: {
                Text("Auf diesem Gerät")
            }

            Section {
                Button {
                    Task { await createBackup() }
                } label: {
                    HStack {
                        Label("Sicherung erstellen", systemImage: "square.and.arrow.up")
                        if busy {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(busy)
            } footer: {
                Text(
                    "Schreibt alles in eine JSON-Datei — Touren, Stopps, Lieferstatus und "
                        + "Stockwerke — und öffnet das Teilen-Menü: AirDrop, an sich selbst "
                        + "schicken, oder in „Dateien“ sichern. Am besten irgendwohin, wo sie "
                        + "nicht auf demselben Gerät liegt wie das Original.")
            }

            Section {
                Button("Sicherung laden", systemImage: "square.and.arrow.down") {
                    importing = true
                }
            } footer: {
                Text(
                    "Beim Laden wird gefragt, ob die Sicherung zu den vorhandenen Daten "
                        + "dazukommt oder alles ersetzt.")
            }

            Section {
                // Not part of the file, and worth saying so before somebody
                // restores a backup and wonders where the lines went.
                Label(
                    "Die gefahrene Strecke wird nicht mitgesichert — "
                        + "wiederhergestellte Touren werden einmal neu optimiert.",
                    systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sicherung")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { file in
            ShareSheet(items: [file.url])
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { outcome in
            switch outcome {
            case .success(let urls):
                if let url = urls.first { load(url) }
            case .failure(let failure):
                error = AppError.message(
                    "Die Datei konnte nicht geöffnet werden. \(failure.localizedDescription)")
            }
        }
        .confirmationDialog(
            "Sicherung laden", isPresented: pendingDialog, titleVisibility: .visible,
            presenting: pending
        ) { archive in
            Button("Dazu laden") { apply(archive, mode: .merge) }
            // The ellipsis is doing real work here: it is the only thing on
            // screen saying that one of the two buttons stops to ask again.
            Button("Alles ersetzen …", role: .destructive) { confirmingReplace = true }
            Button("Abbrechen", role: .cancel) { pending = nil }
        } message: { archive in
            Text(describe(archive))
        }
        // A second, separate confirmation for the one button here that destroys
        // data. "Alles ersetzen" sitting in the same list as the harmless
        // option is one slip away from a year of tours, and a destructive
        // button in a dialog is not the same thing as being asked.
        .confirmationDialog(
            "Wirklich alles ersetzen?", isPresented: $confirmingReplace,
            titleVisibility: .visible
        ) {
            Button("Alles ersetzen", role: .destructive) {
                if let pending { apply(pending, mode: .replace) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(
                "\(routes.count == 1 ? "1 Tour" : "\(routes.count) Touren") und "
                    + "\(stockwerkNotes.count == 1 ? "1 Stockwerk" : "\(stockwerkNotes.count) Stockwerke") "
                    + "auf diesem Gerät werden gelöscht und durch die Sicherung ersetzt. "
                    + "Das lässt sich nicht rückgängig machen.")
        }
        .alert("Sicherung geladen", isPresented: resultAlert) {
            Button("OK") { result = nil }
        } message: {
            Text(result ?? "")
        }
        .errorAlert($error)
    }

    private var pendingDialog: Binding<Bool> {
        Binding(
            get: { pending != nil && !confirmingReplace },
            // Only a dismissal of the dialog itself clears the pending
            // archive — not the moment it steps aside for the replace
            // confirmation, which still needs it.
            set: { if !$0 && !confirmingReplace { pending = nil } })
    }

    private var resultAlert: Binding<Bool> {
        Binding(get: { result != nil }, set: { if !$0 { result = nil } })
    }

    private func describe(_ archive: BackupArchive) -> String {
        let stops = archive.stopCount
        return """
            Vom \(Format.date(archive.createdAt)) · \
            \(archive.routeCount == 1 ? "1 Tour" : "\(archive.routeCount) Touren") · \
            \(stops == 1 ? "1 Stopp" : "\(stops) Stopps") · \
            \(archive.stockwerkCount == 1 ? "1 Stockwerk" : "\(archive.stockwerkCount) Stockwerke")
            """
    }

    // MARK: - Actions

    /// Reading the store has to happen here, on the main actor — that is where
    /// the context lives. Encoding it and writing the file does not, and for a
    /// year of tours that is megabytes of JSON: done inline it freezes the tap
    /// for a beat with nothing on screen saying why. The archive is a plain
    /// `Sendable` value once it is built, so the expensive half goes off the
    /// main actor and the button says it is working.
    private func createBackup() async {
        busy = true
        defer { busy = false }
        do {
            let archive = try BackupArchive.make(from: context, settings: Settings.capture())
            let url = try await Task.detached { try archive.writeForSharing() }.value
            sharing = SharedFile(url: url)
        } catch {
            self.error = AppError.message(
                "Die Sicherung konnte nicht erstellt werden. \(error.localizedDescription)")
        }
    }

    private func load(_ url: URL) {
        // A file handed over by the document picker lives outside this app's
        // sandbox, and the permission to read it has to be taken and given
        // back explicitly. Without this the read fails on a file in iCloud
        // Drive — which is exactly where a sensible backup is kept.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            pending = try BackupArchive.decode(data)
        } catch let failure as AppError {
            error = failure
        } catch {
            self.error = AppError.message(
                "Die Datei konnte nicht gelesen werden. \(error.localizedDescription)")
        }
    }

    private func apply(_ archive: BackupArchive, mode: BackupRestore.Mode) {
        do {
            // Anything pushed on top of a route is standing on an object this
            // is about to delete. Wound back first, so the restore never
            // happens underneath a screen showing what it removed.
            if mode == .replace {
                focus.toursPath = NavigationPath()
                focus.forget()
            }
            let outcome = try BackupRestore.apply(archive, mode: mode, in: context)

            // Only a replace takes the file's settings. A merge is "add this to
            // what I have" — the driver reaching for it wants the tours or the
            // Stockwerke out of an old backup, and silently winding their
            // odometer reading back a month along with them is a number they
            // would then write into the vehicle log.
            if mode == .replace { Settings.restore(archive.settings) }

            pending = nil
            result = outcome.summary
        } catch {
            // The restore deletes and inserts before it saves, so a failure
            // partway through leaves all of that sitting in the context as
            // unsaved changes. Left there, the next ordinary write anywhere in
            // the app — one tick of a delivery — would flush a whole store's
            // worth of deletions that were never meant to happen. Rolled back,
            // the failure costs nothing but the message.
            context.rollback()
            pending = nil
            self.error = AppError.message(
                "Die Sicherung konnte nicht geladen werden. \(error.localizedDescription)")
        }
    }
}

/// The handful of settings that are worth carrying to a new phone.
///
/// Kept to the ones a driver actually set: which maps app to hand over to,
/// whether the car starts the navigation by itself, a self-hosted routing
/// server, and the odometer reading the Kilometerstand tool remembers.
/// Everything else the app stores in `UserDefaults` is either a cache or a
/// window's idea of where it was.
///
/// The CarPlay switch travels even though the Kurzbefehle automation it arms
/// cannot: restored onto a phone with no automation it simply does nothing,
/// which is a great deal better than a driver who restored their backup and
/// then spent a morning wondering why the car stopped navigating.
enum Settings {
    private static let keys = [
        Upstreams.Keys.osrmURL,
        NavigationHandoff.providerKey,
        CarPlayNavigation.enabledKey,
        Kilometerstand.lastKey,
        Kilometerstand.hasLastKey,
        Kilometerstand.savedAtKey,
    ]

    /// Values as strings, so the archive stays one flat, readable dictionary
    /// rather than a typed blob nobody can inspect in a text editor.
    ///
    /// Switched on the key, exactly as `restore` below is. It used to switch on
    /// the *dynamic type* of what came back out of `UserDefaults` — which meant
    /// asking whether an `NSNumber` is a `Bool`, a question Foundation answers
    /// by inspecting the value rather than the type, so a stored `1.0` and a
    /// stored `true` are the same object to it. It happened not to matter,
    /// because both branches wrote the same digit. Keying both directions off
    /// the same list is what makes that a fact rather than a coincidence, and it
    /// is the only way the two halves cannot drift: a key added to `keys` and
    /// handled in one switch is now conspicuously missing from the other.
    static func capture() -> [String: String] {
        var out: [String: String] = [:]
        let defaults = UserDefaults.standard
        for key in keys where defaults.object(forKey: key) != nil {
            switch key {
            case Kilometerstand.lastKey, Kilometerstand.savedAtKey:
                out[key] = String(defaults.double(forKey: key))
            case Kilometerstand.hasLastKey, CarPlayNavigation.enabledKey:
                out[key] = defaults.bool(forKey: key) ? "1" : "0"
            default:
                if let s = defaults.string(forKey: key) { out[key] = s }
            }
        }
        return out
    }

    static func restore(_ settings: [String: String]) {
        let defaults = UserDefaults.standard
        for (key, value) in settings where keys.contains(key) {
            switch key {
            case Kilometerstand.lastKey, Kilometerstand.savedAtKey:
                if let d = Double(value) { defaults.set(d, forKey: key) }
            case Kilometerstand.hasLastKey, CarPlayNavigation.enabledKey:
                defaults.set(value == "1" || value.lowercased() == "true", forKey: key)
            default:
                defaults.set(value, forKey: key)
            }
        }
    }
}

