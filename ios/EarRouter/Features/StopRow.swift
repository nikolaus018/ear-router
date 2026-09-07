import SwiftUI

/// One stop in the tour.
///
/// A tour is thirty of these, read with a thumb, one-handed, often in the rain.
/// So the row is built to be *skimmed*, and everything in it earns its place
/// against that:
///
/// * **One trailing control.** The delivered tick on a customer, the in/out
///   switch on a fixed point — never both, never two circles in a column.
///   Navigation is a leading swipe and a menu item, and a full-width button on
///   the card pinned to the bottom of the screen, which is the stop a driver
///   actually navigates to.
/// * **One solid badge in the whole list**, and it is the stop the driver is
///   on. Every other open stop is the same disc in a soft tint, delivered ones
///   grey. "Where am I" is answerable without reading a word.
/// * **Facts as lines.** What to carry and which stairs share one line; the
///   note gets its own; everything that merely qualifies the address is one
///   grey strip at the bottom. A glyph carries the colour and the words stay
///   words — see `StopFacts`.
struct StopRow: View {
    /// The badge grows with the user's text size — at accessibility sizes a
    /// fixed circle clipped the number it exists to show.
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 26

    /// The one control on the row is the app's most-pressed target — thirty
    /// times a tour — so it grows with the text too, and is clamped so a driver
    /// at the largest setting gets a bigger button rather than a different
    /// layout.
    @ScaledMetric(relativeTo: .body) private var controlScale: CGFloat = 1

    /// At accessibility text sizes the row stops being three columns and
    /// becomes two rows. See `body`.
    @Environment(\.dynamicTypeSize) private var typeSize

    let stop: Stop
    /// How many customers share this front door, this one included.
    var sameDoorCount: Int = 1
    /// Position among the customers — the same number the map pin shows.
    var number: Int?
    /// What is known about this door's floor. `nil` when nobody has said yet.
    var stockwerk: String?
    /// The stop the driver is on: the one row in the list with a solid badge.
    var isNext: Bool = false
    var onToggleDelivered: (() -> Void)?
    /// Switches a fixed point in or out of this tour. `nil` on a customer,
    /// which is not something a tour can decide to skip.
    var onToggleExcluded: (() -> Void)?

    var body: some View {
        // Three columns at ordinary text sizes; two rows once the text is big.
        //
        // Held horizontal at every size, the trailing control kept its 58pt
        // column and the badge kept its own, so at an accessibility size the
        // name and address were left about a third of the screen to wrap into —
        // and German street names do not wrap into that. "Muehlschuettelgasse"
        // broke as "Muehlschuet-telgasse" and "Petritschgasse" as
        // "Petritschga-sse", hyphenated mid-syllable, on the line whose entire
        // job is to be read at a glance from a moving van. Dropping the control
        // onto its own row hands the text the full width back, which is what
        // the words needed all along.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))

        return layout {
            HStack(alignment: .top, spacing: 10) {
                badge
                details
                // Only while the control is beside them. Stacked, the text has
                // already taken the width and a spacer would just push the
                // badge off the left.
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            }
            control
                .frame(
                    maxWidth: typeSize.isAccessibilitySize ? .infinity : nil,
                    alignment: .trailing)
        }
        .padding(.vertical, 3)
        .opacity(stop.excluded ? 0.45 : 1)
        // Flat glyphs, not shaded ones. Several of these symbols are `.fill`
        // variants and those draw hierarchically by default, so a
        // `shippingbox.fill` came out as a little shaded 3-D carton instead of
        // one solid mark in the colour it was given — which is the one thing a
        // glyph inside a line of text must not do.
        .symbolRenderingMode(.monochrome)
        // Every row's separator starts under the text rather than under
        // whatever that row happens to lead with — otherwise a fixed stop's
        // icon and a customer's number badge, being different widths, give the
        // same list two different separator insets.
        .alignmentGuide(.listRowSeparatorLeading) { [badgeSize] _ in badgeSize + 10 }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Badge

    /// The number, or the fixed point's own glyph.
    ///
    /// Three states, one of them loud. The stop the driver is on is a solid
    /// accent disc; every other open stop is the same disc at 12%; a delivered
    /// stop drops to grey. That gradient is what makes the finished half of a
    /// tour recede without hiding it.
    @ViewBuilder
    private var badge: some View {
        switch stop.kind {
        case .customer:
            Text(number.map(String.init) ?? "•")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(badgeForeground)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(badgeFill))
                .accessibilityHidden(true)
        case .start:
            fixedIcon("house.fill")
        case .via:
            fixedIcon("shippingbox.fill")
        case .end:
            fixedIcon("flag.checkered")
        }
    }

    private var badgeForeground: AnyShapeStyle {
        if stop.delivered { return AnyShapeStyle(.secondary) }
        return isNext ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.accentColor)
    }

    private var badgeFill: AnyShapeStyle {
        if stop.delivered { return AnyShapeStyle(.quaternary) }
        return isNext
            ? AnyShapeStyle(Color.accentColor)
            : AnyShapeStyle(Color.accentColor.opacity(0.12))
    }

    private func fixedIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote)
            .foregroundStyle(Color.fixture)
            .frame(width: badgeSize, height: badgeSize)
            .background(Circle().fill(.quaternary))
            .accessibilityHidden(true)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.body)
                    .fontWeight(isNext ? .semibold : .regular)
                    .strikethrough(stop.delivered && stop.kind == .customer)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if stop.pinned {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !stop.listAddress.isEmpty {
                Text(stop.listAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let carry = StopFacts.carry(
                paket: stop.paket, stockwerk: stockwerk, dimmed: dimmed) {
                carry
                    .font(.subheadline)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notiz = stop.notiz?.trimmed, !notiz.isEmpty {
                StopFacts.note(notiz)
                    .font(.subheadline)
                    .padding(.top, 2)
                    .opacity(dimmed ? 0.7 : 1)
            }

            if let meta {
                meta
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        // One VoiceOver element for the whole stop, read as a sentence, rather
        // than seven separate stops of the rotor for one row. The trailing
        // control stays its own element — it is the thing you act on.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The small print: what qualifies the *address* rather than the errand —
    /// how many bells are at this door, how sure we are of the door, how far it
    /// is to the next one, and whether this point is in the tour at all.
    private var meta: Text? {
        var runs: [Text] = []

        if sameDoorCount > 1 {
            runs.append(StopFacts.run("person.2.fill", "\(sameDoorCount) an dieser Tür"))
        }

        if let precision = stop.precision {
            // The short form — "≈ Straße" — not the full sentence. The sentence
            // explaining what an approximate pin means belongs where the driver
            // does something about it: the card at the bottom, and the editor.
            runs.append(StopFacts.run(precision.symbol, precision.shortLabel))
        }

        if stop.excluded {
            runs.append(Text("Ausgelassen"))
        }

        // Only while the stop is still ahead. The leg belongs to the drive
        // *out* of this stop, so on one already ticked off it is a distance the
        // van has covered — true, and no longer anybody's question.
        if !dimmed, let leg = Format.leg(km: stop.nextLegKm, minutes: stop.nextLegMin) {
            runs.append(Text("→ \(leg)").monospacedDigit())
        }

        guard !runs.isEmpty else { return nil }
        return runs.dropFirst().reduce(runs[0]) { Text("\($0) · \($1)") }
    }

    // MARK: - The one control

    @ViewBuilder
    private var control: some View {
        let target = min(42 * controlScale, 58)
        let disc = min(27 * controlScale, 36)

        if let onToggleDelivered {
            Button(action: onToggleDelivered) {
                Image(systemName: stop.delivered ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: disc, weight: .regular))
                    .foregroundStyle(stop.delivered ? Color.delivered : Color.secondary)
                    .frame(width: target, height: target)
                    .contentShape(.rect)
            }
            // `.borderless` is what makes a button inside a List row tappable on
            // its own — without it a tap anywhere in the row fires it.
            .buttonStyle(.borderless)
            .accessibilityLabel(
                stop.delivered ? "Zustellung zurücknehmen" : "Als zugestellt markieren")
            .sensoryFeedback(.impact(weight: .medium), trigger: stop.delivered)
        } else if let onToggleExcluded {
            // The affordance this action never had before it was a control:
            // switching Start, Lager or Ziel out of a tour was a plain tap on
            // the row — the same gesture that opens the editor on every row
            // above it, doing something else entirely, with nothing on screen
            // saying so. The glyph names the *action*, not the state.
            Button(action: onToggleExcluded) {
                Image(systemName: stop.excluded
                    ? "arrow.uturn.backward.circle" : "minus.circle")
                    .font(.system(size: disc, weight: .regular))
                    .foregroundStyle(stop.excluded ? Color.accentColor : Color.secondary)
                    .frame(width: target, height: target)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                stop.excluded
                    ? "\(title) wieder einplanen"
                    : "\(title) für diese Tour auslassen")
        }
    }

    // MARK: -

    private var dimmed: Bool {
        stop.excluded || (stop.delivered && stop.kind == .customer)
    }

    private var title: String {
        stop.kind == .customer ? (stop.kunde ?? "Stopp") : stop.fixedTitle
    }

    /// The row as one spoken sentence, in the order it matters at the van door:
    /// who and where first, then what to carry up, then anything to watch out
    /// for.
    private var accessibilityDescription: String {
        var parts: [String] = []
        if let number, stop.kind == .customer { parts.append("Stopp \(number)") }
        parts.append(title)
        if !stop.listAddress.isEmpty { parts.append(stop.listAddress) }
        if stop.kind == .customer {
            parts.append(stop.delivered ? "zugestellt" : "offen")
        }
        if let paket = stop.paket, !paket.isEmpty { parts.append(paket) }
        if let stockwerk = stockwerk?.trimmed, !stockwerk.isEmpty {
            parts.append("Stockwerk \(Format.floor(stockwerk))")
        }
        if let notiz = stop.notiz, !notiz.isEmpty { parts.append("Notiz: \(notiz)") }
        if sameDoorCount > 1 { parts.append("\(sameDoorCount) Kunden an dieser Tür") }
        if let precision = stop.precision { parts.append(precision.label) }
        if stop.excluded { parts.append("für diese Tour ausgelassen") }
        if let leg = Format.leg(km: stop.nextLegKm, minutes: stop.nextLegMin) {
            parts.append("\(leg) bis zum nächsten Stopp")
        }
        return parts.joined(separator: ", ")
    }
}

/// One row in the tour's stop list, with its swipe actions.
///
/// Split out from the screen because the swipe-action closures pushed the
/// enclosing `List` body past what the type checker will solve in reasonable
/// time — the actions are passed in as plain closures so this view stays cheap
/// to infer.
struct StopListRow: View {
    let stop: Stop
    var sameDoorCount: Int = 1
    var number: Int?
    var stockwerk: String?
    var isNext: Bool = false
    let onTap: () -> Void
    let onToggleDelivered: () -> Void
    let onDelete: () -> Void
    let onNavigate: () -> Void
    let onShowOnMap: () -> Void
    var onEditStockwerk: (() -> Void)?
    /// Only ever called for a fixed point — the same action the row's own tap
    /// and its context menu perform.
    var onToggleExcluded: (() -> Void)?

    private var isCustomer: Bool { stop.kind == .customer }

    var body: some View {
        StopRow(
            stop: stop,
            sameDoorCount: sameDoorCount,
            number: number,
            stockwerk: stockwerk,
            isNext: isNext,
            onToggleDelivered: isCustomer ? onToggleDelivered : nil,
            onToggleExcluded: isCustomer ? nil : onToggleExcluded)
            // Opens the editor. The trailing control is `.borderless`, so it
            // handles its own taps rather than falling through to this.
            .contentShape(.rect)
            .onTapGesture(perform: onTap)
            .accessibilityHint(
                isCustomer
                    ? "Doppeltippen zum Bearbeiten"
                    : (stop.excluded
                        ? "Doppeltippen, um diesen Punkt wieder einzuplanen"
                        : "Doppeltippen, um diesen Punkt für diese Tour auszulassen"))
            // Navigation lives here now, on every row including the fixed
            // points — the depot, the warehouse and the end of the shift are
            // three of the drives a tour actually makes.
            .swipeActions(edge: .leading) {
                Button(action: onNavigate) {
                    Label("Route", systemImage: "arrow.trianglehead.turn.up.right")
                }
                .tint(Color.accentColor)
            }
            .swipeActions(edge: .trailing) {
                if isCustomer {
                    Button(role: .destructive, action: onDelete) {
                        Label("Löschen", systemImage: "trash")
                    }
                    Button(action: onToggleDelivered) {
                        Label(
                            stop.delivered ? "Offen" : "Geliefert",
                            systemImage: stop.delivered ? "arrow.uturn.backward" : "checkmark")
                    }
                    .tint(stop.delivered ? .attention : .delivered)
                }
            }
            .contextMenu { menu }
    }

    /// Everything you can do with this stop, spelled out.
    ///
    /// The row's own control stays what it is — one tap to tick off — because
    /// that is the thing done thirty times a tour and it must not move. This is
    /// for the rest, and it is the only place one of them exists at all: seeing
    /// a stop on the map, which the map could always do in the other direction
    /// and never in this one.
    @ViewBuilder
    private var menu: some View {
        Button("Navigation starten", systemImage: "arrow.trianglehead.turn.up.right",
               action: onNavigate)
        Button("Auf der Karte zeigen", systemImage: "map", action: onShowOnMap)

        if isCustomer {
            Button(
                stop.delivered ? "Als offen markieren" : "Als zugestellt markieren",
                systemImage: stop.delivered ? "arrow.uturn.backward" : "checkmark.circle",
                action: onToggleDelivered)
            if let onEditStockwerk {
                Button(
                    stockwerk == nil ? "Stockwerk eintragen" : "Stockwerk ändern",
                    systemImage: "stairs", action: onEditStockwerk)
            }
            Divider()
            Button("Bearbeiten", systemImage: "pencil", action: onTap)
            Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
        } else {
            Divider()
            Button(
                stop.excluded ? "Wieder einplanen" : "Für diese Tour auslassen",
                systemImage: stop.excluded ? "arrow.uturn.backward" : "minus.circle",
                action: onTap)
        }
    }
}
