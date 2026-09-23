import SwiftUI
import SwiftData

/// "Reihenfolge ändern": the tour's customers, one line each, to drag into
/// the driver's own order.
///
/// A sheet of its own rather than drag handles on the tour's list. Those rows
/// are several lines tall, so a tour of thirty was many screens long and a
/// drag had to be carried past the edge and scrolled along; and every drop
/// saved and re-routed while the next drag was already starting. Here a row
/// is one line, so most of a tour fits on the screen at once, and nothing is
/// written until Fertig.
struct ReorderSheet: View {
    let route: Route
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var customers: [Stop]
    @State private var error: AppError?

    init(route: Route) {
        self.route = route
        _customers = State(initialValue: route.customerStops)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(customers.enumerated()), id: \.element.id) { index, stop in
                    row(stop, number: index + 1)
                }
                .onMove { customers.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reihenfolge ändern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { save() }
                }
            }
            .errorAlert($error)
        }
    }

    private func row(_ stop: Stop, number: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 0) {
                Text(stop.kunde ?? "")
                    .lineLimit(1)
                Text(stop.listAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func save() {
        let changed: Bool
        do {
            changed = try RouteStore.reorder(route, customerIDs: customers.map(\.id), in: context)
        } catch {
            self.error = AppError.message("Die neue Reihenfolge konnte nicht gespeichert werden.")
            return
        }
        dismiss()
        guard changed else { return }
        let route = route, context = context
        Task { await RouteOptimizer.optimizeBestEffort(route, in: context, keepOrder: true) }
    }
}
