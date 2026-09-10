import SwiftUI

/// Pulls a day's tour straight from the Zusteller-Portal instead of the
/// office's list being typed or pasted in by hand.
///
/// Three steps, one screen: sign in once (the Keychain remembers it after
/// that), pick the date and the matching tour, then load. What comes back
/// goes to the same `ImportReviewView` a JSON paste or a file does — nothing
/// here writes to the route directly, so a wrong tour picked by mistake is
/// still just a list on screen, not a changed tour.
struct GourmetImportSheet: View {
    let route: Route
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
    @State private var review: JSONEditorSheet.ReviewPayload?

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
        .sheet(item: $review) { payload in
            ImportReviewView(route: route, entries: payload.entries)
        }
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
            if entries.isEmpty {
                error = AppError.message(
                    "Für \"\(tour.name)\" wurden an diesem Tag keine offenen Lieferungen "
                        + "gefunden.")
            } else {
                review = JSONEditorSheet.ReviewPayload(entries: entries)
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
