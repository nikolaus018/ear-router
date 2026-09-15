import ActivityKit
import SwiftUI
import WidgetKit

/// The current door on the lock screen and in the Dynamic Island.
///
/// What it shows is what the driver would otherwise unlock the phone and open
/// Jetzt for: who, where, what to carry, and what the note says. The note is
/// the reason this is worth having at all — "bitte immer einräumen, Kd ist
/// dement" is a thing to read before ringing, not after.
struct StopLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StopActivityAttributes.self) { context in
            lockScreen(context.state, tour: context.attributes.tour)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    numberBadge(context.state.number)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.progress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // One line each, truncating. The expanded island is a fixed
                    // height and crops silently: four stacked facts at their
                    // natural height drew the last one sliced in half
                    // lengthwise, which reads as a rendering fault rather than
                    // as text that continues. The lock screen is where the note
                    // gets room to be read — this is the glance that says which
                    // door, and whether there is a note to go and read.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.kunde)
                            .font(.headline)
                            .lineLimit(1)
                        if !context.state.adresse.isEmpty {
                            Text(context.state.adresse)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let paket = context.state.paket, !paket.isEmpty {
                            Label(paket, systemImage: "shippingbox.fill")
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        if let notiz = context.state.notiz, !notiz.isEmpty {
                            Label(notiz, systemImage: "note.text")
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            } compactLeading: {
                // The number alone. The island's compact slot is about the
                // width of two digits, and a name clipped to "Hel…" is not a
                // name.
                numberBadge(context.state.number, compact: true)
            } compactTrailing: {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.tint)
            } minimal: {
                numberBadge(context.state.number, compact: true)
            }
        }
    }

    // MARK: - Lock screen

    private func lockScreen(
        _ state: StopActivityAttributes.ContentState, tour: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                numberBadge(state.number)
                Text(state.kunde)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(tour)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(state.progress)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !state.adresse.isEmpty {
                Text(state.adresse)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let paket = state.paket, !paket.isEmpty {
                Label(paket, systemImage: "shippingbox.fill")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notiz = state.notiz, !notiz.isEmpty {
                Label(notiz, systemImage: "note.text")
                    .font(.subheadline)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    /// The stop's number, drawn the way the stop list draws it. `nil` on a stop
    /// the tour has not numbered — a route that has never been optimized — in
    /// which case the badge is left out rather than filled with a zero.
    @ViewBuilder
    private func numberBadge(_ number: Int?, compact: Bool = false) -> some View {
        if let number {
            Text("\(number)")
                .font(compact ? .caption.bold().monospacedDigit() : .subheadline.bold().monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 5 : 7)
                .padding(.vertical, compact ? 1 : 3)
                .background(.tint, in: .capsule)
        } else if !compact {
            Image(systemName: "door.left.hand.open")
                .font(.subheadline)
                .foregroundStyle(.tint)
        }
    }
}
