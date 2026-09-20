import SwiftUI

/// Tagesabschluss — the day, in the form somebody else has to hear it.
///
/// Comes up the moment a tour is filed, because that is the one minute the
/// driver is still sitting in the van with the day in their head. Everything on
/// it is read off stops that are already in the store; nothing here is typed
/// twice.
///
/// The share button is the point of the screen. What the office actually needs
/// is four lines and two names, and until now those were reconstructed from
/// memory an hour later, on the phone, while somebody else waited.
struct TourReportSheet: View {
    let route: Route

    @Environment(\.dismiss) private var dismiss

    // No odometer reading here, deliberately. `TourReport` takes an
    // `odometerKm` and prints a "Laut Tacho" line from it, and this screen used
    // to hold the two `@AppStorage` values for it — read nowhere, passed
    // nowhere, so the line has never once appeared. Wiring them up as they
    // stood would have been worse than leaving them dead: `Kilometerstand`
    // remembers a *reading*, not a distance, and this sheet opens the moment a
    // tour is filed — before the driver has been anywhere near the odometer
    // tool. The line would have been absent exactly when it was wanted, or
    // carried yesterday's figure. The parameter stays for a caller that has a
    // real number; this screen does not have one.

    @State private var sharing: SharedText?

    var body: some View {
        let report = TourReport(route)

        return NavigationStack {
            List {
                Section {
                    LabeledContent("Geliefert") {
                        Text("\(report.deliveredCount) von \(report.customerCount)")
                            .monospacedDigit()
                    }
                    if report.neighbourCount > 0 {
                        LabeledContent("Bei Nachbarn") {
                            Text("\(report.neighbourCount)").monospacedDigit()
                        }
                    }
                    if report.cancelledCount > 0 {
                        LabeledContent("Abbestellt") {
                            Text("\(report.cancelledCount)").monospacedDigit()
                        }
                    }
                    if let span = report.timeSpan {
                        LabeledContent("Unterwegs", value: span)
                    }
                    if let km = Format.km(report.km) {
                        LabeledContent("Strecke", value: km)
                    }
                } header: {
                    Text(Format.date(report.day))
                }

                // The part of the report anybody actually reads, and the reason
                // it is not buried under the numbers.
                if !report.notHome.isEmpty {
                    entries(
                        report.notHome, title: "Nicht angetroffen",
                        symbol: "bell.slash.fill",
                        footer: "Diese Kunden haben heute kein Essen bekommen.")
                }

                if !report.stillOpen.isEmpty {
                    entries(
                        report.stillOpen, title: "Nicht angefahren",
                        symbol: "circle.dotted",
                        footer: "Diese Stopps sind offen geblieben.")
                }

                Section {
                    Button {
                        sharing = SharedText(text: report.text)
                    } label: {
                        WideButtonLabel("Bericht teilen", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                    Button {
                        UIPasteboard.general.string = report.text
                    } label: {
                        WideButtonLabel("Bericht kopieren", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 4, trailing: 16))
                } footer: {
                    Text("Als Text — für WhatsApp, eine Mail oder die Zwischenablage.")
                }
            }
            .navigationTitle("Tagesabschluss")
            .navigationSubtitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(item: $sharing) { shared in
                ShareSheet(items: [shared.text])
            }
        }
    }

    private func entries(
        _ entries: [TourReport.Entry], title: String, symbol: String, footer: String
    ) -> some View {
        Section {
            ForEach(entries, id: \.name) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).fixedSize(horizontal: false, vertical: true)
                    if !entry.address.isEmpty {
                        Text(entry.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let telefon = entry.telefon {
                        Text(telefon)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Label(title, systemImage: symbol)
                .labelStyle(TintedIconLabelStyle(tint: .attention))
                .symbolRenderingMode(.monochrome)
        } footer: {
            Text(footer)
        }
    }
}
