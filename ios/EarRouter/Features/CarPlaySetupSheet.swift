import SwiftUI

/// The six taps in Kurzbefehle that make the CarPlay switch actually do
/// something — shown when the driver turns it on, which is the only thing that
/// opens it. Turning the switch off and on again is the way back to it, and
/// that is the whole of it: one switch, and the instructions for the one thing
/// switching it on requires.
///
/// It exists because the honest version of this feature is "turn it on, then go
/// and build an automation in a different app". Left unexplained, the switch
/// would be one that visibly does nothing: plugged in the next morning, nothing
/// happens, and the only conclusion available is that the app is broken. See
/// `CarPlayNavigation` for why iOS does not let the app do this on its own.
struct CarPlaySetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Opens Kurzbefehle itself. Straight to the app, not to a prepared
    /// automation: iOS has no URL that creates a CarPlay automation, so a link
    /// promising more than the front door would be a lie.
    private let shortcutsURL = URL(string: "shortcuts://")!

    private struct Step: Identifiable {
        let id: Int
        let text: String
    }

    private let steps: [Step] = [
        Step(id: 1, text: "Die App „Kurzbefehle“ öffnen und unten auf „Automation“ tippen."),
        Step(
            id: 2,
            text: "Auf „Neue Automation“ tippen — oder oben auf „+“, wenn dort schon "
                + "Automationen stehen."),
        Step(
            id: 3,
            text: "Ganz unten ins Suchfeld „CarPlay“ eintippen und den Auslöser "
                + "auswählen. Die Liste ist lang — such, statt zu scrollen."),
        Step(
            id: 4,
            text: "„Wird verbunden“ ankreuzen, „Sofort ausführen“ einschalten "
                + "und auf „Weiter“ tippen."),
        Step(
            id: 5,
            text: "Nach „Zum nächsten Stopp navigieren“ suchen und die Aktion von "
                + "EAR Router auswählen."),
        Step(id: 6, text: "Auf „Fertig“ tippen. Das war's."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(steps) { step in
                        row(step)
                    }
                } header: {
                    Text("In Kurzbefehle einrichten")
                } footer: {
                    Text(
                        "Danach startet die Navigation von selbst, sobald das Handy im "
                            + "Auto steckt — auch mit gesperrtem Bildschirm. Gefahren wird "
                            + "immer zum nächsten Stopp, der noch nicht abgehakt ist.")
                }

                Section {
                    Label(
                        "Findet die Suche kein „CarPlay“, nimm „Bluetooth“ und wähl dein "
                            + "Autoradio aus. Das verbindet sich im selben Moment, in dem du "
                            + "ansteckst — der Rest der Anleitung bleibt gleich.",
                        systemImage: "antenna.radiowaves.left.and.right")
                        .labelStyle(TintedIconLabelStyle(tint: .secondary))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Kein CarPlay in der Liste?")
                }

                Section {
                    Link(destination: shortcutsURL) {
                        SettingsRow(
                            icon: "arrow.up.forward.app.fill", tint: .indigo,
                            title: "Kurzbefehle öffnen")
                    }
                }

                Section {
                    Label(
                        "Der Schalter in „Mehr“ bleibt der Hauptschalter: steht er auf aus, "
                            + "macht die Automation nichts — sie muss nicht gelöscht werden.",
                        systemImage: "power")
                        .labelStyle(TintedIconLabelStyle(tint: .secondary))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label(
                        "Läuft gerade keine Tour oder sind alle Stopps erledigt, sagt das "
                            + "Handy kurz Bescheid und startet nichts.",
                        systemImage: "info.circle")
                        .labelStyle(TintedIconLabelStyle(tint: .secondary))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Gut zu wissen")
                }
            }
            .navigationTitle("CarPlay-Navigation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    /// A numbered step. The number is a filled circle rather than "1." in the
    /// text, because this is read once, at a kitchen table, against a screen in
    /// another app — and the thing being looked for is "where was I".
    @ScaledMetric(relativeTo: .body) private var numberSize: CGFloat = 26

    private func row(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step.id)")
                .font(.footnote.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: numberSize, height: numberSize)
                .background(Color.accentColor, in: .circle)

            Text(step.text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        // One sentence per row to VoiceOver, numbered, rather than a bare digit
        // followed by an unrelated paragraph.
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    CarPlaySetupSheet()
}
