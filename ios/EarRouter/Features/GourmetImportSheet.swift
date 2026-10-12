import SwiftUI
import SwiftData

/// Pulls a day's tour straight from the Zusteller-Portal instead of the
/// office's list being typed or pasted in by hand.
///
/// Three steps, one screen: sign in once (the Keychain remembers it after
/// that), pick the date and the matching tour, then load. What comes back
/// goes to the same `ImportReviewView` a JSON paste does — reviewed,
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
    /// Return in the username field moves to the password, and Return there
    /// signs in — the way every login form on this phone behaves. Without it
    /// the keyboard's own key did nothing, and the driver had to dismiss the
    /// keyboard to find a button it was covering.
    @FocusState private var loginField: LoginField?
    private enum LoginField: Hashable { case username, password }

    @State private var date = Date()
    @State private var tours: [GourmetPortal.Tour] = []
    @State private var selectedTourID: Int?
    @State private var loadingTours = false

    @State private var busy: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var error: AppError?
    @State private var pendingSelection: PendingSelection?
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

    /// The tour's deliveries, list data only — handed to
    /// `GourmetStopSelectionView` so the driver can say which of them to
    /// actually keep before any of them pay for a detail fetch. Carries the
    /// login token along so picking stops doesn't cost a second login.
    struct PendingSelection: Identifiable {
        let id = UUID()
        let tour: GourmetPortal.Tour
        let token: String
        let deliveries: [GourmetPortal.Delivery]
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
            .floatingBanner {
                if let busy {
                    BusyBanner(text: busy)
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
            .onChange(of: date) { _, _ in reconcileSelection() }
        }
        .sheet(item: $pendingSelection) { pending in
            GourmetStopSelectionView(deliveries: pending.deliveries) { chosen in
                pendingSelection = nil
                loadTask = Task { await loadDetails(tour: pending.tour, token: pending.token, deliveries: chosen) }
            }
        }
        .sheet(item: $review, onDismiss: reviewDismissed) { ctx in
            // Always an addition: what is already on the tour stays, whatever
            // the portal's list says. A new tour has nothing to keep, so there
            // it comes to the same thing.
            ImportReviewView(route: ctx.route, entries: ctx.entries, replacing: false) {
                imported = true
            }
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
                    .submitLabel(.next)
                    .focused($loginField, equals: .username)
                    .onSubmit { loginField = .password }
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($loginField, equals: .password)
                    .onSubmit(startSignIn)
            } footer: {
                Text(
                    "Dieselben Zugangsdaten wie im Zusteller-Portal im Browser. Sie werden "
                        + "verschlüsselt auf diesem Gerät gespeichert.")
            }
            Section {
                // Held in `loadTask` like every other job on this screen, so
                // the "Stoppen" button the banner puts in the toolbar has
                // something to cancel. Started as a loose task — which is what
                // this did — the sheet spent a slow login showing a stop button
                // that cancelled nothing, over a swipe-down that `busy` had
                // already disabled: no way out at all until the request timed
                // out.
                Button("Anmelden", action: startSignIn)
                    .disabled(!canSignIn)
            }
        }
    }

    private var canSignIn: Bool {
        !username.trimmed.isEmpty && !password.isEmpty && busy == nil
    }

    private func startSignIn() {
        guard canSignIn else { return }
        loginField = nil
        loadTask = Task { await signIn() }
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
        } catch is CancellationError {
            // Stopped from the banner. The form is still standing with both
            // fields filled in, which says it better than an alert would.
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

    /// Keeps the chosen tour while it still runs on the chosen day, and picks
    /// it for the driver when there is only one it could be — which, for a
    /// driver on the same round every weekday, is most days. Changing the date
    /// used to clear the choice outright, so stepping a day forward to load
    /// tomorrow's list meant choosing the same tour again from a menu of one.
    private func reconcileSelection() {
        let candidates = candidateTours
        if let id = selectedTourID, candidates.contains(where: { $0.id == id }) { return }
        selectedTourID = candidates.count == 1 ? candidates[0].id : nil
    }

    private func loadTours() async {
        guard let credentials = GourmetCredentialsStore.load() else { return }
        loadingTours = true
        defer { loadingTours = false }
        do {
            let token = try await GourmetPortal.login(credentials)
            tours = try await GourmetPortal.tours(token: token)
            reconcileSelection()
        } catch is CancellationError {
            // Stopped from the banner — the driver already knows.
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Tourenliste konnte nicht geladen werden.")
        }
    }

    /// First half: log in, fetch the tour's deliveries (list data only), and
    /// hand them to `GourmetStopSelectionView` for the driver to narrow down.
    /// Nothing is created yet — `.newRoute`'s empty shell still only appears
    /// once `loadDetails` below has something real to put on it.
    private func load() async {
        guard let selectedTourID, let tour = tours.first(where: { $0.id == selectedTourID }),
            let credentials = GourmetCredentialsStore.load()
        else { return }
        busy = "Anmelden …"
        defer { busy = nil }
        do {
            let (token, deliveries) = try await GourmetPortal.matchingDeliveries(
                tour: tour, date: date, credentials: credentials
            ) { progress in
                Task { @MainActor in busy = progress }
            }
            guard !deliveries.isEmpty else {
                error = AppError.message(
                    "Für „\(tour.name)“ wurden an diesem Tag keine offenen Lieferungen "
                        + "gefunden.")
                return
            }
            pendingSelection = PendingSelection(tour: tour, token: token, deliveries: deliveries)
        } catch is CancellationError {
            // The driver stopped it on purpose — nothing to report.
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Lieferungen konnten nicht geladen werden.")
        }
    }

    /// Second half: once the driver has picked which stops to keep, fetch
    /// each one's Paket and go to the same review screen every other import
    /// ends up on.
    private func loadDetails(
        tour: GourmetPortal.Tour, token: String, deliveries: [GourmetPortal.Delivery]
    ) async {
        busy = "Details werden geladen …"
        defer { busy = nil }
        do {
            let entries = try await GourmetPortal.fetchDetails(for: deliveries, token: token) {
                done, total in
                Task { @MainActor in busy = "Paket \(done) von \(total) wird geladen …" }
            }

            switch mode {
            case .existing(let route):
                // A route that already says which tour it came from keeps
                // saying it — but not which day: a tour driven again next
                // week is loaded again for that day, and the map's "Stopps
                // der anderen" asked the portal about last week's.
                let link = PortalTourLink.load(for: route.id)
                if link == nil || link?.tourID == tour.id {
                    PortalTourLink(tourID: tour.id, tourName: tour.name, date: date)
                        .save(for: route.id)
                }
                review = ReviewContext(route: route, entries: entries)
            case .newRoute:
                // Created only now that there is something real to put on
                // it — a cancelled fetch above never leaves a stray route
                // behind.
                let open = FetchDescriptor<Route>(
                    predicate: #Predicate { $0.statusRaw == "active" })
                let taken = Set(((try? context.fetch(open)) ?? []).map(\.name))
                let name = GourmetPortal.suggestedRouteName(tour: tour, date: date, taken: taken)
                let route = try RouteStore.createRoute(name: name, in: context)
                PortalTourLink(tourID: tour.id, tourName: tour.name, date: date)
                    .save(for: route.id)
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

// MARK: - Choosing which stops to keep

/// Between the tour's full delivery list and the review screen: a
/// searchable checklist so the driver can drop stops that are not theirs to
/// drive before any of them pay for a detail fetch — every entry starts
/// unselected: the driver picks the stops they drive, and "Alle auswählen" is one tap.
///
/// The order the stops are picked in is kept and handed on: the Prüfen list
/// arrives in that order rather than in the portal's. Tapping everything off
/// and then back on in the order of the printed list is the cheapest way there
/// is to check the day against it, and it costs nothing to remember.
///
/// It is the checking order and nothing more. The tour itself is sorted by
/// OSRM once it is saved, the same as every other import.
struct GourmetStopSelectionView: View {
    let deliveries: [GourmetPortal.Delivery]
    var onContinue: ([GourmetPortal.Delivery]) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The chosen deliveries in the order they were chosen, not a `Set`:
    /// picking a stop appends it, and that sequence is what „Weiter“ passes
    /// on. Picking a stop off and on again therefore moves it to the back,
    /// which is the whole point — it is how a driver puts the list in the
    /// order of the printed one without leaving this screen.
    @State private var selected: [Int]
    @State private var search = ""

    init(deliveries: [GourmetPortal.Delivery], onContinue: @escaping ([GourmetPortal.Delivery]) -> Void) {
        self.deliveries = deliveries
        self.onContinue = onContinue
        _selected = State(initialValue: [])
    }

    private var allSelected: Bool { selected.count == deliveries.count }

    /// Each picked stop's place in the order, counted from 1 — what the row
    /// badges draw, and what says a row is picked at all.
    private var positions: [Int: Int] {
        Dictionary(
            selected.enumerated().map { ($0.element, $0.offset + 1) },
            uniquingKeysWith: { first, _ in first })
    }

    /// What was picked, as deliveries and in the picked order. Built through a
    /// lookup rather than by filtering `deliveries`, because filtering would
    /// quietly put the portal's order back.
    private var chosen: [GourmetPortal.Delivery] {
        let byID = Dictionary(deliveries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.compactMap { byID[$0] }
    }

    /// Folded and tokenised the way the tour's own search is, so "Doebling"
    /// finds "Döbling" and "gruber gentz" finds Fam. Gruber in the Gentzgasse.
    /// A plain lowercased `contains` was the one search in the app that did
    /// neither — and it is the one used on a list from somebody else's system.
    private var filtered: [GourmetPortal.Delivery] {
        let query = AddressText.Search(search)
        guard !query.isEmpty else { return deliveries }
        return deliveries.filter { delivery in
            let (name, address) = GourmetPortal.summary(delivery)
            return query.matches(AddressText.matchKey("\(name) \(address)"))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Hoisted out of the rows: one pass over the picked list for
                // the whole list, rather than a linear search per row. Doubles
                // as the membership test — a stop with no number is not picked.
                let positions = self.positions
                ForEach(filtered, id: \.id) { delivery in
                    row(delivery, position: positions[delivery.id])
                }
            }
            .listStyle(.insetGrouped)
            // Picking a row while searching must not close the keyboard.
            .scrollDismissesKeyboard(.never)
            // Over the list rather than a footer inside it, the same as every
            // other search in the app: "Keine Treffer." set in footnote grey
            // under an empty inset block read as a list that had failed to
            // load.
            .overlay {
                if filtered.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Name oder Adresse")
            .navigationTitle("Stopps wählen")
            .navigationBarTitleDisplayMode(.inline)
            // The count and the one bulk action beside it, where the thumb
            // already is. "Alle"/"Keine" used to share the top-leading corner
            // with "Abbrechen": two bare words crowding one corner, one of
            // which threw the whole selection away.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Text("\(selected.count) von \(deliveries.count) ausgewählt")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: selected.count)
                    Spacer(minLength: 8)
                    Button(allSelected ? "Keine auswählen" : "Alle auswählen") {
                        if allSelected {
                            selected = []
                        } else {
                            // Behind what is already picked, in the portal's
                            // order. A driver who has put six stops in order
                            // and then wants the rest along keeps those six.
                            let picked = Set(selected)
                            selected += deliveries.map(\.id).filter { !picked.contains($0) }
                        }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Weiter") { onContinue(chosen) }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func row(_ delivery: GourmetPortal.Delivery, position: Int?) -> some View {
        let (name, address) = GourmetPortal.summary(delivery)
        return Button {
            if position != nil {
                selected.removeAll { $0 == delivery.id }
            } else {
                selected.append(delivery.id)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Ohne Namen" : name)
                        .foregroundStyle(.primary)
                    Text(address.isEmpty ? "Keine Adresse" : address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                marker(position)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(position != nil ? .isSelected : [])
        .accessibilityValue(position.map { "Nummer \($0)" } ?? "nicht ausgewählt")
    }

    /// A tick said the stop was coming along; the number says where in the
    /// list it comes — the printed list's order, which Prüfen is read in. The
    /// tour's own order is OSRM's. It is the badge the tour's own rows wear, in
    /// the shade an undelivered stop wears there — because a picked stop is
    /// exactly that, one row before it exists.
    ///
    /// The empty circle is drawn at the badge's own 26pt rather than left as
    /// an SF Symbol at its optical size, so the column does not breathe in and
    /// out as stops are picked and dropped.
    @ViewBuilder
    private func marker(_ position: Int?) -> some View {
        if let position {
            StopNumberBadge(number: position, kind: .open)
        } else {
            Circle()
                .strokeBorder(.tertiary, lineWidth: 1.5)
                .frame(width: 26, height: 26)
        }
    }
}

// MARK: - Signing in on its own

/// The portal login as a screen of its own, for the places that need a login
/// before they can do anything and have no banner of their own to report
/// progress in. Checks the password with one round trip, stores it in the
/// Keychain, and says so through `onSignedIn`.
struct GourmetLoginForm: View {
    var onSignedIn: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var error: AppError?
    @State private var task: Task<Void, Never>?
    @FocusState private var field: Field?
    private enum Field: Hashable { case username, password }

    var body: some View {
        Form {
            Section {
                TextField("Benutzername", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .submitLabel(.next)
                    .focused($field, equals: .username)
                    .onSubmit { field = .password }
                SecureField("Passwort", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($field, equals: .password)
                    .onSubmit(start)
            } header: {
                Text("Zusteller-Portal")
            } footer: {
                Text(
                    "Dieselben Zugangsdaten wie im Zusteller-Portal im Browser. Sie werden "
                        + "verschlüsselt auf diesem Gerät gespeichert.")
            }
            Section {
                Button(action: start) {
                    HStack {
                        Text("Anmelden")
                        Spacer()
                        if signingIn { ProgressView() }
                    }
                }
                .disabled(!canSignIn)
            }
        }
        .errorAlert($error)
        .onDisappear { task?.cancel() }
    }

    private var canSignIn: Bool {
        !username.trimmed.isEmpty && !password.isEmpty && !signingIn
    }

    private func start() {
        guard canSignIn else { return }
        field = nil
        task = Task { await signIn() }
    }

    private func signIn() async {
        signingIn = true
        defer { signingIn = false }
        let credentials = GourmetPortal.Credentials(username: username.trimmed, password: password)
        do {
            _ = try await GourmetPortal.login(credentials)
            GourmetCredentialsStore.save(credentials)
            password = ""
            onSignedIn()
        } catch is CancellationError {
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Anmeldung fehlgeschlagen.")
        }
    }
}
