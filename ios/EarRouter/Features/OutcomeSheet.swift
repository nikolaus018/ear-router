import SwiftUI

/// "Nicht zugestellt" — what to record when the meal does not simply go into
/// the customer's hands.
///
/// It opens *before* the driver has decided to give up, which is the whole
/// point of it being a screen rather than a menu. The two things most likely to
/// turn a failed delivery into a successful one are on it: whatever this app
/// already knows about the door — above all "lange läuten", on somebody who is
/// slow to get to it — and the customer's own phone number, one tap away. Only
/// under those come the three ways of writing the door off.
///
/// A locked door is not a neutral event on this round. It is the one outcome
/// somebody has to hear about today, and the thirty seconds this screen spends
/// arguing for one more try are cheap against it.
struct OutcomeSheet: View {
    let stop: Stop
    /// What is known about this door, so the sheet can argue with the driver.
    let knowledge: StockwerkNote?
    let onPick: (DeliveryOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    advice
                    if let telefonURL { callButton(telefonURL) }
                    choices
                }
                .padding()
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("Nicht zugestellt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stop.kunde ?? "Stopp")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !stop.listAddress.isEmpty {
                Text(stop.listAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The one thing on this screen that might send the driver back up the
    /// stairs instead of back to the van.
    @ViewBuilder
    private var advice: some View {
        if knowledge?.langeLaeuten == true {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lange läuten").fontWeight(.semibold)
                    Text("Dieser Kunde braucht länger zur Tür. Gib ihm noch einen Moment.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "bell.badge.fill")
            }
            .labelStyle(TintedIconLabelStyle(tint: .attention))
            .symbolRenderingMode(.monochrome)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.attention.opacity(0.12), in: .rect(cornerRadius: 12))
        } else if let note = knowledge?.tuerNotiz?.trimmed, !note.isEmpty {
            StopFacts.note(note, lineLimit: 6)
                .font(.subheadline)
        }
    }

    private func callButton(_ url: URL) -> some View {
        Button { openURL(url) } label: {
            WideButtonLabel("Anrufen", systemImage: "phone.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var choices: some View {
        VStack(spacing: 10) {
            ForEach(DeliveryOutcome.exceptions, id: \.self) { outcome in
                Button {
                    onPick(outcome)
                    dismiss()
                } label: {
                    WideButtonLabel(outcome.label, systemImage: outcome.symbol)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(outcome.needsFollowUp ? .attention : .accentColor)
            }
        }
    }

    /// The customer's own number, or one written into the note. The same two
    /// `Jetzt` and the stop row's menu already offer, because a driver standing
    /// at a locked door should not have to remember which screen has the phone
    /// button on it.
    private var telefonURL: URL? {
        if let own = stop.telefon?.trimmed.nilIfEmpty,
           let url = PhoneNumbers.dialURL(for: own)
        {
            return url
        }
        return PhoneNumbers.inNote(stop.notiz, besides: stop.telefon).first?.url
    }
}
