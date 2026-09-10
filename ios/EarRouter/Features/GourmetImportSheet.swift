import SwiftUI
import SwiftData

/// Pulls a day's tour straight from the Zusteller-Portal instead of the
/// office's list being typed or pasted in by hand.
///
/// Three steps, one screen: sign in once (the Keychain remembers it after
/// that), pick the date and the matching tour, then load. What comes back
/// goes to the same `ImportReviewView` a JSON paste or a file does — reviewed,
/// corrected and only then saved, exactly like every other bulk import this
/// app has. Nothing here writes to a route directly.
///
/// Two ways in, one screen for both. From an existing tour's own menu this
/// adds to it — the same route the driver was already looking at. From
/// Touren's "+" there is no route yet: `.newRoute` creates one only once
/// there is something real to put on it, names it after the tour, and hands
/// it back through `onRouteCreated` so the caller can jump straight to it. A
/// route created that way and then abandoned mid-review — the driver picked
/// the wrong tour, or just backed out — is deleted again on the way out
/// rather than left behind as an empty tour nobody asked for.
struct GourmetImportSheet: View {
    enum Mode {
        case existing(Route)
        case newRoute
    }

    let mode: Mode
    var onRouteCreated: ((Route) -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var hasCredentials = false
    @State private var editingCredentials = false

    @State private var date = Date()
    @State private var tours: [GourmetPortal.Tour] = []
    @State private var selectedTourID: Int?
    @State private var loadingTours = false

    @State private var busy: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var error: AppError?
    @State private var review: ReviewContext?
    /// Only ever set in `.newRoute` mode — the empty shell `load()` created to
    /// have something to hand `ImportReviewView`. Cleared, and the route with
    /// it, unless the review actually saves.
    @State private var createdRoute: Route?
    @State private var imported = false

    /// What `ImportReviewView` needs, bundled so the sheet always presents
    /// the route the entries were actually fetched for — `.newRoute` creates
    /// that route only at `load()` time, so it cannot be fixed ahead of time
    /// the way `.existing` already has it.
    struct ReviewContext: Identifiable {
        let id = UUID()
        let route: Route
        let entries: [CustomerJSON]
    }

    init(mode: Mode, onRouteCreated: ((Route) -> Void)? = nil) {
        self.mode = mode
        self.onRouteCreated = onRouteCreated
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasCredentials && !editingCredentials {
                    form
                } else {
                    loginForm
                }
            }
            .navigationTitle("Zusteller-Portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if busy != nil {
                        Button("Stoppen") { loadTask?.cancel() }
                    } else if editingCredentials && hasCredentials {
                        // Not "Schließen" here: there is already a working
                        // login one tap back, and closing the whole sheet
                        // over a driver who just wanted out of this form
                        // would send them digging through the menu again.
                        Button("Abbrechen") { editingCredentials = false }
                    } else {
                        Button("Schließen") { dismiss() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let busy {
                    BusyBanner(text: busy)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: busy)
            .errorAlert($error)
            .interactiveDismissDisabled(busy != nil)
            .task {
                hasCredentials = GourmetCredentialsStore.load() != nil
                if hasCredentials { await loadTours() }
            }
            .onChange(of: date) { _, _ in selectedTourID = nil }
        }
        .sheet(item: $review, onDismiss: reviewDismissed) { ctx in
            ImportReviewView(route: ctx.route, entries: ctx.entries) { imported = true }
        }
    }

    /// Runs once the review sheet is gone, whichever way it went. Both
    /// branches only matter in `.newRoute` mode — `.existing` never sets
    /// `createdRoute`, so this is a no-op there beyond closing the sheet.
    private func reviewDismissed() {
        defer { imported = false }
        if let createdRoute {
            if imported {
                onRouteCreated?(createdRoute)
            } else {
                // Nothing was saved — a route the driver never asked to
                // create should not be the one thing this screen leaves
                // behind.
                try? RouteStore.delete(createdRoute, in: context)
            }
            self.createdRoute = nil
        }
        if imported { dismiss() }
    }

    // MARK: - Login

    private var loginForm: some View {
        Form {
            Section {
                TextField("Benutzername", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
            } footer: {
                Text(
                    "Dieselben Zugangsdaten wie im Zusteller-Portal im Browser. Sie werden "
                        + "verschlüsselt auf diesem Gerät gespeichert.")
            }
            Section {
                Button("Anmelden") { Task { await signIn() } }
                    .disabled(username.trimmed.isEmpty || password.isEmpty || busy != nil)
            }
        }
    }

    private func signIn() async {
        busy = "Anmelden …"
        defer { busy = nil }
        let credentials = GourmetPortal.Credentials(
            username: username.trimmed, password: password)
        do {
            // A login round trip up front, purely to check the password —
            // saving first and finding out only on the actual fetch would
            // leave a driver staring at "Zusteller-Portal" with no idea
            // which of the two fields was wrong.
            _ = try await GourmetPortal.login(credentials)
            GourmetCredentialsStore.save(credentials)
            password = ""
            hasCredentials = true
            editingCredentials = false
            await loadTours()
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Anmeldung fehlgeschlagen.")
        }
    }

    // MARK: - Date and tour

    private var form: some View {
        Form {
            Section {
                DatePicker("Datum", selection: $date, displayedComponents: .date)
            }

            Section {
                if loadingTours {
                    HStack {
                        ProgressView()
                        Text("Touren werden geladen …")
                            .foregroundStyle(.secondary)
                    }
                } else if candidateTours.isEmpty {
                    Text("Keine Tour für diesen Tag gefunden.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Tour", selection: $selectedTourID) {
                        Text("Bitte wählen").tag(Int?.none)
                        ForEach(candidateTours) { tour in
                            Text(tour.name).tag(Int?.some(tour.id))
                        }
                    }
                }
            } footer: {
                if !tours.isEmpty {
                    Text(
                        "\(GourmetPortal.germanWeekday(for: date).capitalized) — "
                            + "\(candidateTours.count) von \(tours.count) Touren passen.")
                }
            }

            Section {
                Button("Laden") { loadTask = Task { await load() } }
                    .disabled(selectedTourID == nil || busy != nil)
            }

            Section {
                Button("Andere Zugangsdaten verwenden") {
                    username = ""
                    password = ""
                    editingCredentials = true
                }
                Button("Abmelden", role: .destructive) {
                    GourmetCredentialsStore.clear()
                    hasCredentials = false
                    tours = []
                    selectedTourID = nil
                }
            }
        }
    }

    private var candidateTours: [GourmetPortal.Tour] {
        tours.filter { GourmetPortal.runs($0, on: date) }
    }

    private func loadTours() async {
        guard let credentials = GourmetCredentialsStore.load() else { return }
        loadingTours = true
        defer { loadingTours = false }
        do {
            let token = try await GourmetPortal.login(credentials)
            tours = try await GourmetPortal.tours(token: token)
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Tourenliste konnte nicht geladen werden.")
        }
    }

    private func load() async {
        guard let selectedTourID, let tour = tours.first(where: { $0.id == selectedTourID }),
            let credentials = GourmetCredentialsStore.load()
        else { return }
        busy = "Anmelden …"
        defer { busy = nil }
        do {
            let entries = try await GourmetPortal.fetchTourEntries(
                tour: tour, date: date, credentials: credentials
            ) { progress in
                Task { @MainActor in busy = progress }
            }
            guard !entries.isEmpty else {
                error = AppError.message(
                    "Für \"\(tour.name)\" wurden an diesem Tag keine offenen Lieferungen "
                        + "gefunden.")
                return
            }

            switch mode {
            case .existing(let route):
                review = ReviewContext(route: route, entries: entries)
            case .newRoute:
                // Created only now that there is something real to put on
                // it — a failed or empty fetch above never leaves a stray
                // route behind.
                let name = GourmetPortal.suggestedRouteName(tour: tour, date: date)
                let route = try RouteStore.createRoute(name: name, in: context)
                createdRoute = route
                review = ReviewContext(route: route, entries: entries)
            }
        } catch is CancellationError {
            // The driver stopped it on purpose — nothing to report.
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Lieferungen konnten nicht geladen werden.")
        }
    }
}
