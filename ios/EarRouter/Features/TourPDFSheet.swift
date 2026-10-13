import SwiftData
import SwiftUI

/// "Tour als PDF": a tour of the Zusteller-Portal as the printed list, handed
/// to the share sheet — to print, or to send to whoever is driving it.
///
/// Picked the way "Tour aufteilen" picks one — a day, then that day's tours
/// from the portal — and like it, nothing here becomes a tour on the phone.
struct TourPDFSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var date = Date()
    @State private var tours: [GourmetPortal.Tour] = []
    @State private var selectedTourID: Int?
    @State private var loadingTours = false

    @State private var busy: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var sharing: SharedFile?
    @State private var error: AppError?
    /// Read once, not in `body` — see `TourSplitSheet`.
    @State private var signedIn = GourmetCredentialsStore.load() != nil

    var body: some View {
        NavigationStack {
            Group {
                if signedIn {
                    form
                } else {
                    GourmetLoginForm {
                        signedIn = true
                        Task { await loadTours() }
                    }
                }
            }
            .navigationTitle("Tour als PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if busy != nil {
                        Button("Stoppen") { loadTask?.cancel() }
                    } else {
                        Button("Schließen") { dismiss() }
                    }
                }
            }
            .floatingBanner {
                if let busy {
                    BusyBanner(text: busy)
                }
            }
            .animation(.snappy, value: busy)
            .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
            .errorAlert($error)
            .interactiveDismissDisabled(busy != nil)
            .task {
                if signedIn { await loadTours() }
            }
            .onChange(of: date) { _, _ in reconcileSelection() }
        }
    }

    private var form: some View {
        Form {
            Section {
                DatePicker("Datum", selection: $date, displayedComponents: .date)
                if loadingTours {
                    HStack {
                        ProgressView()
                        Text("Touren werden geladen …").foregroundStyle(.secondary)
                    }
                } else if candidateTours.isEmpty {
                    Text("Keine Tour für diesen Tag gefunden.").foregroundStyle(.secondary)
                } else {
                    Picker("Tour", selection: $selectedTourID) {
                        Text("Bitte wählen").tag(Int?.none)
                        ForEach(candidateTours) { tour in
                            Text(tour.name).tag(Int?.some(tour.id))
                        }
                    }
                }
            } footer: {
                Text(
                    "Die offenen Lieferungen der Tour laut Zusteller-Portal, in "
                        + "Fahrreihenfolge, als Liste zum Ausdrucken — mit dem Stockwerk aus "
                        + "den Globalen Infos.")
            }

            Section {
                Button {
                    loadTask = Task { await export() }
                } label: {
                    WideButtonLabel("PDF teilen", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedTourID == nil || busy != nil)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            }
        }
    }

    private var candidateTours: [GourmetPortal.Tour] {
        tours.filter { GourmetPortal.runs($0, on: date) }
    }

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
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Tourenliste konnte nicht geladen werden.")
        }
    }

    /// With the detail call per stop — the Paket and the note are most of what
    /// the list is printed for — and then put in driving order, the way a
    /// tour of these stops would be.
    private func export() async {
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
                    "Für „\(tour.name)“ wurden an diesem Tag keine offenen Lieferungen gefunden.")
                return
            }
            let entries = try await GourmetPortal.fetchDetails(for: deliveries, token: token) {
                done, total in
                Task { @MainActor in busy = "Paket \(done) von \(total) wird geladen …" }
            }
            let placed = try await PortalPlacement.place(deliveries) { done, total in
                Task { @MainActor in busy = "Adresse \(done) von \(total) wird gesucht …" }
            }
            busy = "Fahrreihenfolge wird berechnet …"
            let order = try await PortalDrivingOrder.order(
                placed.map { stop in stop.coordinate.map { (lat: $0.latitude, lon: $0.longitude) } })
            let notes = (try? StockwerkStore.all(in: context)) ?? []
            let pdf = TourPDF(
                tourName: tour.name, day: date,
                entries: order.compactMap { entries.indices.contains($0) ? entries[$0] : nil },
                notes: notes)
            sharing = SharedFile(url: try pdf.writeForSharing())
        } catch is CancellationError {
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message(
                "Das PDF konnte nicht erstellt werden. \(error.localizedDescription)")
        }
    }
}
