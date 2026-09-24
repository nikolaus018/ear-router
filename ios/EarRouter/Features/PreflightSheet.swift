import SwiftUI
import SwiftData

/// Tour vorbereiten — the checklist that runs while the van is still in the
/// yard, in signal, with time.
///
/// Every problem this app can have is cheap here and expensive in a
/// Gemeindebau courtyard: an address the geocoder never placed, a route never
/// optimised, yesterday's ticks still on today's list. All of it was already
/// visible somewhere — on four screens, to a driver who would have to think to
/// go looking. This is the one place that asks unprompted, and each line that
/// can be fixed carries the button that fixes it.
///
/// Green rows are on it deliberately. A checklist that only ever shows bad news
/// teaches a driver that opening it means work, and then it stops being opened.
struct PreflightSheet: View {
    let route: Route
    let onOptimize: () -> Void
    let onRecheck: () -> Void
    let onResetDelivered: () -> Void
    let onLadeliste: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var stockwerkNotes: [StockwerkNote]
    /// "Lieferstatus zurücksetzen", waiting to be confirmed — the same question
    /// the tour's own menu asks before it clears every tick of the day.
    @State private var confirmingReset = false

    var body: some View {
        let snapshot = RouteSnapshot(route)
        let known = stockwerkNotes.floorQuestionClosed(for: snapshot.ordered)
        let preflight = Preflight(route: route, snapshot: snapshot, floorsKnown: known)

        return NavigationStack {
            List {
                Section {
                    ForEach(preflight.findings) { finding in
                        row(finding)
                    }
                } footer: {
                    Text(
                        preflight.isReady
                            ? "Alles bereit. Gute Fahrt."
                            : "Was oben orange ist, lässt sich hier noch erledigen — "
                                + "unterwegs meistens nicht mehr.")
                }

                if let finish = snapshot.etaFinish() {
                    Section {
                        LabeledContent("Voraussichtlich fertig") {
                            Text(Format.time(finish)).monospacedDigit()
                        }
                    } footer: {
                        Text(
                            snapshot.pace.measured
                                ? "Gerechnet mit deinem heutigen Tempo an der Tür."
                                : "Grobe Schätzung — wird genauer, sobald die ersten "
                                    + "Stopps abgehakt sind.")
                    }
                }
            }
            .navigationTitle("Tour vorbereiten")
            .navigationSubtitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .confirmationDialog(
                "Lieferstatus zurücksetzen?", isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("Zurücksetzen", role: .destructive) {
                    onResetDelivered()
                    dismiss()
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(RouteStore.resetDeliveredMessage(for: route))
            }
        }
    }

    private func row(_ finding: Preflight.Finding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title)
                        .fontWeight(finding.severity == .problem ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = finding.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: finding.symbol)
            }
            .labelStyle(TintedIconLabelStyle(tint: tint(finding.severity)))
            .symbolRenderingMode(.monochrome)

            if let action = finding.action {
                Button(actionLabel(action)) {
                    // The one action here that takes something away asks
                    // first. It used to run straight from this button: one
                    // tap, every outcome and every time of the day gone, and
                    // no undo anywhere in the app.
                    guard action != .resetDelivered else {
                        confirmingReset = true
                        return
                    }
                    perform(action)
                    // The two long jobs put their own banner on the screen
                    // behind this one, where the driver can watch them and stop
                    // them. Staying open would hide both.
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func tint(_ severity: Preflight.Severity) -> Color {
        switch severity {
        case .problem: .attention
        case .note: .secondary
        case .ok: .delivered
        }
    }

    private func actionLabel(_ action: Preflight.Finding.Action) -> String {
        switch action {
        case .optimize: "Jetzt optimieren"
        case .recheckAddresses: "Adressen prüfen"
        case .resetDelivered: "Lieferstatus zurücksetzen"
        case .openLadeliste: "Ladeliste öffnen"
        }
    }

    private func perform(_ action: Preflight.Finding.Action) {
        switch action {
        case .optimize: onOptimize()
        case .recheckAddresses: onRecheck()
        case .resetDelivered: onResetDelivered()
        case .openLadeliste: onLadeliste()
        }
    }
}
