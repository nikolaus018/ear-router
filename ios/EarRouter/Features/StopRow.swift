import SwiftUI

/// One stop in the route list.
///
/// The rule this row is built on: **one control, one colour, one line per
/// question.** A tour is thirty of these read with a thumb, and the previous
/// row spent a filled indigo pill on the Paket, a filled amber block on the
/// note, a solid indigo disc on the number and two stacked 46pt circles on the
/// right — so every row shouted, and a list where everything shouts ranks
/// nothing.
///
/// What is left:
///
/// * **One trailing control.** The delivered tick on a customer, the in/out
///   switch on a fixed point. Never both, never two circles in a column.
///   Navigation is still one gesture away — a leading swipe, and the context
///   menu — and it is a full-width button on the next-stop card, which is the
///   stop a driver actually navigates to.
/// * **One solid badge in the whole list**, and it is the stop the driver is
///   on. Every other number is the same shape in a soft tint, delivered ones
///   in grey. That is what makes "where am I" answerable without reading.
/// * **Facts as lines, not blocks.** What to carry and which floor share one
///   line; the note gets a line with an amber glyph rather than an amber box.
///   Colour marks the glyph, the text stays text.
struct StopRow: View {
    /// The badge grows with the user's text size — at accessibility sizes a
    /// fixed circle clipped the number it exists to show.
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 26

    /// The one control on the row. It is the app's most-pressed target —
    /// thirty times a tour, one-handed, in the rain — so it grows with the
    /// text, and is clamped so a driver at the largest setting gets a bigger
    /// button rather than a different layout.
    @ScaledMetric(relativeTo: .body) private var controlScale: CGFloat = 1

    let stop: Stop
    /// How many customers share this front door, this one included.
    var sameDoorCount: Int = 1
    /// Position among the customers — the same number the map badge shows.
    var number: Int?
    /// What is known about this door's floor, from `StockwerkNote`. `nil` when
    /// this door has not been answered for yet.
    var stockwerk: String?
    /// The stop the driver is on. The one row in the list that wears a solid
    /// badge.
    var isNext: Bool = false
    var onToggleDelivered: (() -> Void)?
    /// Switches a fixed point in or out of this tour. `nil` on a customer,
    /// which is not something a tour can decide to skip.
    var onToggleExcluded: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            badge
            details
            Spacer(minLength: 4)
            control
        }
        .padding(.vertical, 3)
        .opacity(stop.excluded ? 0.45 : 1)
        // Flat glyphs, not shaded ones. Several of the symbols this row uses
        // are `.fill` variants, and those draw hierarchically by default — a
        // `shippingbox.fill` came out as a little shaded 3-D carton rather than
        // as one solid mark in the colour it was given, which is the one thing
        // a glyph in a line of text must not do.
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
    /// Three states, and only one of them is loud. The stop the driver is on is
    /// a solid accent disc; every other open stop is the same disc at 12% —
    /// still unmistakably the app's colour, still legible, but it does not
    /// compete with the one row that matters. A delivered stop drops to grey,
    /// which is what makes the finished half of a tour recede.
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
        return isNext ? AnyShapeStyle(Color.onBrand) : AnyShapeStyle(Color.brand)
    }

    private var badgeFill: AnyShapeStyle {
        if stop.delivered { return AnyShapeStyle(.quaternary) }
        return isNext
            ? AnyShapeStyle(Color.brand)
            : AnyShapeStyle(Color.brand.opacity(0.12))
    }

    private func fixedIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote)
            .foregroundStyle(Color.structure)
            .frame(width: badgeSize, height: badgeSize)
            .background(Circle().fill(.quaternary))
            .accessibilityHidden(true)
    }

    // MARK: - Details

    /// Who and where, then what to carry and which stairs, then the note, then
    /// the small print — in the order they are needed between the van and the
    /// door, one line each.
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

            if let carry {
                carry
                    .font(.subheadline)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notiz = stop.notiz?.trimmed, !notiz.isEmpty {
                // A line, not a filled block. The amber is on the glyph, where
                // it marks the line without setting a sentence in a colour —
                // the note is regularly two lines of somebody's handwriting,
                // and two lines inside a coloured box was the heaviest thing on
                // the row.
                Label {
                    Text(notiz)
                        .italic()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "note.text")
                        .foregroundStyle(dimmed ? Color.secondary : Color.warning)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
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

    /// What comes out of the van, and which stairs it goes up — one line,
    /// because it is one errand and the driver reads it once, at the van door.
    ///
    /// Built by concatenating `Text` rather than as an `HStack`, so the whole
    /// thing is a single paragraph: it wraps mid-line at large text sizes
    /// instead of overflowing off the right edge or forcing each fact onto a
    /// line of its own.
    ///
    /// The Paket's glyph is the app's colour only when there is more than one
    /// thing to carry — that is the fact which changes what the driver picks up
    /// before shutting the door, and it is the one place an ordinary row spends
    /// a colour at all.
    private var carry: Text? {
        var runs: [Text] = []

        if let paket = stop.paket?.trimmed, !paket.isEmpty {
            let many = PaketParser.totalQty(paket) > 1
            let glyph = Text(Image(systemName: "shippingbox.fill"))
                .foregroundStyle(dimmed ? Color.secondary : (many ? Color.brand : Color.secondary))
            let label = Text(paket)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .fontWeight(many ? .semibold : .regular)
            runs.append(Text("\(glyph)\u{202F}\(label)"))
        }

        if let stockwerk = stockwerk?.trimmed, !stockwerk.isEmpty {
            let glyph = Text(Image(systemName: "stairs")).foregroundStyle(Color.secondary)
            let label = Text(NextStopCard.floorLabel(stockwerk))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            runs.append(Text("\(glyph)\u{202F}\(label)"))
        }

        guard !runs.isEmpty else { return nil }
        return runs.dropFirst().reduce(runs[0]) { Text("\($0)  \($1)") }
    }

    /// The small print: what qualifies the *address* rather than the errand —
    /// how many bells are at this door, how sure we are of the door, how far it
    /// is to the next one, and whether this point is in the tour at all.
    private var meta: Text? {
        var runs: [Text] = []

        if sameDoorCount > 1 {
            runs.append(Self.run("person.2.fill", "\(sameDoorCount) an dieser Tür"))
        }

        if let precision = stop.precision {
            // The short form — "≈ Straße" — not the full sentence. The sentence
            // explaining what an approximate pin means belongs where the driver
            // does something about it: the next-stop card and the editor.
            let run = Self.run(precision.symbol, precision.shortLabel)
            runs.append(dimmed ? run : run.foregroundStyle(Color.warningText))
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

    /// One icon-and-words run of a strip.
    ///
    /// A narrow *no-break* space between the glyph and its words, not an
    /// ordinary one: a strip is a single wrapping paragraph, so an ordinary
    /// space is a place the line is allowed to end — and that is exactly where
    /// it ended, leaving a warning triangle alone at the end of one line and
    /// the words it belongs to at the start of the next.
    private static func run(_ symbol: String, _ text: String) -> Text {
        Text("\(Image(systemName: symbol))\u{202F}\(text)")
    }

    // MARK: - The one control

    /// The delivered tick on a customer, the in/out switch on a fixed point.
    ///
    /// Never two. This row used to carry the tick *and* a navigation disc in a
    /// column, so the most-scanned surface in the app had two competing targets
    /// on every one of thirty rows and a visible hole under them on any row
    /// taller than they were. Navigation moved to where it is actually used —
    /// a full-width button on the next-stop card, a leading swipe here, and the
    /// context menu — and the row got its width back.
    @ViewBuilder
    private var control: some View {
        let target = min(42 * controlScale, 58)
        let disc = min(27 * controlScale, 36)

        if let onToggleDelivered {
            Button(action: onToggleDelivered) {
                Image(systemName: stop.delivered ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: disc, weight: .regular))
                    .foregroundStyle(stop.delivered ? Color.success : Color.secondary)
                    .frame(width: target, height: target)
                    .contentShape(.rect)
            }
            // `.borderless` is what makes a button in a List row tappable on its
            // own — without it a tap anywhere in the row fires it.
            .buttonStyle(.borderless)
            .accessibilityLabel(
                stop.delivered ? "Zustellung zurücknehmen" : "Als zugestellt markieren")
            .sensoryFeedback(.impact(weight: .medium), trigger: stop.delivered)
        } else if let onToggleExcluded {
            // The affordance this action never had before it was a control:
            // switching Start, Lager or Ziel out of a tour was a plain tap on
            // the row — the same gesture that opens the editor on every row
            // above it, doing something else entirely, with nothing on screen
            // saying so.
            //
            // The glyph names the *action*, not the state: a minus to leave
            // this point out, an arrow to put it back.
            Button(action: onToggleExcluded) {
                Image(systemName: stop.excluded
                    ? "arrow.uturn.backward.circle" : "minus.circle")
                    .font(.system(size: disc, weight: .regular))
                    .foregroundStyle(stop.excluded ? Color.brand : Color.secondary)
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
            parts.append("Stockwerk \(NextStopCard.floorLabel(stockwerk))")
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

/// One fact, as an icon and a word or two, with no fill behind it.
///
/// It used to be a filled tag, and on a row carrying a Paket, a floor and a
/// note that was three coloured blocks under one name. The tag is now the
/// glyph: colour marks *which kind* of fact this is, and the words stay words.
/// Kept as a type because the import review shows the same facts about a
/// customer who is not a stop yet, and one should look like the other.
struct RowTag: View {
    enum Tone {
        /// A multi-item drop — the fact that changes what leaves the van.
        case loud
        /// Context: a floor, something to know rather than decide.
        case quiet
        /// The driver's own words, which have to be read before the bell.
        case note
    }

    let symbol: String
    let text: String
    var tone: Tone = .quiet
    var italic = false
    var lineLimit = 3
    /// Delivered, or left out of this tour: the glyph gives up its colour.
    var dimmed = false

    var body: some View {
        Label {
            Text(text)
                .italic(italic)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : textStyle)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(dimmed ? Color.secondary : glyph)
        }
        .font(.subheadline)
        .fontWeight(tone == .loud ? .semibold : .regular)
    }

    private var glyph: Color {
        switch tone {
        case .loud: .brand
        case .quiet: .secondary
        case .note: .warning
        }
    }

    private var textStyle: AnyShapeStyle {
        switch tone {
        case .loud, .quiet: AnyShapeStyle(.primary)
        case .note: AnyShapeStyle(.secondary)
        }
    }
}

/// One row in the route's stop list, with its swipe actions.
///
/// Split out from `RouteDetailView` because the swipe-action closures pushed
/// the enclosing `List` body past what the type checker will solve in
/// reasonable time — the actions are passed in as plain closures so this view
/// stays cheap to infer.
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
            // three of the drives a tour actually makes. It came off the row as
            // a second visible disc; one swipe is what it costs instead.
            .swipeActions(edge: .leading) {
                Button(action: onNavigate) {
                    Label("Route", systemImage: "arrow.trianglehead.turn.up.right")
                }
                .tint(Color.brand)
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
                    .tint(stop.delivered ? Color.warning : Color.success)
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

/// A saved floor, in the list of every door ever answered for.
///
/// Still a badge, and the only one left in the app. On a stop row a floor is
/// one run of the line under the address, because there it competes with the
/// customer's name and loses on purpose. Here it is the whole subject of the
/// row — this screen is a list *of floors* — so the chip is what makes
/// "3. Stock" and "2/Tür 14" scan as one column.
struct StockwerkBadge: View {
    let text: String
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "stairs").font(.caption2)
            Text(NextStopCard.floorLabel(text)).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(dimmed ? Color.secondary : Color.floorText)
        .padding(.horizontal, dimmed ? 0 : 7)
        .padding(.vertical, dimmed ? 0 : 3)
        .background(
            dimmed ? AnyShapeStyle(.clear) : AnyShapeStyle(Color.floor.opacity(0.14)),
            in: .rect(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("Stockwerk \(NextStopCard.floorLabel(text))")
    }
}
