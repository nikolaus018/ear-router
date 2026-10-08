import SwiftUI

/// Kilometerstand — what the odometer read before the tour, what it reads now,
/// and the difference. The number the driver has to write into the vehicle log
/// at the end of the day.
///
/// The point of the tool is the memory, not the subtraction: the reading typed
/// as "neu" today is the reading that will already be filled in as "alt"
/// tomorrow, so on every day after the first there is exactly one number left
/// to type. The old field stays editable anyway — a van gets swapped, someone
/// else drives it, a reading gets fat-fingered — but it is never *required*
/// input again.
struct KilometerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Kilometerstand.lastKey) private var storedReading = 0.0
    @AppStorage(Kilometerstand.hasLastKey) private var hasStoredReading = false
    @AppStorage(Kilometerstand.savedAtKey) private var storedAt = 0.0

    @State private var oldText = ""
    @State private var newText = ""
    /// Bumped on every save, purely to drive the haptic and the confirmation
    /// line. A `Bool` would not fire twice for two saves in a row.
    @State private var saveCount = 0
    /// "Gemerkten Stand löschen", waiting to be confirmed. The reading is the
    /// one number this tool exists to remember for tomorrow, and it sat one
    /// tap from gone under a footnote.
    @State private var confirmingForget = false
    @FocusState private var focus: Field?

    private enum Field { case old, new }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // The moment the reading is taken, for the log book.
                    TimelineView(.everyMinute) { context in
                        Text("\(Format.date(context.date)) · \(Format.time(context.date)) Uhr")
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 10) {
                        field("Alt", text: $oldText, field: .old)
                        field("Neu", text: $newText, field: .new)
                    }

                    result

                    Button { save() } label: {
                        WideButtonLabel("Stand merken", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(newReading == nil)

                    footnote
                }
                .padding()
            }
            // The content is short enough to fit on its own; without this the
            // whole tool rubber-bands under the finger like a half-empty list.
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Kilometerstand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
                // The decimal pad has no return key of its own, so without this
                // there is no way back out of the keyboard except tapping the
                // one strip of background it does not cover.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Tastatur schließen") { focus = nil }
                }
            }
            .sensoryFeedback(.success, trigger: saveCount)
            // The keyboard lands on the one field that still needs a number —
            // on every day but the first, that is "Neu", and the whole tool is
            // then open-type-read. Delayed for the same reason Türcode delays
            // it: asking for the keyboard mid-presentation is a race the
            // presentation animation regularly wins.
            .task {
                try? await Task.sleep(for: .milliseconds(350))
                // Not if the driver got there first during the animation.
                guard focus == nil, newText.isEmpty else { return }
                focus = oldText.isEmpty ? .old : .new
            }
        }
        .onAppear(perform: prefill)
    }

    // MARK: - Pieces

    /// Wide enough for the longest of the two field names at whatever size
    /// they are drawn.
    @ScaledMetric(relativeTo: .subheadline) private var titleWidth: CGFloat = 34

    /// The typed reading follows the user's text setting, like the answer below
    /// it and like Türcode's input field.
    ///
    /// It was a hard-coded 22pt — the one thing on this screen that did not
    /// move. With the text turned up, "Alt" and "km" grew to two or three times
    /// the height of the number sitting between them, on a screen whose entire
    /// content is two numbers. Capped, so the longest reading an odometer can
    /// show still fits on the line beside its label.
    @ScaledMetric(relativeTo: .title2) private var fieldBase: CGFloat = 22
    private var fieldSize: CGFloat { min(fieldBase, 40) }

    private func field(_ title: String, text: Binding<String>, field: Field) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                // Scaled, not a fixed 34: at an accessibility text size the
                // word did not come close to fitting, and the label naming
                // which odometer reading this is was clipped to its first
                // letter or two.
                .frame(width: titleWidth, alignment: .leading)

            TextField("0", text: text)
                .font(.system(size: fieldSize, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .focused($focus, equals: field)

            Text("km")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    }

    /// The answer, at a size that follows the user's text setting. It was a
    /// hard-coded 40pt, so on a phone where every other word had grown by half
    /// the one number the screen exists to show had not moved at all.
    @ScaledMetric(relativeTo: .largeTitle) private var readoutBase: CGFloat = 40
    private var readoutSize: CGFloat { min(readoutBase, 64) }

    private var result: some View {
        VStack(spacing: 6) {
            // Sentence case, no tracking. Tracked all-caps is a web idiom;
            // nothing on this phone labels a readout that way, and the app
            // stopped doing it on the tour card for the same reason.
            Text("Gefahren")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(drivenLabel)
                .font(.system(size: readoutSize, weight: .bold, design: .monospaced))
                .foregroundStyle(driven == nil ? Color.secondary : Color.accentColor)
                .textSelection(.enabled)
                .contentTransition(.numericText())
                .animation(.snappy, value: drivenLabel)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            // Only ever shown for a reading that is genuinely backwards. An
            // odometer does not count down, so this is a typo every time —
            // and a silent negative number is a typo that gets written into
            // the log book.
            if isBackwards {
                Label(
                    "Der neue Stand ist kleiner als der alte.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .labelStyle(TintedIconLabelStyle(tint: .attention))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footnote: some View {
        Text(footnoteText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .animation(.default, value: footnoteText)

        if hasStoredReading {
            Button("Gemerkten Stand löschen", role: .destructive) { confirmingForget = true }
                .font(.footnote)
                .padding(.top, 2)
                .confirmationDialog(
                    "Gemerkten Stand löschen?", isPresented: $confirmingForget,
                    titleVisibility: .visible
                ) {
                    Button("Löschen", role: .destructive) { forget() }
                    Button("Abbrechen", role: .cancel) {}
                } message: {
                    Text("„Alt“ muss danach wieder von Hand eingetragen werden.")
                }
        }
    }

    private var footnoteText: String {
        if saveCount > 0 {
            return "Gemerkt. Beim nächsten Öffnen steht dieser Wert schon oben."
        }
        if hasStoredReading {
            let date = Date(timeIntervalSince1970: storedAt)
            let when = storedAt > 0 ? " · \(Format.date(date))" : ""
            return "„Alt“ ist der zuletzt gemerkte Stand\(when). Kann überschrieben werden."
        }
        return "Beide Stände eintragen. „Stand merken“ übernimmt „Neu“ für das nächste Mal."
    }

    // MARK: - Numbers

    private var oldReading: Double? { Kilometerstand.parse(oldText) }
    private var newReading: Double? { Kilometerstand.parse(newText) }

    private var driven: Double? {
        guard let oldReading, let newReading, newReading >= oldReading else { return nil }
        return newReading - oldReading
    }

    private var isBackwards: Bool {
        guard let oldReading, let newReading else { return false }
        return newReading < oldReading
    }

    private var drivenLabel: String {
        guard let driven else { return "—" }
        return Kilometerstand.format(driven) + " km"
    }

    // MARK: - Actions

    /// Fills "Alt" from the remembered reading — but only into an empty field,
    /// so a value the driver is in the middle of editing survives the app being
    /// backgrounded and brought back.
    private func prefill() {
        guard oldText.isEmpty, hasStoredReading else { return }
        oldText = Kilometerstand.format(storedReading)
    }

    private func save() {
        guard let newReading else { return }
        storedReading = newReading
        hasStoredReading = true
        storedAt = Date().timeIntervalSince1970

        // The saved reading becomes the starting point right away rather than
        // only on the next open: the tour is over, and what the driver sees is
        // the state they will come back to.
        oldText = Kilometerstand.format(newReading)
        newText = ""
        focus = nil
        saveCount += 1
    }

    private func forget() {
        hasStoredReading = false
        storedReading = 0
        storedAt = 0
        oldText = ""
        newText = ""
        saveCount = 0
    }
}

/// The stored reading and the number parsing behind the Kilometerstand tool.
enum Kilometerstand {
    static let lastKey = "kilometer.lastReading"
    /// Kept separately rather than treating 0 as "nothing stored": a trip meter
    /// that has just been reset really does read 0, and that is a value worth
    /// remembering like any other.
    static let hasLastKey = "kilometer.hasLastReading"
    static let savedAtKey = "kilometer.savedAt"

    private static let atLocale = Locale(identifier: "de_AT")

    /// A typed odometer reading.
    ///
    /// The decimal pad offers the locale's own separator, so on this phone the
    /// comma is what a driver actually types — but a pasted value can carry a
    /// dot, and can carry both when it has a thousands separator too. Whichever
    /// separator comes last is the decimal one; the other is grouping and gets
    /// dropped. Anything that is not a plain non-negative number is `nil`,
    /// which the tool shows as "—" rather than as a wrong distance.
    static func parse(_ text: String) -> Double? {
        var s = text.trimmed
        s.removeAll { $0 == " " || $0 == "\u{00A0}" || $0 == "\u{202F}" || $0 == "'" }
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) else {
            return nil
        }

        if let lastComma = s.lastIndex(of: ","), let lastDot = s.lastIndex(of: ".") {
            let grouping: Character = lastComma > lastDot ? "." : ","
            s.removeAll { $0 == grouping }
        }
        s = s.replacingOccurrences(of: ",", with: ".")

        guard let value = Double(s), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// "132" and "132,5" — a whole number of kilometres keeps no decimal at
    /// all, because an odometer is read as a whole number.
    ///
    /// No thousands separator, even though six-digit readings are the normal
    /// case here and grouping would read better. This string is put straight
    /// back into the "Alt" text field, where `parse` has to read it again: a
    /// grouped "132.000" is indistinguishable from a decimal one, and a
    /// remembered 132.000 km would have come back as 132 km.
    static func format(_ value: Double) -> String {
        value.formatted(
            .number.precision(.fractionLength(0...1)).grouping(.never).locale(atLocale))
    }
}
