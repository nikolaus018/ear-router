import SwiftUI

/// Türcode decoder — a manual tool for the office's own cipher sheet
/// (letter → digit). A driver types the letters a Notiz gives them (e.g.
/// "ENVV") and gets the digits back live.
///
/// Deliberately not automatic: a Notiz can also carry a code that is already
/// the literal digits to punch in, and the two look identical from the text
/// alone. So this is a tool the driver reaches for on purpose, not a guess the
/// app makes for them.
struct TuercodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool

    /// Both the field and the answer follow the user's text setting. They were
    /// hard-coded point sizes, so on a phone with the text turned up the one
    /// screen whose entire content is two strings of characters was the one
    /// screen that ignored the setting.
    @ScaledMetric(relativeTo: .title2) private var inputBase: CGFloat = 24
    @ScaledMetric(relativeTo: .largeTitle) private var readoutBase: CGFloat = 40
    private var inputSize: CGFloat { min(inputBase, 40) }
    private var readoutSize: CGFloat { min(readoutBase, 64) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(
                    "Zeichen aus der Notiz eingeben — auch das Fragezeichen, das für die "
                        + "7 steht. Zeichen ohne eigene Ziffer (z. B. X oder ein "
                        + "Bindestrich) bleiben unverändert — die gehören dann schon "
                        + "direkt zum Code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextField("z. B. EN?V", text: $input)
                    .font(.system(size: inputSize, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: .rect(cornerRadius: 14))
                    .focused($focused)

                VStack(spacing: 6) {
                    // Sentence case: see `KilometerSheet`.
                    Text("Code")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(output)
                        .font(.system(size: readoutSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .textSelection(.enabled)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: output)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 18))

                Spacer()
            }
            .padding()
            .navigationTitle("Türcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            // Focused after the sheet has finished presenting rather than in
            // `onAppear`: asking for the keyboard mid-presentation is a race
            // the presentation animation regularly wins, and the driver then
            // has to tap the field themselves.
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                focused = true
            }
        }
    }

    private var output: String {
        let trimmed = input.trimmed
        return trimmed.isEmpty ? "—" : Tuercode.decode(trimmed)
    }
}

enum Tuercode {
    /// The office's cipher sheet. Note that seven is a question mark and not a
    /// letter — the table ran C, E, Z, D, V, F, S, A, N and simply had no seven
    /// in it, so a code containing one came back with the "?" still in it and
    /// the driver standing at a keypad with eight digits and a punctuation
    /// mark.
    private static let symbolToDigit: [Character: Character] = [
        "C": "0", "E": "1", "Z": "2", "D": "3", "V": "4",
        "F": "5", "S": "6", "?": "7", "A": "8", "N": "9",
    ]

    /// A character with no entry in the table (an X, a hyphen, a space) is
    /// passed through unchanged rather than dropped or flagged — those are
    /// not encoded, they are written straight into the result as-is.
    static func decode(_ letters: String) -> String {
        String(letters.uppercased().map { symbolToDigit[$0] ?? $0 })
    }
}
