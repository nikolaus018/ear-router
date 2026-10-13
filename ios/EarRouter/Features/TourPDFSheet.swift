import SwiftUI

/// "Als PDF exportieren": the tour as the printed list, and — when asked — cut
/// into shares for however many people are driving it.
///
/// The split here is a suggestion on paper and nothing else. It changes no
/// stop and makes no tour; "Tour aufteilen" is still where shares are drawn by
/// hand and turned into tours.
struct TourPDFSheet: View {
    let route: Route
    @Environment(\.dismiss) private var dismiss
    @State private var split = false
    @State private var people = 2
    @State private var sharing: SharedFile?
    @State private var error: AppError?

    private var mostPeople: Int {
        min(SplitState.maxPeople, route.stops.count(where: \.isOwedAMeal))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Aufteilung vorschlagen", isOn: $split)
                        .disabled(mostPeople < 2)
                    if split, mostPeople >= 2 {
                        Stepper("Personen: \(people)", value: $people, in: 2...mostPeople)
                    }
                } footer: {
                    Text(
                        split
                            ? "Die Liste bleibt in der Fahrreihenfolge und wird so geteilt, "
                                + "dass jede Person etwa gleich lang unterwegs ist — Fahrzeit "
                                + "und Zeit an der Tür zusammen. Kunden an derselben Tür "
                                + "bleiben beisammen. Die Tour selbst ändert sich nicht."
                            : "Alle Stopps in der Fahrreihenfolge, als Liste zum Ausdrucken.")
                }

                Section {
                    Button {
                        export()
                    } label: {
                        WideButtonLabel("PDF teilen", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Als PDF exportieren")
            .navigationSubtitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
            .errorAlert($error)
        }
        .presentationDetents([.medium, .large])
    }

    private func export() {
        do {
            let pdf = TourPDF(route, people: split ? min(people, mostPeople) : nil)
            sharing = SharedFile(url: try pdf.writeForSharing())
        } catch {
            self.error = AppError.message(
                "Das PDF konnte nicht erstellt werden. \(error.localizedDescription)")
        }
    }
}
