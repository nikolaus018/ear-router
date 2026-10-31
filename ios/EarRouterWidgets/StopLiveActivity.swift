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
            lockScreen(context.state)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    numberBadge(context.state.number)
                        .padding(.leading, 4)
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
                        // The floor rides along with the address rather than
                        // taking a row of its own: this region fits about four
                        // lines, and "3. Stock" is three words that would
                        // otherwise cost the note its place.
                        if !addressLine(context.state).isEmpty {
                            Text(addressLine(context.state))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let paket = context.state.paket, !paket.isEmpty {
                            // One line, cut off. What is being asked of this
                            // line is "is there a box, and roughly what" — the
                            // full contents are read at the van, off the
                            // Ladeliste, not through a hole in the island.
                            Label(paket, systemImage: "shippingbox.fill")
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        if let notiz = context.state.notiz, !notiz.isEmpty {
                            // The note gets whatever room capping the Paket
                            // freed up. It cannot have all of it: this region
                            // is a fixed height and crops silently, so an
                            // uncapped note is drawn sliced through the middle
                            // of a line rather than ending in an ellipsis. Two
                            // lines and an honest "…", and the lock screen —
                            // right below — carries the rest.
                            Label(notiz, systemImage: "note.text")
                                .font(.subheadline)
                                .lineLimit(2)
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
        _ state: StopActivityAttributes.ContentState
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The number and the name. The tour's name and its "x von y
            // erledigt" used to sit opposite: one of them told a driver which
            // round they had been driving since six in the morning, the other
            // was a score. Neither changes anything at the door, and the height
            // they cost is the note's.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                numberBadge(state.number)
                Text(state.kunde)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Address and floor share a line here too. The lock screen card
            // has a hard maximum height and iOS crops what runs past it from
            // *both* ends — with address, floor, Paket and two notes each on
            // their own row, the row that disappeared off the top was the one
            // with the customer's name on it.
            if !addressLine(state).isEmpty {
                Text(addressLine(state))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let paket = state.paket, !paket.isEmpty {
                // Cut off at one line. A TK stop's Paket runs to four dish
                // names, and it is the least useful of these at a locked
                // screen: the box is already in the driver's hand.
                Label(paket, systemImage: "shippingbox.fill")
                    .font(.subheadline)
                    .lineLimit(1)
            }

            // The two notes get whatever the rest left, and they get it in
            // preference to everything above. Two lines each rather than
            // unlimited: the height is fixed, so "unlimited" does not mean the
            // note is shown in full — it means the card is cropped somewhere
            // nobody chose, and the name goes first.
            // `fixedSize` as well as the line limit, and both are load-bearing.
            // Without the first, a `Text` in a height-constrained container
            // compresses to a single line and truncates rather than wrapping;
            // without the second, it takes as many lines as it likes and the
            // card is cropped from both ends.
            if let info = state.kundeninfo, !info.isEmpty {
                Label(info, systemImage: "person.text.rectangle.fill")
                    .font(.subheadline)
                    .italic()
                    .lineLimit(1)
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

    /// Address and floor as one line, for the island. Either half alone when
    /// that is all there is — a bare "· 3. Stock" reads as a missing address
    /// rather than as a known floor.
    private func addressLine(_ state: StopActivityAttributes.ContentState) -> String {
        [state.adresse, state.stockwerk ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
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
