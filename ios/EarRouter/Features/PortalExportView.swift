import SwiftUI

/// Hands over the last weeks of the TK tours, whole, as one file — for looking
/// back at how a shared tour was divided. Deep in Erweitert on purpose: it is
/// something to need once, not a tool.
struct PortalExportView: View {
    @State private var days = 30
    @State private var busy: String?
    @State private var task: Task<Void, Never>?
    @State private var result: (url: URL, days: Int, stops: Int)?
    @State private var error: AppError?

    var body: some View {
        List {
            Section {
                Stepper("Letzte \(days) Tage", value: $days, in: 7...90, step: 7)
                Button {
                    task = Task { await export() }
                } label: {
                    HStack(spacing: 8) {
                        Text("TK-Touren holen")
                        if busy != nil { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(busy != nil)
                if let busy {
                    Text(busy).foregroundStyle(.secondary)
                    Button("Stoppen", role: .cancel) { task?.cancel() }
                }
            } footer: {
                Text(
                    "Holt jede TK-Tour der letzten Tage vollständig aus dem Zusteller-Portal, "
                        + "auch die schon gelieferten Stopps und die Hälfte der anderen Fahrer. "
                        + "Mit der Anmeldung, die die App schon hat. Es wird nichts gesendet, "
                        + "bevor du die Datei teilst.")
            }
            if let result {
                Section("Fertig") {
                    LabeledContent("Touren-Tage", value: "\(result.days)")
                    LabeledContent("Stopps", value: "\(result.stops)")
                    ShareLink(item: result.url) {
                        Label("Datei teilen", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("TK-Touren holen")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($error)
        .onDisappear { task?.cancel() }
    }

    private func export() async {
        guard let credentials = GourmetCredentialsStore.load() else {
            error = AppError.message(
                "Erst im Zusteller-Portal anmelden, zum Beispiel unter „Tour aufteilen“.")
            return
        }
        busy = "Anmelden …"
        result = nil
        defer { busy = nil }
        do {
            let document = try await PortalDayExport.run(
                daysBack: days, credentials: credentials
            ) { progress in
                Task { @MainActor in busy = progress }
            }
            guard !document.days.isEmpty else {
                error = AppError.message(
                    "Das Portal liefert für diese Tage keine TK-Touren mehr.")
                return
            }
            let url = try PortalDayExport.write(document)
            result = (url, document.days.count, document.days.reduce(0) { $0 + $1.deliveries.count })
        } catch is CancellationError {
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError.message("Die TK-Touren konnten nicht geholt werden.")
        }
    }
}
