import SwiftUI

/// Mode for temperature generation: Tiefkühl (TK) or Vitalmenü (VM).
enum TemperaturModus: String, CaseIterable, Identifiable {
    case tk = "TK"
    case vm = "VM"

    var id: String { rawValue }
    var label: String { rawValue }

    var title: String {
        switch self {
        case .tk: "Tiefkühl (TK)"
        case .vm: "Vitalmenü (VM)"
        }
    }

    var rangeDescription: String {
        switch self {
        case .tk: "-18 °C bis -10 °C"
        case .vm: "-12 °C bis -8 °C"
        }
    }
}

/// The three logged tour temperatures: Start, Mitte, Ende.
struct TourTemperaturen: Equatable {
    let start: Double
    let mitte: Double
    let ende: Double
    var mitDezimal: Bool = true

    func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_AT")
        formatter.minimumFractionDigits = mitDezimal ? 1 : 0
        formatter.maximumFractionDigits = mitDezimal ? 1 : 0
        let numStr = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(numStr) °C"
    }

    var startText: String { formatted(start) }
    var mitteText: String { formatted(mitte) }
    var endeText: String { formatted(ende) }
}

enum TemperaturGenerator {
    /// Generates 3 temperatures for TK or VM so that:
    /// - For TK: between -18 °C and -10 °C, start not so cold, middle colder, end coldest.
    /// - For VM: between -12 °C and -8 °C, start not so cold, middle colder, end coldest.
    static func generate(modus: TemperaturModus, mitDezimal: Bool = true) -> TourTemperaturen {
        if mitDezimal {
            let (start, mitte, ende): (Double, Double, Double) = switch modus {
            case .tk:
                (
                    -Double(Int.random(in: 100...125)) / 10.0,
                    -Double(Int.random(in: 130...155)) / 10.0,
                    -Double(Int.random(in: 160...180)) / 10.0
                )
            case .vm:
                (
                    -Double(Int.random(in: 80...93)) / 10.0,
                    -Double(Int.random(in: 96...107)) / 10.0,
                    -Double(Int.random(in: 110...120)) / 10.0
                )
            }
            return TourTemperaturen(start: start, mitte: mitte, ende: ende, mitDezimal: true)
        } else {
            let (start, mitte, ende): (Double, Double, Double) = switch modus {
            case .tk:
                (
                    -Double(Int.random(in: 10...12)),
                    -Double(Int.random(in: 13...15)),
                    -Double(Int.random(in: 16...18))
                )
            case .vm:
                (
                    -Double(Int.random(in: 8...9)),
                    -10.0,
                    -Double(Int.random(in: 11...12))
                )
            }
            return TourTemperaturen(start: start, mitte: mitte, ende: ende, mitDezimal: false)
        }
    }
}

struct TemperaturSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("temperatur.modus") private var modusRaw = TemperaturModus.tk.rawValue
    @AppStorage("temperatur.mitDezimal") private var mitDezimal = true

    @State private var values: TourTemperaturen?
    @State private var copiedIndex: Int?
    @State private var copiedAll = false
    @State private var rollCount = 0

    private var modus: TemperaturModus {
        TemperaturModus(rawValue: modusRaw) ?? .tk
    }

    private var modusBinding: Binding<TemperaturModus> {
        Binding(
            get: { modus },
            set: { newModus in
                modusRaw = newModus.rawValue
                roll()
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker("Tourart", selection: modusBinding) {
                        ForEach(TemperaturModus.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 4)

                    if let values {
                        temperatureCards(values)
                    }

                    VStack(spacing: 12) {
                        Toggle("Mit Kommastelle", isOn: Binding(
                            get: { mitDezimal },
                            set: { newValue in
                                mitDezimal = newValue
                                roll()
                            }
                        ))
                        .font(.subheadline)
                        .padding(.horizontal, 4)

                        Button {
                            roll()
                        } label: {
                            WideButtonLabel("Neu ausdenken", systemImage: "dice.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button {
                            copyAll()
                        } label: {
                            WideButtonLabel(copiedAll ? "Kopiert!" : "Alle 3 kopieren", systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .sensoryFeedback(.success, trigger: copiedAll)
                    }

                    Text("Generiert drei plausible Temperaturen für den Kühlnachweis: Am Start noch nicht so kalt, in der Mitte kälter und am Ende am kältesten (\(modus.rangeDescription)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .padding(.horizontal)
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Temperaturen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sensoryFeedback(.impact, trigger: rollCount)
            .onAppear {
                if values == nil { roll() }
            }
        }
    }

    private func roll() {
        values = TemperaturGenerator.generate(modus: modus, mitDezimal: mitDezimal)
        rollCount += 1
        copiedIndex = nil
        copiedAll = false
    }

    @ViewBuilder
    private func temperatureCards(_ temp: TourTemperaturen) -> some View {
        VStack(spacing: 12) {
            tempRow(title: "Start", subtitle: "Vor Abfahrt", text: temp.startText, icon: "play.circle.fill", index: 0)
            Divider()
            tempRow(title: "Mitte", subtitle: "Tourmitte", text: temp.mitteText, icon: "gauge.with.needle.fill", index: 1)
            Divider()
            tempRow(title: "Ende", subtitle: "Rückkehr", text: temp.endeText, icon: "flag.checkered.circle.fill", index: 2)
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
    }

    private func tempRow(title: String, subtitle: String, text: String, icon: String, index: Int) -> some View {
        let isCopied = copiedIndex == index
        return HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(text)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(Color.primary)

            Button {
                UIPasteboard.general.string = text
                withAnimation(.snappy) { copiedIndex = index }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedIndex == index {
                        withAnimation(.snappy) { copiedIndex = nil }
                    }
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCopied ? Color.delivered : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .sensoryFeedback(.success, trigger: isCopied)
            .accessibilityLabel(isCopied ? "\(title) kopiert" : "\(title) kopieren")
        }
        .padding(.vertical, 4)
    }

    private func copyAll() {
        guard let values else { return }
        let text = "\(values.startText) / \(values.mitteText) / \(values.endeText)"
        UIPasteboard.general.string = text
        withAnimation(.snappy) { copiedAll = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { copiedAll = false }
        }
    }
}
