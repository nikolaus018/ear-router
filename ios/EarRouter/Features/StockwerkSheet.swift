import SwiftUI
import SwiftData

/// "Which floor?" — asked once per customer, right after the meal is handed
/// over, because that is the one moment the driver is standing in the stairwell
/// and knows the answer.
///
/// It is a sheet and not an alert for one reason: an alert can hold a text
/// field or a row of buttons, and this needs both plus the switch that turns
/// the question off for good. It is small, it comes up over the list, and every
/// way out of it — including a swipe down — leaves the tour exactly as it was.
struct StockwerkSheet: View {
    let stop: Stop

    @Environment(\.modelContext) private var context

    var body: some View {
        StockwerkForm(
            title: stop.kunde ?? "Stopp",
            subtitle: stop.listAddress,
            initial: (try? StockwerkStore.note(for: stop, in: context)) ?? nil,
            askingAfterDelivery: true
        ) { text, dontAsk in
            try StockwerkStore.save(
                stockwerk: text, dontAsk: dontAsk, for: stop, in: context)
        }
    }
}

/// The same question about a customer already in the list, reached from Mehr →
/// Stockwerke rather than from a delivery.
struct StockwerkNoteSheet: View {
    let note: StockwerkNote

    @Environment(\.modelContext) private var context

    var body: some View {
        StockwerkForm(
            title: note.title,
            subtitle: note.subtitle,
            initial: note,
            askingAfterDelivery: false
        ) { text, dontAsk in
            let cleaned = text.trimmed
            if cleaned.isEmpty && !dontAsk {
                context.delete(note)
            } else {
                note.stockwerk = cleaned.isEmpty ? nil : cleaned
                note.dontAsk = dontAsk
                note.updatedAt = Date()
            }
            try context.save()
        }
    }
}

/// The fields themselves, shared by both.
///
/// One form rather than two that look alike: the prompt after a delivery and
/// the edit from the entries list are the same question about the same row, and
/// the day they drift apart is the day one of them stops writing what the other
/// reads.
///
/// A `Form`, not a hand-built `VStack` in a `ScrollView`. The hand-built one
/// looked right and was not: the sheet drew without its own background, and the
/// `Toggle` in it never changed — taps on the one control that turns the
/// question off for good did nothing at all, while the buttons on either side
/// of it worked. A `Form` row is the platform's own answer to "a switch with a
/// label", and it behaves like one.
struct StockwerkForm: View {
    let title: String
    let subtitle: String
    let initial: StockwerkNote?
    let askingAfterDelivery: Bool
    /// Throws rather than returning a flag, so a failed write shows the driver
    /// a sentence instead of closing as though it had worked.
    let onSave: (String, Bool) throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var dontAsk = false
    @State private var loaded = false
    @State private var saveError: String?
    @FocusState private var focused: Bool

    /// The floors that come up over and over in a Viennese stairwell. Tapping
    /// one fills the field rather than saving outright: a mis-tap that saves is
    /// a wrong floor stored for good, and the field is right there to correct.
    private let quick = ["EG", "1", "2", "3", "4", "5"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                Section {
                    TextField("z. B. 3 oder 2/Tür 14", text: $text)
                        .font(.system(size: 20, weight: .semibold))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveAndClose)
                        .focused($focused)
                    quickPicks
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Stockwerk")
                }

                Section {
                    Toggle("Nicht mehr fragen", isOn: $dontAsk)
                } footer: {
                    Text(
                        dontAsk
                            ? "Dieser Kunde wird nie wieder nachgefragt — auch auf jeder "
                                + "künftigen Tour nicht."
                            : "Wird für diesen Kunden gespeichert und steht ab dann bei "
                                + "jeder Tour gleich in der Liste.")
                }

                Section {
                    Button(action: saveAndClose) {
                        WideButtonLabel("Speichern", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSave)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                } footer: {
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .labelStyle(TintedIconLabelStyle(tint: .attention))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(askingAfterDelivery ? "Stockwerk?" : "Stockwerk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Später", not "Abbrechen": after a delivery nothing is
                    // being cancelled — the meal is already ticked off — and
                    // the customer is simply asked about again next time.
                    Button(askingAfterDelivery ? "Später" : "Abbrechen") { dismiss() }
                }
            }
            // No automatic keyboard. The floor is one tap on a quick pick,
            // and a sheet that opens without the keyboard covering half of
            // itself is the one a driver can answer with a thumb.
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = initial?.stockwerk ?? ""
                dontAsk = initial?.dontAsk ?? false
            }
        }
        // Full height, with no `presentationDetents`.
        //
        // This sheet had `[.medium, .large]`, and on iOS 26 that left it
        // wedged: it drew as a frozen, translucent snapshot with the list
        // showing through, and *every* control inside it — the quick picks, the
        // switch, the save button — stopped responding to touches, while the
        // navigation bar above them kept working. The switch was simply the
        // first control anyone tried. Dropping the detents fixes it outright;
        // the content is a card's worth of form either way.
        .presentationDragIndicator(.visible)
    }

    /// Saving nothing at all is not an answer — except when there was something
    /// there before, where clearing the field is how a wrong floor gets taken
    /// back out.
    private var canSave: Bool {
        !text.trimmed.isEmpty || dontAsk || initial != nil
    }

    private var quickPicks: some View {
        HStack(spacing: 8) {
            ForEach(quick, id: \.self) { value in
                quickPick(value)
            }
        }
    }

    /// One floor button. Split out of the `HStack` above because three
    /// conditional style properties inside a `ForEach` is past what the type
    /// checker will solve in reasonable time.
    private func quickPick(_ value: String) -> some View {
        let picked = isPicked(value)
        return Button {
            text = value
            focused = false
        } label: {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(picked ? Color.accentColor : Color.primary)
                .background(quickPickFill(picked), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == "EG" ? "Erdgeschoss" : "\(value). Stock")
        .accessibilityAddTraits(picked ? [.isSelected] : [])
    }

    private func quickPickFill(_ picked: Bool) -> AnyShapeStyle {
        picked
            ? AnyShapeStyle(Color.accentColor.opacity(0.16))
            : AnyShapeStyle(.quaternary.opacity(0.5))
    }

    private func isPicked(_ value: String) -> Bool {
        text.trimmed.caseInsensitiveCompare(value) == .orderedSame
    }

    private func saveAndClose() {
        guard canSave else { return }
        do {
            try onSave(text, dontAsk)
            dismiss()
        } catch {
            saveError = "Konnte das Stockwerk nicht speichern."
        }
    }
}

extension View {
    /// Presents the floor question for whichever stop is waiting to be asked
    /// about.
    ///
    /// A modifier rather than a sheet written out twice, because the question
    /// is asked from both places a meal can be ticked off — the stop list and
    /// the map — and those two must not drift apart.
    func stockwerkPrompt(for stop: Binding<Stop?>) -> some View {
        sheet(item: stop) { StockwerkSheet(stop: $0) }
    }
}
