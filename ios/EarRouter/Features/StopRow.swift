import SwiftUI

/// One stop in the route list.
///
/// Both of the things a driver does at a van door — tick the delivery off and
/// start navigating — are always-visible buttons on every customer row, never a
/// swipe. They are the app's primary interactions, done thirty-odd times a tour,
/// one-handed, often in the rain: each has to be one tap at a target you can hit
/// without looking.
///
/// Start, Lager and Ziel carry the navigation button too — the depot, the
/// warehouse and the end of the shift are three of the drives a tour actually
/// makes, and reaching them used to mean opening the stop's editor first. They
/// get no delivered tick: there is nothing to hand over at any of them.
///
/// Stacked, not side by side: two 46pt targets on top of each other still come
/// to less than the height of a row carrying a Paket and a Notiz, and keeping
/// them in one column leaves the text its full width instead of squeezing a
/// wrapped address into what is left beside them.
struct StopRow: View {
    /// The badge grows with the user's text size — at accessibility sizes a
    /// fixed 26pt circle clipped the number it exists to show.
    @ScaledMetric(relativeTo: .footnote) private var badgeSize: CGFloat = 26

    /// How far the body text has been scaled up, as a plain multiplier.
    ///
    /// The two controls on the right are the app's most-used targets — thirty
    /// times a tour, one-handed, in the rain — and they were the only thing in
    /// the row that did not grow with the text. Beside 28pt type a 46pt circle
    /// reads as a decoration rather than a button, and a driver who has turned
    /// the text up is usually the same driver who needs the bigger target.
    ///
    /// Clamped, because the scale runs to about 3.1× at the largest setting and
    /// a 140pt control would leave the address nothing to wrap into. The cap is
    /// what keeps this a bigger button rather than a different layout.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    private func scaled(_ base: CGFloat, max cap: CGFloat) -> CGFloat {
        min(base * textScale, cap)
    }

    let stop: Stop
    /// How many customers share this front door, this one included.
    var sameDoorCount: Int = 1
    /// Position among the customers — the same number the map badge shows.
    var number: Int?
    /// What is known about this door's floor, from `StockwerkNote`. `nil` when this
    /// door has not been answered for yet.
    var stockwerk: String?
    var onToggleDelivered: (() -> Void)?
    var onNavigate: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Badge and text are one top-aligned group: the number belongs
            // beside the customer's *name*, not floating halfway down beside
            // their note. The buttons are outside that group and centre
            // themselves in the row — top-aligned they left a visible hole
            // under themselves on any row taller than they are, and on a short
            // row they are the tallest thing in it, which is what used to drag
            // the badge above the name.
            HStack(alignment: .top, spacing: 12) {
                leading
                details
            }
            Spacer(minLength: 4)
            // A fixed point gets the navigation button but no delivered tick —
            // there is nothing to hand over at the depot or the warehouse, but
            // driving to them is the first and the last thing the shift does.
            if onToggleDelivered != nil || onNavigate != nil {
                trailingControls
            }
        }
        .padding(.vertical, 2)
        .opacity(stop.excluded ? 0.5 : 1)
        // Every row's separator starts under the text rather than under
        // whatever that particular row happens to lead with — otherwise a fixed
        // stop's icon and a customer's number badge, being different widths,
        // gave the same list two different separator insets.
        .alignmentGuide(.listRowSeparatorLeading) { [badgeSize] _ in badgeSize + 12 }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Leading

    @ViewBuilder
    private var leading: some View {
        switch stop.kind {
        case .customer:
            Text(number.map(String.init) ?? "•")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(
                    stop.delivered ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.onBrand))
                .frame(width: badgeSize, height: badgeSize)
                .background(
                    Circle().fill(
                        stop.delivered
                            ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.brand)))
                .accessibilityHidden(true)
        case .start:
            fixedIcon("house.fill")
        case .via:
            fixedIcon("shippingbox.fill")
        case .end:
            fixedIcon("flag.checkered")
        }
    }

    private func fixedIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.body)
            .foregroundStyle(Color.structure)
            .frame(width: badgeSize, height: badgeSize)
            .accessibilityHidden(true)
    }

    // MARK: - Details

    /// Name, address, and then everything else the stop knows about itself
    /// folded into one running line.
    ///
    /// It used to be a stack. Floor, Paket, Notiz, "2 Kunden an dieser Tür",
    /// the precision warning and the onward leg each got their own line, and
    /// four of the six were filled chips — so one customer could occupy eight
    /// lines and four coloured blocks, and a tour of thirty of them was a wall
    /// of pills with nothing subordinate to anything else. A list where
    /// everything is emphasised has no emphasis in it.
    ///
    /// Now there is a hierarchy. The name and the address lead. Underneath
    /// them, one strip of plain text carries the facts a driver checks on the
    /// way past — what to carry up, which floor, how many bells, how sure we
    /// are of the address — as runs separated by middots, which wraps like
    /// prose instead of stacking like a form. Colour is spent on exactly two
    /// things: a multi-item drop, because it changes what comes out of the van,
    /// and the driver's own note, because it is the one line that has to be
    /// read before ringing rather than skimmed after.
    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.body.weight(.medium))
                    .strikethrough(stop.delivered && stop.kind == .customer)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if stop.pinned {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pin von Hand gesetzt")
                }
            }

            if !stop.listAddress.isEmpty {
                Text(stop.listAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let meta {
                meta
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
            }

            if let notiz = stop.notiz?.trimmed, !notiz.isEmpty {
                // Still its own line, and still the one coloured thing on an
                // ordinary row. A note is a sentence someone wrote — "Hund im
                // Hof", "bitte laut klingeln" — and folding it into the strip
                // above would bury it among the facts it is meant to interrupt.
                Label {
                    Text(notiz).italic().lineLimit(3)
                } icon: {
                    Image(systemName: "note.text")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(dimmed ? Color.secondary : Color.warningText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if stop.excluded {
                Text("Für diese Tour ausgelassen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Only while the stop is still ahead. The leg belongs to the drive
            // *out* of this stop, so on one already ticked off it is a distance
            // the van has covered — true, and no longer anybody's question.
            if !dimmed, let leg = Format.leg(km: stop.nextLegKm, minutes: stop.nextLegMin) {
                Text("→ \(leg)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        // One VoiceOver element for the whole stop, read as a sentence, rather
        // than seven separate stops of the rotor for one row. The two buttons
        // stay their own elements — they are the things you act on.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The strip under the address, built with `Text` concatenation rather than
    /// an `HStack` of views: composed this way it is a single paragraph, so it
    /// wraps mid-strip at large text sizes instead of overflowing off the right
    /// edge or forcing every fact onto its own line.
    private var meta: Text? {
        var runs: [Text] = []

        if let paket = stop.paket?.trimmed, !paket.isEmpty {
            // Loud only when there is more than one thing to carry. That is the
            // fact which changes what the driver picks up before shutting the
            // van, and it is the only place an ordinary row spends the app's
            // colour.
            let run = Self.run("shippingbox.fill", paket)
            runs.append(
                PaketParser.totalQty(paket) > 1 && !dimmed
                    ? run.fontWeight(.semibold).foregroundStyle(Color.brand)
                    : run)
        }

        if let stockwerk = stockwerk?.trimmed, !stockwerk.isEmpty {
            runs.append(Self.run("stairs", NextStopCard.floorLabel(stockwerk)))
        }

        if sameDoorCount > 1 {
            runs.append(Self.run("person.2.fill", "\(sameDoorCount) an dieser Tür"))
        }

        if let precision = stop.precision {
            // The short form — "≈ Straße" — not the full sentence. The sentence
            // explaining what an approximate pin means belongs where the driver
            // does something about it: the next-stop card and the editor. In a
            // list of thirty rows it was a wrapped two-line paragraph on every
            // stop the geocoder was unsure about.
            let run = Self.run(precision.symbol, precision.shortLabel)
            runs.append(dimmed ? run : run.foregroundStyle(Color.warningText))
        }

        guard !runs.isEmpty else { return nil }
        return runs.dropFirst().reduce(runs[0]) { Text("\($0) · \($1)") }
    }

    /// One icon-and-words run of the strip.
    ///
    /// A narrow *no-break* space between the glyph and its words, not an
    /// ordinary one: the strip is a single wrapping paragraph, so an ordinary
    /// space is a place the line is allowed to end — and on a row whose Paket
    /// runs long that is exactly where it ended, leaving a warning triangle
    /// alone at the end of one line and the words it belongs to at the start of
    /// the next.
    private static func run(_ symbol: String, _ text: String) -> Text {
        Text("\(Image(systemName: symbol))\u{202F}\(text)")
    }

    // MARK: - Trailing controls

    @ViewBuilder
    private var trailingControls: some View {
        let target = scaled(46, max: 64)
        // One point size for both circles, and both drawn from the same SF
        // Symbol family — `circle`, `checkmark.circle.fill` and `circle.fill`
        // are one shape on Apple's grid, so they come out the same diameter to
        // the pixel and stay that way at every Dynamic Type size.
        //
        // Sized independently they never matched: a symbol at 27pt draws a
        // circle of about 26, next to a hand-drawn `Circle()` of 38. Two
        // controls in one column, a third apart in size, read as two unrelated
        // things rather than as the pair they are.
        let disc = scaled(30, max: 42)

        VStack(spacing: 4) {
            if let onToggleDelivered {
                Button(action: onToggleDelivered) {
                    Image(systemName: stop.delivered ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: disc, weight: .regular))
                        .foregroundStyle(stop.delivered ? Color.success : Color.secondary)
                        .frame(width: target, height: target)
                        .contentShape(.rect)
                }
                // `.borderless` is what makes several buttons in one List row
                // independently tappable — without it a tap anywhere in the row
                // fires every button in it.
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    stop.delivered ? "Zustellung zurücknehmen" : "Als zugestellt markieren")
                .sensoryFeedback(.impact(weight: .medium), trigger: stop.delivered)
            }

            if let onNavigate {
                Button(action: onNavigate) {
                    // A soft tinted disc rather than a solid brand-filled one.
                    // Filled, it put a second saturated blob on every single row
                    // next to the delivered tick, and a list where everything
                    // shouts tells the driver nothing about what matters.
                    //
                    // The disc is `circle.fill` rather than a `Circle()` shape:
                    // it is the tick's own symbol, at the tick's own point size,
                    // which is what makes the two exactly equal instead of
                    // approximately so. The arrow rides on the same layout box,
                    // so it stays centred in the disc at every text size.
                    Image(systemName: "circle.fill")
                        .font(.system(size: disc, weight: .regular))
                        .foregroundStyle(Color.brand.opacity(0.14))
                        .overlay {
                            Image(systemName: "arrow.trianglehead.turn.up.right")
                                .font(.system(size: disc * 0.42, weight: .semibold))
                                .foregroundStyle(Color.brand)
                        }
                        .frame(width: target, height: target)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Navigation zu \(title) starten")
            }
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
    let onTap: () -> Void
    let onToggleDelivered: () -> Void
    let onDelete: () -> Void
    let onNavigate: () -> Void
    let onShowOnMap: () -> Void
    var onEditStockwerk: (() -> Void)?

    private var isCustomer: Bool { stop.kind == .customer }

    var body: some View {
        StopRow(
            stop: stop,
            sameDoorCount: sameDoorCount,
            number: number,
            stockwerk: stockwerk,
            onToggleDelivered: isCustomer ? onToggleDelivered : nil,
            onNavigate: onNavigate)
            // Opens the editor. The trailing buttons are `.borderless`, so they
            // handle their own taps rather than falling through to this.
            .contentShape(.rect)
            .onTapGesture(perform: onTap)
            .accessibilityHint(
                isCustomer
                    ? "Doppeltippen zum Bearbeiten"
                    : (stop.excluded
                        ? "Doppeltippen, um diesen Punkt wieder einzuplanen"
                        : "Doppeltippen, um diesen Punkt für diese Tour auszulassen"))
            .swipeActions(edge: .leading) {
                if isCustomer {
                    Button(action: onToggleDelivered) {
                        Label(
                            stop.delivered ? "Offen" : "Geliefert",
                            systemImage: stop.delivered ? "arrow.uturn.backward" : "checkmark")
                    }
                    .tint(stop.delivered ? Color.warning : Color.success)
                }
            }
            .swipeActions(edge: .trailing) {
                if isCustomer {
                    Button(role: .destructive, action: onDelete) {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }
            .contextMenu { menu }
    }

    /// Everything you can do with this stop, spelled out.
    ///
    /// The row's own controls stay what they are — one tap to tick off, one to
    /// navigate — because those are the two things done thirty times a tour and
    /// they must not move. This is for the rest, and it is the only place two of
    /// them exist at all: seeing a stop on the map (the map could always send
    /// you to the list, never the other way round), and switching a fixed point
    /// out of the tour, which until now was a plain tap on the row with nothing
    /// anywhere saying so.
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
/// The last badge of its kind. On a stop row a floor is now one run of the
/// plain strip under the address, because there it competes with the customer's
/// name for a driver's attention and loses on purpose. Here it is the whole
/// subject of the row — this screen is a list *of floors* — so it keeps the
/// chip, which is what makes "3. Stock" and "2/Tür 14" scan as one column.
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
            dimmed ? AnyShapeStyle(.clear) : AnyShapeStyle(Color.floor.opacity(0.18)),
            in: .rect(cornerRadius: 6))
        .accessibilityLabel("Stockwerk \(NextStopCard.floorLabel(text))")
    }
}
