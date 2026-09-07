import SwiftUI

/// The tour reduced to the one thing the driver is doing right now.
///
/// This used to be a second copy of the customer's own list row, pinned to the
/// top of the screen under a header. That answered "which one is next" and
/// nothing else: the same 17pt name and the same strip of small chips as the
/// thirty rows below it, read at arm's length in a windscreen mount, between a
/// parking space and a stairwell. And it was visibly the same row twice on one
/// screen, which reads as a bug rather than as a pin — the code marking it said
/// as much.
///
/// So it stopped being a row. A driver between the van and the door is asking
/// four questions and no others: who and where, what do I carry up, which
/// floor, is there anything I need to know before I ring. This answers them at
/// the size they are actually asked at, and puts the two actions that move the
/// tour forward — navigate, and tick it off — under a thumb as real buttons
/// rather than as 46pt discs shared with every other row in the list.
struct NextStopCard: View {
    let stop: Stop
    let number: Int?
    /// What is known about this door's floor, or `nil` if nobody has said yet.
    let stockwerk: String?
    /// How many customers share this front door, this one included.
    let sameDoorCount: Int
    let deliveredCount: Int
    let customerCount: Int
    let openCount: Int
    let remainingKm: Double
    let remainingMinutes: Double

    let onNavigate: () -> Void
    let onDelivered: () -> Void
    let onEditStockwerk: () -> Void
    let onEdit: () -> Void

    /// The number badge and the two buttons grow with the user's text size. A
    /// driver who has turned the type up is usually the same driver who wants a
    /// bigger target, and this card is where that matters most.
    @ScaledMetric(relativeTo: .title2) private var badge: CGFloat = 38

    /// Two places on this card put two things side by side, and neither
    /// survives an accessibility text size in one row: the eyebrow, where
    /// "NÄCHSTER STOPP" hyphenated itself across three lines next to a distance
    /// doing the same, and the two buttons, which had half a phone each for a
    /// word and an icon. Both stack instead. The same switch `BusyBanner`
    /// makes, for the same reason.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            progress
            headline
            facts
            actions
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.brandWash))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.brand.opacity(0.18), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { onEdit() }
    }

    // MARK: - Progress

    /// Where the tour stands, on one line above everything else: how far
    /// through, and what is still ahead.
    ///
    /// "Noch 22 Stopps · 18,2 km" rather than "12 von 34 geliefert". Both are
    /// the same fact, but only one of them is the question a driver actually
    /// has at half past eleven — the list's own section header below still
    /// counts the deliveries, for the times the other framing is the one
    /// wanted.
    private var progress: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))

        return VStack(alignment: .leading, spacing: 6) {
            layout {
                Text("NÄCHSTER STOPP")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(Color.brand)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(remainingLine)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // A hairline, drawn by hand rather than with `ProgressView`: the
            // system bar carries its own vertical padding and a minimum height
            // that made a two-pixel rule into a twelve-point band across the
            // top of the card.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.brand.opacity(0.15))
                    Capsule()
                        .fill(Color.success)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Nächster Stopp. \(deliveredCount) von \(customerCount) geliefert. \(remainingLine)")
    }

    private var fraction: Double {
        guard customerCount > 0 else { return 0 }
        return Double(deliveredCount) / Double(customerCount)
    }

    /// Distance but not time. "Noch 10 Stopps · 51,8 km · 1 h 22 min" is wider
    /// than the half of a phone this line gets, and wrapping it pushed the
    /// progress bar and the whole card down by a line. The tour's minutes are
    /// still under the list, where there is a full width to print them in.
    private var remainingLine: String {
        let stops = "Noch \(Format.stops(openCount))"
        guard let km = Format.km(remainingKm), remainingKm >= 0.05 else { return stops }
        return "\(stops) · \(km)"
    }

    // MARK: - Who and where

    private var headline: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.map(String.init) ?? "•")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.onBrand)
                .frame(width: badge, height: badge)
                .background(Circle().fill(Color.brand))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(stop.kunde ?? "Stopp")
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !stop.listAddress.isEmpty {
                    Text(stop.listAddress)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - What to carry, and what to know

    /// The three things between the van door and the flat door, each big enough
    /// to read without stopping to look: what is being delivered, which floor
    /// it goes to, and anything the driver wrote down about the door itself.
    @ViewBuilder
    private var facts: some View {
        let paket = stop.paket?.trimmed
        let hasPaket = !(paket ?? "").isEmpty
        let note = stop.notiz?.trimmed
        let hasNote = !(note ?? "").isEmpty

        if hasPaket || stockwerk != nil || sameDoorCount > 1 || hasNote
            || stop.precision != nil {
            VStack(alignment: .leading, spacing: 8) {
                if hasPaket || stockwerk != nil || sameDoorCount > 1 {
                    // Wrapping, not scrolling: at large text sizes "3 × Menü
                    // klein" and "Dachgeschoss" do not fit on one line of a
                    // phone, and a row that overflows off the right edge hides
                    // exactly the fact it was put there to show.
                    WrappingHStack(spacing: 8) {
                        if let paket, hasPaket {
                            let qty = PaketParser.totalQty(paket)
                            FactChip(
                                symbol: "shippingbox.fill", text: paket,
                                count: qty > 1 ? qty : nil)
                        }
                        // Tappable: the floor is the one fact on this card the
                        // driver is standing in front of the evidence for, and
                        // "wrong floor" is worth one tap to fix rather than a
                        // trip back to the list and into a context menu.
                        Button(action: onEditStockwerk) {
                            FactChip(
                                symbol: "stairs",
                                text: stockwerk.map(Self.floorLabel) ?? "Stockwerk?",
                                emphasis: stockwerk == nil ? .missing : .quiet)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            stockwerk.map { "Stockwerk \(Self.floorLabel($0)), ändern" }
                                ?? "Stockwerk eintragen")

                        if sameDoorCount > 1 {
                            FactChip(
                                symbol: "person.2.fill",
                                text: "\(sameDoorCount) an dieser Tür", emphasis: .quiet)
                        }
                    }
                }

                if let note, hasNote {
                    Label {
                        Text(note).italic()
                    } icon: {
                        Image(systemName: "note.text").font(.caption)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let precision = stop.precision {
                    Label {
                        Text(precision.label)
                    } icon: {
                        Image(systemName: precision.symbol).foregroundStyle(Color.warning)
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "3" is a floor and reads better said out; anything the driver spelled
    /// out themselves is left exactly as they wrote it. Shared with
    /// `StockwerkBadge`, which makes the same call on the row below.
    static func floorLabel(_ text: String) -> String {
        let t = text.trimmed
        return t.allSatisfy(\.isNumber) && !t.isEmpty ? "\(t). Stock" : t
    }

    // MARK: - The two things you do here

    /// Navigate, then tick off. Both full-size, side by side, because they are
    /// the two ends of the same errand and the driver presses one on the way
    /// out and the other on the way back.
    ///
    /// Both are filled. Everywhere else in this app that would be one loud
    /// thing too many, but this card is the whole of driving mode and there is
    /// genuinely no third action competing with them — the colours are what
    /// separates "go there" from "done", at a glance, with a thumb already
    /// moving.
    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            Button(action: onNavigate) {
                WideButtonLabel("Route", systemImage: "arrow.trianglehead.turn.up.right")
                    .onBrandLabel()
            }
            .tint(Color.brand)

            Button(action: onDelivered) {
                WideButtonLabel("Geliefert", systemImage: "checkmark")
                    .foregroundStyle(Color.onSuccess)
            }
            .tint(Color.success)
            .sensoryFeedback(.impact(weight: .medium), trigger: stop.delivered)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

/// A single fact about the stop, as a chip: an icon and a word or two.
///
/// Three weights of the same shape, because these facts are not equally
/// important. The delivery itself carries the app's colour; a floor is context
/// and stays grey; a floor nobody has answered for yet is a dashed outline,
/// which says "tap me" without spending a colour on it.
///
/// A `count` replaces the icon with the number in a filled disc. That is the
/// one fact on the card which changes what comes out of the van before the
/// driver shuts the door, and it was briefly a solid block of colour the width
/// of the card — which made "2x Menü + 2x Nachspeise" heavier on the page than
/// the customer's own name. A 20pt disc says the same thing and knows its
/// place.
struct FactChip: View {
    enum Emphasis { case normal, quiet, missing }

    let symbol: String
    let text: String
    var count: Int?
    var emphasis: Emphasis = .normal

    var body: some View {
        HStack(spacing: 6) {
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.onBrand)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.brand))
            } else {
                Image(systemName: symbol).font(.caption)
            }
            Text(text).lineLimit(2)
        }
        .font(.subheadline.weight(count == nil ? .medium : .semibold))
        .foregroundStyle(foreground)
        .padding(.leading, count == nil ? 10 : 5)
        .padding(.trailing, 10)
        .padding(.vertical, count == nil ? 6 : 4)
        .background(background, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            if emphasis == .missing {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        Color.floorText.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    private var foreground: Color {
        switch emphasis {
        case .normal: .brand
        case .quiet, .missing: .floorText
        }
    }

    private var background: AnyShapeStyle {
        switch emphasis {
        case .normal: AnyShapeStyle(Color.brand.opacity(0.16))
        case .quiet: AnyShapeStyle(Color.floor.opacity(0.16))
        case .missing: AnyShapeStyle(Color.clear)
        }
    }
}

/// An `HStack` that wraps onto a second line instead of running off the screen.
///
/// SwiftUI has no such stack, and the alternatives are both wrong here: a
/// `ScrollView` hides the overflow behind a gesture nobody makes on a card they
/// are reading, and a `Grid` gives every chip the width of the widest one. This
/// is `Layout`, which is the supported way to answer "how wide is this actually
/// going to be" — the chips carry a Paket the driver typed and a floor they
/// wrote out, so their widths are not knowable in advance.
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
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    /// Greedy: each chip goes on the current line if it fits and starts a new
    /// one if it does not. A chip wider than the card on its own still gets its
    /// own line rather than an empty one above it.
    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : x + spacing + size.width
            if !row.indices.isEmpty && needed > width {
                rows.append(row)
                row = Row()
                x = 0
            }
            x = row.indices.isEmpty ? size.width : x + spacing + size.width
            row.indices.append(index)
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
