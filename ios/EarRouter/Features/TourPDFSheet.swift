import SwiftData
import SwiftUI

/// "Tour als PDF": one of the phone's tours as the printed list, handed to the
/// share sheet — to print, or to send to whoever is driving it instead.
struct TourPDFSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Route.createdAt, order: .reverse) private var routes: [Route]

    @State private var selected: UUID?
    @State private var sharing: SharedFile?
    @State private var error: AppError?

    /// The tour being worked until another is picked — see `Route.current`.
    private var route: Route? {
        routes.first { $0.id == selected }
            ?? Route.current(
                among: routes.filter { $0.status == .active },
                working: RouteFocus.lastOpenedRouteID)
            ?? routes.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let route {
                    form(route)
                } else {
                    ContentUnavailableView(
                        "Keine Tour", systemImage: "doc.text",
                        description: Text("Leg zuerst eine Tour an."))
                }
            }
            .navigationTitle("Tour als PDF")
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

    private func form(_ route: Route) -> some View {
        Form {
            Section {
                Picker("Tour", selection: Binding(get: { route.id }, set: { selected = $0 })) {
                    ForEach(routes) { route in
                        Text(label(route)).tag(route.id)
                    }
                }
            } footer: {
                Text(
                    "Alle Stopps in der Fahrreihenfolge, als Liste zum Ausdrucken — "
                        + "mit dem Stockwerk aus den Globalen Infos.")
            }

            Section {
                Button {
                    export(route)
                } label: {
                    WideButtonLabel("PDF teilen", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(route.customerCount == 0)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
            }
        }
    }

    /// A finished tour says which day it was: by then there are several of
    /// one name.
    private func label(_ route: Route) -> String {
        guard route.status == .completed, let day = route.completedAt else { return route.name }
        return "\(route.name) · \(Format.numericDate(day))"
    }

    private func export(_ route: Route) {
        do {
            sharing = SharedFile(url: try TourPDF(route).writeForSharing())
        } catch {
            self.error = AppError.message(
                "Das PDF konnte nicht erstellt werden. \(error.localizedDescription)")
        }
    }
}
