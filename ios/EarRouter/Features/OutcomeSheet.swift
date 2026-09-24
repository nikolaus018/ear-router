import SwiftUI

/// "Nicht geliefert" — what to record when the meal does not simply go into
/// the customer's hands.
///
/// It opens *before* the driver has decided to give up, which is the whole
/// point of it being a screen rather than a menu. The two things most likely to
/// turn a failed delivery into a successful one are on it: whatever has been
/// written down about this customer — "klingelt nicht, klopfen", "braucht lange
/// zur Tür" — and their own phone number, one tap away. Only under those come
/// the three ways of writing the door off.
///
/// A locked door is not a neutral event on this round. It is the one outcome
/// somebody has to hear about today, and the thirty seconds this screen spends
/// arguing for one more try are cheap against it.
struct OutcomeSheet: View {
    let stop: Stop
    /// What is known about this customer, so the sheet can argue with the
    /// driver before it lets the door be written off.
    let info: StockwerkNote?
    let onPick: (DeliveryOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// How tall the sheet needs to be for everything on it, navigation bar
    /// included — see the detent below.
    @State private var fittedHeight: CGFloat?

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
            // The content plus the insets the navigation bar and the home
            // indicator put around it: the whole sheet, measured.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top
                    + geometry.contentInsets.bottom
            } action: { _, height in
                if height > 0 { fittedHeight = height }
            }
            .navigationTitle("Nicht geliefert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        // As tall as what is on it. At full height the four buttons sat in the
        // top half of a sheet whose bottom half was empty white — the look of
        // a screen that failed to load the rest of itself. A note long enough
        // to need more than the phone has still gets the whole height, and
        // scrolls.
        .presentationDetents(fittedHeight.map { [.height($0)] } ?? [.medium])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stop.kunde ?? "Stopp")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !stop.listAddress.isEmpty {
                Text(Format.address(stop.listAddress))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The one thing on this screen that might send the driver back up the
    /// stairs instead of back to the van.
    ///
    /// Whatever was written down about this customer, at the moment it is worth
    /// the most: "klingelt nicht, klopfen" and "braucht lange zur Tür" are both
    /// ordinary things to have noted, and both of them are the difference
    /// between a failed delivery and one more try.
    @ViewBuilder
    private var advice: some View {
        StopFacts.customerNote(info, lineLimit: 8)
            .font(.subheadline)
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
                .tint(tint(outcome))
            }
        }
    }

    /// Each outcome in the colour it wears everywhere else: a meal left with a
    /// neighbour was handed over, so green like the tick; a door nobody opened
    /// amber; abbestellt grey, like its pin. Both of those used to be the
    /// accent blue here — the colour of "tap me", saying nothing about which
    /// answer was which.
    private func tint(_ outcome: DeliveryOutcome) -> Color {
        if outcome.handedOver { return .delivered }
        return outcome.needsFollowUp ? .attention : .fixture
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
