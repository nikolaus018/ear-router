import SwiftUI

/// One stop in the tour.
///
/// A tour is thirty of these, read with a thumb, one-handed, often in the rain.
/// So the row is built to be *skimmed*, and everything in it earns its place
/// against that:
///
/// * **Two trailing controls, side by side.** Navigation, then the delivered
///   tick on a customer or the in/out switch on a fixed point. Never stacked:
///   two discs in a column left a visible hole under themselves on a tall row
///   and made the pair the loudest thing in the list.
///
///   Navigation was briefly *not* here at all — moved to a swipe, on the
///   grounds that the driver navigates to the next stop and the next stop has
///   a full-width button on the card. That reasoning only holds while the tour
///   is driven strictly in order. A door nobody answers, a customer caught on
///   the street, a stop come back to at the end — all of those want navigation
///   to a row that is not the next one, and a swipe with wet hands in a moving
///   van is a harder gesture than a tap. It is quiet now rather than absent:
///   a plain tinted arrow, no filled disc behind it.
/// * **One solid badge in the whole list**, and it is the stop the driver is
///   on. Every other open stop is the same disc in a soft tint, delivered ones
///   grey. "Where am I" is answerable without reading a word.
/// * **A line each.** What to carry, which stairs, and the note the driver
///   wrote — three separate lines, because they are three separate checks made
///   in three different places. Everything that merely qualifies the *address*
///   stays one grey strip at the bottom. A glyph carries the colour and the
///   words stay words — see `StopFacts`.
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

    /// Presses of this row's own tick, and nothing else — it drives the haptic.
    ///
    /// Keyed on `stop.delivered`, the haptic also fired whenever the value
    /// changed from somewhere else — a tick made on Jetzt thumped again from
    /// this row in the tab behind it, and resetting the tour thumped once per
    /// visible row. The same counter Jetzt keeps, for the same reason.
    @State private var ticks = 0

    let stop: Stop
    /// How many customers share this front door, this one included.
    var sameDoorCount: Int = 1
    /// Position among the customers — the same number the map pin shows.
    var number: Int?
    /// What is known about this door's floor. `nil` when nobody has said yet.
    var stockwerk: String?
    /// What is kept about this customer across every tour — their floor, and
    /// the driver's own standing note. `nil` on a screen that has not got the
    /// rows to hand, which is what `stockwerk` above is still for.
    var info: StockwerkNote?
    /// When the van is expected here. `nil` on a settled stop, on a route that
    /// has never been optimized, and on every fixed point.
    var eta: Date?
    /// The stop the driver is on: the one row in the list with a solid badge.
    var isNext: Bool = false
    var onToggleDelivered: (() -> Void)?
    /// Switches a fixed point in or out of this tour. `nil` on a customer,
    /// which is not something a tour can decide to skip.
    var onToggleExcluded: (() -> Void)?
    /// On every row, fixed points included: the depot, the warehouse and the
    /// end of the shift are three of the drives a tour actually makes.
    var onNavigate: (() -> Void)?

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
            controls
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
            StopNumberBadge(number: number, kind: badgeKind, size: badgeSize)
        case .start:
            fixedIcon("house.fill")
        case .via:
            fixedIcon("shippingbox.fill")
        case .end:
            fixedIcon("flag.checkered")
        }
    }

    /// Four states, and the new one is the point: a door the van has been to
    /// where the meal did not leave it. Grey would file it with the deliveries
    /// and open would put it back on the list of things still to do, and it is
    /// neither.
    ///
    /// The rule itself lives on `StopNumberBadge.Kind`, because the map draws
    /// this badge too and used to answer the question differently.
    private var badgeKind: StopNumberBadge.Kind { .of(stop, isNext: isNext) }

    /// Grey, except on Lager or Ziel while it is the stop the driver is on.
    /// Then it is the list's one solid badge, as it is on Jetzt — otherwise at
    /// the start of every tour, parked at the Lager, no row said "you are here".
    private func fixedIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.footnote)
            .foregroundStyle(isNext ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.fixture))
            .frame(width: badgeSize, height: badgeSize)
            .background(Circle().fill(isNext ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            .accessibilityHidden(true)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.body)
                    .fontWeight(isNext ? .semibold : .regular)
                    .strikethrough(stop.delivered && stop.countsAsStop)
                    // A customer who was not home is not crossed off. The line
                    // through a name means "done with"; on the one row somebody
                    // still has to do something about, it means the opposite.
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if stop.pinned {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !stop.listAddress.isEmpty {
                Text(Format.address(stop.listAddress))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let paket = StopFacts.paket(stop.displayPaket, dimmed: dimmed) {
                paket
                    .font(.subheadline)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let floor = StopFacts.floor(stockwerk ?? info?.stockwerk, dimmed: dimmed) {
                floor
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            StopFacts.customerNote(info)
                .font(.subheadline)
                .opacity(dimmed ? 0.7 : 1)

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
            // does something about it: Jetzt, the map's pin card, the editor.
            runs.append(StopFacts.run(precision.symbol, precision.shortLabel))
        }

        if stop.excluded {
            runs.append(Text("Ausgelassen"))
        }

        // What happened here, when it was not the ordinary thing. A plain
        // delivery says nothing — the struck-through name and the green tick
        // have already said it.
        if let outcome = StopFacts.outcome(stop.outcome) {
            runs.append(outcome)
        }

        // Only on a door still ahead. `eta` is already `nil` on a settled one;
        // this says so a second time because the two facts arrive from
        // different places and a stale arrival time on a finished stop is
        // exactly the kind of thing nobody notices until a driver does.
        if !dimmed, !stop.isSettled, let when = StopFacts.eta(eta) {
            runs.append(when)
        }

        // Only while the stop is still ahead. The leg belongs to the drive
        // *out* of this stop, so on one already ticked off it is a distance the
        // van has covered — true, and no longer anybody's question.
        if !dimmed, let leg = Format.leg(km: stop.nextLegKm, minutes: stop.nextLegMin) {
            runs.append(Text(Format.unbroken("→ \(leg)")).monospacedDigit())
        }

        guard !runs.isEmpty else { return nil }
        return runs.dropFirst().reduce(runs[0]) { Text("\($0) · \($1)") }
    }

    // MARK: - The two controls

    private var controls: some View {
        // 44, not 42. Apple's minimum touch target is 44×44 points, and these
        // are the app's most-pressed controls — thirty times a tour each,
        // one-handed, in the rain. The tick had been trimmed to 42 to buy the
        // address two more points of width, which is exactly the trade the
        // guideline exists to stop you making.
        let target = min(44 * controlScale, 60)
        let disc = min(27 * controlScale, 36)
        let arrow = min(19 * controlScale, 26)

        // Two points apart, because the targets already carry their own
        // padding: the glyphs sit about 19 points apart, which reads as a pair
        // rather than as two unrelated buttons that happen to be adjacent.
        return HStack(spacing: 2) {
            navigateButton(arrow: arrow, target: target)
            stateButton(disc: disc, target: target)
        }
    }

    /// A bare tinted arrow, not the filled disc this used to be.
    ///
    /// Filled, it put a second saturated blob on all thirty rows next to the
    /// delivered tick — and a list where everything shouts ranks nothing. The
    /// glyph alone is unmistakably a control, sits in a full 44pt target, and
    /// costs the row no colour it cannot afford.
    @ViewBuilder
    private func navigateButton(arrow: CGFloat, target: CGFloat) -> some View {
        if let onNavigate {
            Button(action: onNavigate) {
                Image(systemName: "arrow.trianglehead.turn.up.right")
                    .font(.system(size: arrow, weight: .semibold))
                    .foregroundStyle(dimmed ? Color.secondary : Color.accentColor)
                    .frame(width: target, height: target)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Navigation zu \(title) starten")
        }
    }

    /// The tick on a customer and on Lager and Ziel while the tour drives them,
    /// the in/out switch on Start and on an excluded point. Trailing-most
    /// of the two, because it is the one pressed at every single door and the
    /// edge of the screen is where a thumb lands.
    @ViewBuilder
    private func stateButton(disc: CGFloat, target: CGFloat) -> some View {
        if let onToggleDelivered {
            Button {
                ticks += 1
                onToggleDelivered()
            } label: {
                Image(systemName: stateGlyph)
                    .font(.system(size: disc, weight: .regular))
                    .foregroundStyle(stateTint)
                    .frame(width: target, height: target)
                    .contentShape(.rect)
            }
            // `.borderless` is what makes a button inside a List row tappable on
            // its own — without it a tap anywhere in the row fires it.
            .buttonStyle(.borderless)
            .accessibilityLabel(
                stop.isSettled
                    ? "Stopp wieder öffnen"
                    : (stop.kind == .customer ? "Als geliefert markieren" : "Als erledigt markieren"))
            .sensoryFeedback(.impact(weight: .medium), trigger: ticks)
        } else if let onToggleExcluded {
            // The affordance this action never had before it was a control:
            // switching Start, Lager or Ziel out of a tour was a plain tap on
            // the row — the same gesture that opens the editor on every row
            // above it, doing something else entirely, with nothing on screen
            // saying so. The glyph names the *action*, not the state.
            //
            // Smaller and fainter than the tick beside the customers below it.
            // At the tick's size and grey, the ⊖ on Start sat in the column
            // every delivery is ticked in and read as a delete button.
            Button(action: onToggleExcluded) {
                Image(systemName: stop.excluded
                    ? "arrow.uturn.backward.circle" : "minus.circle")
                    .font(.system(size: disc * 0.75, weight: .regular))
                    .foregroundStyle(stop.excluded ? Color.accentColor : Color(.tertiaryLabel))
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

    /// The one control's glyph, which now has three things to say rather than
    /// two: delivered, settled some other way, or still owed.
    private var stateGlyph: String {
        guard let outcome = stop.outcome else { return "circle" }
        return outcome.handedOver ? "checkmark.circle.fill" : outcome.symbol
    }

    private var stateTint: Color {
        guard let outcome = stop.outcome else { return .secondary }
        return outcome.handedOver ? .delivered : .attention
    }

    /// A row the driver is finished with, whichever way it went.
    private var dimmed: Bool {
        stop.excluded || (stop.isSettled && stop.countsAsStop)
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
            parts.append(stop.outcome?.label ?? "offen")
        } else if stop.isCheckpoint {
            parts.append(stop.isSettled ? "erledigt" : "offen")
        }
        if let paket = stop.displayPaket, !paket.isEmpty { parts.append(paket) }
        if let floor = (stockwerk ?? info?.stockwerk)?.trimmed, !floor.isEmpty {
            parts.append("Stockwerk \(Format.floor(floor))")
        }
        if let note = info?.notiz?.trimmed, !note.isEmpty { parts.append("Kunde: \(note)") }
        if !dimmed, !stop.isSettled, let eta {
            parts.append("Ankunft etwa \(Format.time(eta))")
        }
        if let notiz = stop.notiz, !notiz.isEmpty { parts.append("Notiz: \(notiz)") }
        if sameDoorCount > 1 { parts.append("\(sameDoorCount) Kunden an dieser Tür") }
        if let precision = stop.precision { parts.append(precision.label) }
        if stop.excluded { parts.append("für diese Tour ausgelassen") }
        // Only while the stop is still ahead, the same as the strip on screen:
        // VoiceOver read out the leg of a drive the van had already made.
        if !dimmed, let leg = Format.leg(km: stop.nextLegKm, minutes: stop.nextLegMin) {
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
    var info: StockwerkNote?
    var eta: Date?
    var isNext: Bool = false
    let onTap: () -> Void
    let onToggleDelivered: () -> Void
    let onDelete: () -> Void
    let onNavigate: () -> Void
    let onShowOnMap: () -> Void
    var onEditStockwerk: (() -> Void)?
    /// Opens the "Nicht geliefert" sheet. `nil` on a screen that has no way
    /// to present it.
    var onRecordOutcome: (() -> Void)?
    /// Only ever called for a fixed point — the same action the row's own tap
    /// and its context menu perform.
    var onToggleExcluded: (() -> Void)?

    @Environment(\.openURL) private var openURL

    /// Copies of the address from the menu, and nothing else — it drives the
    /// haptic. The menu closes on the tap, so a feel is the one answer there
    /// is room for.
    @State private var copies = 0

    private var isCustomer: Bool { stop.kind == .customer }

    var body: some View {
        tappable
            .accessibilityHint(
                isCustomer
                    ? "Doppeltippen zum Bearbeiten"
                    : (stop.kind == .start || stop.kind == .end)
                    ? "Doppeltippen zum Bearbeiten"
                    : stop.excluded
                    ? "Wieder einplanen über die Taste am Zeilenende"
                    : "Auslassen über das Kontextmenü")
            // Both swipes are second paths to something already visible on
            // the row, which is what a swipe should be. Leading was briefly
            // "Route" — the only way to navigate to a stop that was not the
            // next one, which is a lot to ask of a gesture nothing on screen
            // advertises. Navigation is a button again, so the swipes go back
            // to what this app has always had: deliver one way, delete the
            // other.
            .swipeActions(edge: .leading) { leadingSwipes }
            .swipeActions(edge: .trailing) { trailingSwipes }
            .contextMenu { menu }
            .sensoryFeedback(.success, trigger: copies)
    }

    /// A button, so the row greys under the finger the way every tappable
    /// row on the phone does. As a bare tap gesture it gave no sign of having
    /// been touched at all until the editor slid up — which on a slow frame
    /// read as a missed tap, and got a second one.
    ///
    /// Not on the Lager, which a tap deliberately does nothing to: a row that
    /// lights up and then does nothing is worse than one that does not light
    /// up. The trailing controls are `.borderless`, so they keep their own
    /// taps inside the button.
    @ViewBuilder
    private var tappable: some View {
        if stop.kind == .via {
            row
        } else {
            Button(action: onTap) { row }
                // Plain, so the label keeps its own colours rather than taking
                // the button's tint; the list still draws the pressed row.
                .buttonStyle(.plain)
                // The row's two controls stay separate elements for
                // VoiceOver, as they were before this was a button.
                .accessibilityElement(children: .contain)
        }
    }

    private var row: some View {
        StopRow(
            stop: stop,
            sameDoorCount: sameDoorCount,
            number: number,
            stockwerk: stockwerk,
            info: info,
            eta: eta,
            isNext: isNext,
            onToggleDelivered: stop.countsAsStop ? onToggleDelivered : nil,
            onToggleExcluded: stop.canToggleExcluded ? onToggleExcluded : nil,
            onNavigate: onNavigate)
    }

    @ViewBuilder
    private var leadingSwipes: some View {
        if stop.isCheckpoint {
            Button(action: onToggleDelivered) {
                Label(
                    stop.isSettled ? "Offen" : "Erledigt",
                    systemImage: stop.isSettled ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(stop.isSettled ? .attention : .delivered)
        }
        if isCustomer {
            Button(action: onToggleDelivered) {
                Label(
                    stop.isSettled ? "Offen" : "Geliefert",
                    systemImage: stop.isSettled ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(stop.isSettled ? .attention : .delivered)
            // The second-most-made decision at a door, on the gesture
            // next to the most-made one. It is in the menu as well; a
            // driver with one free hand in the rain finds this first.
            if let onRecordOutcome, !stop.isSettled {
                Button(action: onRecordOutcome) {
                    Label("Nicht geliefert", systemImage: "bell.slash")
                }
                .tint(.attention)
            }
        }
    }

    @ViewBuilder
    private var trailingSwipes: some View {
        if isCustomer {
            // Not `role: .destructive`. That role tells the list to
            // play its own delete animation — the row collapsing away
            // — the instant the button is tapped, on the assumption
            // that the action removes the row synchronously. This one
            // does not: `onDelete` only stages a confirmation dialog,
            // so the row was still on the route a moment later and
            // popped straight back, mid-collapse, with the dialog now
            // up over a list that had visibly flinched for nothing.
            // Manual red styling gets the destructive *look* without
            // the premature animation.
            Button(action: onDelete) {
                Label("Löschen", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// Everything you can do with this stop, spelled out.
    ///
    /// The row's own two controls stay what they are — one tap to navigate,
    /// one to tick off — because those are the things done thirty times a tour
    /// and they must not move. This is for the rest, and it is the only place
    /// one of them exists at all: seeing a stop on the map, which the map could
    /// always do in the other direction and never in this one.
    @ViewBuilder
    private var menu: some View {
        Button("Navigation starten", systemImage: "arrow.trianglehead.turn.up.right",
               action: onNavigate)
        Button("Auf der Karte zeigen", systemImage: "map", action: onShowOnMap)
        // The same two Jetzt offers, so a stop that is not the current one can
        // be copied or called from its row — "1 Stunde vorher anrufen" is a note
        // about a door the driver has not reached yet.
        // Only with a street to copy, like Jetzt's button: a stop carrying a
        // postcode alone copied an empty string.
        if let street = stop.strasse?.trimmed, !street.isEmpty {
            Button("Adresse kopieren", systemImage: "doc.on.doc") {
                // Street and house number only, like Jetzt's copy button.
                UIPasteboard.general.string = street
                copies += 1
            }
        }

        if isCustomer {
            if let telefon = stop.telefon?.trimmed.nilIfEmpty,
               let url = PhoneNumbers.dialURL(for: telefon)
            {
                Button("Anrufen", systemImage: "phone") { openURL(url) }
            }
            ForEach(PhoneNumbers.inNote(stop.notiz, besides: stop.telefon)) { phone in
                Button("\(phone.display) anrufen", systemImage: "phone") {
                    if let url = phone.url { openURL(url) }
                }
            }
            Button(
                stop.isSettled ? "Als offen markieren" : "Als geliefert markieren",
                systemImage: stop.isSettled ? "arrow.uturn.backward" : "checkmark.circle",
                action: onToggleDelivered)
            if let onRecordOutcome, !stop.isSettled {
                Button("Nicht geliefert …", systemImage: "bell.slash", action: onRecordOutcome)
            }
            if let onEditStockwerk {
                Button(
                    info == nil && stockwerk == nil
                        ? "Globale Infos eintragen" : "Globale Infos ändern",
                    systemImage: "stairs", action: onEditStockwerk)
            }
            Divider()
            Button("Bearbeiten", systemImage: "pencil", action: onTap)
            Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
        } else {
            if stop.isCheckpoint {
                Button(
                    stop.isSettled ? "Als offen markieren" : "Als erledigt markieren",
                    systemImage: stop.isSettled ? "arrow.uturn.backward" : "checkmark.circle",
                    action: onToggleDelivered)
            }
            if stop.kind == .start || stop.kind == .end {
                Button("Bearbeiten", systemImage: "pencil", action: onTap)
            }
            if stop.canToggleExcluded {
                Divider()
                Button(
                    stop.excluded ? "Wieder einplanen" : "Für diese Tour auslassen",
                    systemImage: stop.excluded ? "arrow.uturn.backward" : "minus.circle",
                    action: onToggleExcluded ?? onTap)
            }
        }
    }
}
