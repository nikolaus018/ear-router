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
    /// A departure to try the estimate with. Lives exactly as long as this
    /// sheet is open: it is a question — "and if I leave at seven?" — not a
    /// setting, and no other screen's times move with it.
    @State private var plannedStart: Date?

    var body: some View {
        let snapshot = RouteSnapshot(route, plannedStart: plannedStart)
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
                        departure(snapshot)
                        LabeledContent("Voraussichtlich fertig") {
                            Text(Format.time(finish)).monospacedDigit()
                        }
                        // Only beside a departure that is still ahead. Counted
                        // from now it is "fertig" again in other words.
                        if snapshot.pendingStart() != nil,
                           let duration = Format.minutes(snapshot.plannedDuration()) {
                            LabeledContent("Dauer") {
                                Text("ca. \(duration)").monospacedDigit()
                            }
                        }
                    } footer: {
                        Text(
                            (snapshot.pace.measured
                                ? "Gerechnet mit deinem heutigen Tempo an der Tür."
                                : snapshot.pace.learned
                                ? "Gerechnet mit deinem Tempo der letzten Touren — wird "
                                    + "genauer, sobald die ersten Stopps abgehakt sind."
                                : "Grobe Schätzung — wird genauer, sobald die ersten "
                                    + "Stopps abgehakt sind.")
                                + (snapshot.pendingStart() != nil
                                    ? " Die Abfahrt gilt nur hier zum Nachrechnen und wird "
                                        + "nicht gespeichert."
                                    : ""))
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

    /// A departure to work the estimate out for. Without it the estimate below
    /// starts now — right on the day, and no use the evening before.
    ///
    /// Not offered once the tour is under way: the ticks say where the van
    /// is by then.
    @ViewBuilder
    private func departure(_ snapshot: RouteSnapshot) -> some View {
        if snapshot.pendingStart() != nil {
            DatePicker(
                "Abfahrt",
                selection: Binding(
                    get: { plannedStart ?? Date() },
                    set: { setPlannedStart($0) }),
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute])
            Button("Ab jetzt rechnen") { setPlannedStart(nil) }
        } else if !snapshot.underWay {
            Button("Mit Abfahrtszeit rechnen", systemImage: "clock") {
                setPlannedStart(PlannedStart.suggestion())
            }
        }
    }

    private func setPlannedStart(_ date: Date?) {
        plannedStart = date
        if let date { PlannedStart.remember(date) }
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
