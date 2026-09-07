import SwiftUI

/// The tour reduced to the one thing the driver is doing right now.
///
/// A driver between the van and the door asks four questions and no others:
/// who and where, what do I carry up, which floor, is there anything I need to
/// know before I ring. This answers them at the size they are actually asked
/// at, and puts the two actions that move the tour forward under a thumb.
///
/// The card has been the loudest thing in the app: a saturated slab carrying a
/// tracked all-caps eyebrow, a hairline progress bar, three filled chips, a
/// dashed-outline prompt and **two equally weighted filled buttons** side by
/// side. Every one of those was defensible on its own and together they left
/// nothing quiet enough to make anything else stand out.
///
/// What it is now:
///
/// * **A list of facts, not a wall of chips.** One `Label` per fact, in one
///   icon column, the way Contacts and Maps lay out everything they know about
///   a place. Colour marks the glyph; the words stay words.
/// * **One filled button.** "Route" is the accent-filled one — it is what
///   continues the journey — and "Geliefert" is a green *bordered* button
///   beside it. Two filled pills of equal weight forced the eye to choose
///   between them; hue tells them apart now, and weight says which one the
///   screen is about.
/// * **No progress bar.** How far through the tour is a property of the tour,
///   not of this stop, and it now sits under the screen's own title where it is
///   readable whether or not this card is on screen.
struct NextStopCard: View {
    let stop: Stop
    let number: Int?
    /// What is known about this door's floor, or `nil` if nobody has said yet.
    let stockwerk: String?
    /// How many customers share this front door, this one included.
    let sameDoorCount: Int

    let onNavigate: () -> Void
    let onDelivered: () -> Void
    let onEditStockwerk: () -> Void
    let onEdit: () -> Void

    /// The number badge grows with the user's text size. A driver who has
    /// turned the type up is usually the same driver who wants a bigger target,
    /// and this card is where that matters most.
    @ScaledMetric(relativeTo: .title3) private var badge: CGFloat = 34

    /// The two buttons do not survive an accessibility text size in one row —
    /// they had half a phone each for a word and an icon — so they stack
    /// instead.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How many times the driver has pressed "Geliefert" on this card, and
    /// nothing more — it drives the haptic and is read by nothing else.
    ///
    /// The obvious trigger is `stop.delivered`, which is what this was, and it
    /// never fired once. This card only ever shows the next open stop, so its
    /// stop is undelivered by definition: tick one off and the same card is
    /// handed the *next* undelivered stop in the same update, so the value goes
    /// `false → false` and `sensoryFeedback` correctly does nothing. A counter
    /// incremented in the action fires on the press itself, which is the thing
    /// being confirmed.
    @State private var ticks = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            eyebrow
            headline
            facts
            actions
        }
        .padding(16)
        // See `StopRow`: the `.fill` symbols shade themselves otherwise.
        .symbolRenderingMode(.monochrome)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.brandWash))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { onEdit() }
    }

    /// Sentence case, no letter-spacing. The tracked all-caps version this
    /// replaces is a web idiom; nothing on an iPhone labels a card that way.
    private var eyebrow: some View {
        Text("Nächster Stopp")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.brand)
            .accessibilityHidden(true)
    }

    // MARK: - Who and where

    private var headline: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.map(String.init) ?? "•")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Color.onBrand)
                .frame(width: badge, height: badge)
                .background(Circle().fill(Color.brand))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
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

            Spacer(minLength: 8)

            // Says that the card opens. Tapping it has edited the stop since
            // the tap was added, and nothing on the card admitted it: a large,
            // inviting surface that a thumb reaching for "Geliefert" can catch,
            // answering with a full editing form on the one screen a driver
            // looks at while they are still moving.
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        // The name, the address and the chevron are one thing to VoiceOver, and
        // that thing is a button — the tap gesture on the card is otherwise
        // invisible to it entirely.
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Doppeltippen zum Bearbeiten")
    }

    // MARK: - What to carry, and what to know

    /// The things between the van door and the flat door, one line each, in one
    /// icon column: what is being delivered, which floor it goes to, who else
    /// is at that door, anything the driver wrote down, and whether the pin can
    /// be trusted.
    @ViewBuilder
    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let paket = stop.paket?.trimmed, !paket.isEmpty {
                let many = PaketParser.totalQty(paket) > 1
                Label {
                    Text(paket)
                        .fontWeight(many ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(many ? Color.brand : Color.secondary)
                }
                .font(.body)
            }

            // Tappable either way: the floor is the one fact on this card the
            // driver is standing in front of the evidence for, and "wrong
            // floor" is worth one tap to fix rather than a trip back to the
            // list and into a context menu.
            //
            // Unknown, it is an ordinary accent-coloured button rather than the
            // dashed-outline chip it used to be. A dashed border is not
            // something this phone draws anywhere; a tinted verb is how iOS has
            // always said "there is something to add here".
            Button(action: onEditStockwerk) {
                if let stockwerk = stockwerk?.trimmed, !stockwerk.isEmpty {
                    Label(Self.floorLabel(stockwerk), systemImage: "stairs")
                        .font(.body)
                        .foregroundStyle(.primary)
                } else {
                    Label("Stockwerk eintragen", systemImage: "stairs")
                        .font(.body)
                        .foregroundStyle(Color.brand)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                stockwerk.map { "Stockwerk \(Self.floorLabel($0)), ändern" }
                    ?? "Stockwerk eintragen")

            if sameDoorCount > 1 {
                Label("\(sameDoorCount) an dieser Tür", systemImage: "person.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let note = stop.notiz?.trimmed, !note.isEmpty {
                Label {
                    Text(note)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "note.text").foregroundStyle(Color.warning)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if let precision = stop.precision {
                Label {
                    Text(precision.label).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: precision.symbol).foregroundStyle(Color.warning)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// "3" is a floor and reads better said out; anything the driver spelled
    /// out themselves is left exactly as they wrote it. Shared with
    /// `StockwerkBadge` and the stop row, which make the same call.
    static func floorLabel(_ text: String) -> String {
        let t = text.trimmed
        return t.allSatisfy(\.isNumber) && !t.isEmpty ? "\(t). Stock" : t
    }

    // MARK: - The two things you do here

    /// Navigate, then tick off — the two ends of the same errand, pressed one
    /// on the way out and the other on the way back.
    ///
    /// One of them is filled and it is "Route": it is what the driver presses
    /// first, and it is the action that continues the tour. "Geliefert" is the
    /// same size in green, bordered — unmistakable by hue, and no longer
    /// competing for the eye with the button next to it. Filling both was one
    /// loud thing too many on a card that is already the app's focal point.
    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            Button(action: onNavigate) {
                WideButtonLabel("Route", systemImage: "arrow.trianglehead.turn.up.right")
                    .onBrandLabel()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)

            Button {
                // Counted here rather than read off the stop — see `ticks`.
                ticks += 1
                onDelivered()
            } label: {
                WideButtonLabel("Geliefert", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .tint(Color.success)
            .sensoryFeedback(.impact(weight: .medium), trigger: ticks)
        }
        .controlSize(.large)
    }
}

/// An `HStack` that wraps onto a second line instead of running off the screen.
///
/// SwiftUI has no such stack, and the alternatives are both wrong where this is
/// used: a `ScrollView` hides the overflow behind a gesture nobody makes on a
/// card they are reading, and a `Grid` gives every item the width of the widest
/// one. This is `Layout`, which is the supported way to answer "how wide is
/// this actually going to be" for content somebody typed.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = arrange(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, in: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                // The size the row was measured with, not a fresh unconstrained
                // one: measuring twice by two different rules is how an item
                // ends up laid out at one width and drawn at another.
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var height: CGFloat = 0
    }

    /// Greedy: each item goes on the current line if it fits and starts a new
    /// one if it does not.
    ///
    /// Every item is measured against the width actually available rather than
    /// against `.unspecified`, which asks a `Text` how wide it would like to be
    /// with nothing in its way — so an item whose contents run long answered
    /// with its whole sentence on one line, got a line of its own, correctly,
    /// and was then *placed* at that same impossible width, running off the
    /// right of the screen. Proposing the container's width instead lets it
    /// wrap inside itself. An item that fits is unaffected: content sizes to
    /// content, and a wider proposal does not make it take the room.
    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: max(0, width), height: nil))
            let needed = row.items.isEmpty ? size.width : x + spacing + size.width
            if !row.items.isEmpty && needed > width {
                rows.append(row)
                row = Row()
                x = 0
            }
            x = row.items.isEmpty ? size.width : x + spacing + size.width
            row.items.append(Item(index: index, size: size))
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
