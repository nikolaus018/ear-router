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
        case .vm: "-18 °C bis -4 °C"
        }
    }
}

/// The three logged tour temperatures: Start, Mitte, Ende. Whole degrees.
struct TourTemperaturen: Equatable {
    let start: Int
    let mitte: Int
    let ende: Int

    func formatted(_ value: Int) -> String { "\(value) °C" }

    var startText: String { formatted(start) }
    var mitteText: String { formatted(mitte) }
    var endeText: String { formatted(ende) }
}

enum TemperaturGenerator {
    /// Generates 3 whole-degree temperatures, ends included, so that the start
    /// is not so cold, the middle colder and the end coldest:
    /// - TK: from -18 °C to -10 °C.
    /// - VM: from -18 °C to -4 °C.
    static func generate(modus: TemperaturModus) -> TourTemperaturen {
        switch modus {
        case .tk:
            TourTemperaturen(
                start: -Int.random(in: 10...12),
                mitte: -Int.random(in: 13...15),
                ende: -Int.random(in: 16...18))
        case .vm:
            TourTemperaturen(
                start: -Int.random(in: 4...8),
                mitte: -Int.random(in: 9...13),
                ende: -Int.random(in: 14...18))
        }
    }
}

struct TemperaturSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("temperatur.modus") private var modusRaw = TemperaturModus.tk.rawValue

    @State private var values: TourTemperaturen?
    @State private var copiedIndex: Int?
    @State private var copiedAll = false
    @State private var rollCount = 0
    @State private var copyTask: Task<Void, Never>?
    @State private var copyAllTask: Task<Void, Never>?

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
                        .sensoryFeedback(.success, trigger: copiedAll) { _, now in now }
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
                if values == nil {
                    values = TemperaturGenerator.generate(modus: modus)
                }
            }
        }
    }

    private func roll() {
        values = TemperaturGenerator.generate(modus: modus)
        rollCount += 1
        copyTask?.cancel()
        copyAllTask?.cancel()
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
                copyTask?.cancel()
                withAnimation(.snappy) { copiedIndex = index }
                copyTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    if copiedIndex == index {
                        withAnimation(.snappy) { copiedIndex = nil }
                    }
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCopied ? Color.delivered : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .sensoryFeedback(.success, trigger: isCopied) { _, now in now }
            .accessibilityLabel(isCopied ? "\(title) kopiert" : "\(title) kopieren")
        }
        .padding(.vertical, 4)
    }

    private func copyAll() {
        guard let values else { return }
        let text = "\(values.startText) / \(values.mitteText) / \(values.endeText)"
        UIPasteboard.general.string = text
        copyAllTask?.cancel()
        withAnimation(.snappy) { copiedAll = true }
        copyAllTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { copiedAll = false }
        }
    }
}
