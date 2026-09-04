import SwiftUI

/// One stop in the route list.
///
/// Ticking a delivery off is an always-visible 44pt button on the trailing edge,
/// never a swipe. It is the app's primary interaction, done thirty-odd times a
/// tour, one-handed, often in the rain: it has to be one tap at a target you can
/// hit without looking. Navigation gets the same treatment on the "next stop"
/// card, and a swipe action everywhere else. The swipes remain as the secondary
/// path iOS users reach for, but nothing is *only* reachable that way.
struct StopRow: View {
    /// The badge grows with the user's text size — at accessibility sizes a
    /// fixed 26pt circle clipped the number it exists to show.
    @ScaledMetric(relativeTo: .footnote) private var badgeSize: CGFloat = 26

    let stop: Stop
    let isNext: Bool
    /// How many customers share this front door, this one included.
    var sameDoorCount: Int = 1
    /// Position among the customers — the same number the map badge shows.
    var number: Int?
    var onToggleDelivered: (() -> Void)?
    var onNavigate: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            details
            Spacer(minLength: 4)
            if stop.kind == .customer {
                trailingControls
            }
        }
        .padding(.vertical, 2)
        .opacity(stop.excluded ? 0.5 : 1)
    }

    // MARK: - Leading

    @ViewBuilder
    private var leading: some View {
        switch stop.kind {
        case .customer:
            Text(number.map(String.init) ?? "•")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(stop.delivered ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
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
            .foregroundStyle(Color.brand)
            .frame(width: badgeSize, height: badgeSize)
            .accessibilityHidden(true)
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(isNext ? .headline : .body.weight(.medium))
                    .strikethrough(stop.delivered && stop.kind == .customer)
                    .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if stop.pinned {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pin von Hand gesetzt")
                }
            }

            if !stop.fullAddress.isEmpty {
                Text(stop.fullAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let paket = stop.paket, !paket.isEmpty {
                PaketBadge(
                    text: paket,
                    quantity: PaketParser.totalQty(paket),
                    dimmed: stop.delivered)
            }

            if let notiz = stop.notiz, !notiz.isEmpty {
                NotizBadge(text: notiz, dimmed: stop.delivered)
            }

            if sameDoorCount > 1 {
                Label("\(sameDoorCount) Kunden an dieser Tür", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.brand)
            }

            if let precision = stop.precision {
                // Not a `Label`: its icon centres itself against the whole text
                // block, so on the two-line warnings this wraps to, the triangle
                // floated in the middle of the gap instead of sitting with the
                // first line.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: precision.symbol)
                    Text(precision.label)
                }
                .font(.caption)
                .foregroundStyle(Color.warning)
            }

            if stop.excluded {
                Text("Für diese Tour ausgelassen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let leg = Format.leg(km: stop.nextLegKm, minutes: stop.nextLegMin) {
                Text("→ \(leg)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Trailing controls

    @ViewBuilder
    private var trailingControls: some View {
        VStack(spacing: 2) {
            if let onToggleDelivered {
                Button(action: onToggleDelivered) {
                    Image(systemName: stop.delivered ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(stop.delivered ? Color.success : Color.secondary)
                        .frame(width: 54, height: 54)
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

            // Only on the "next stop" card. On an ordinary row a second
            // stacked 44pt button forces the row to ~96pt whatever its content
            // is, which left every sparse stop with a block of dead space.
            // Navigation for the other rows lives on the trailing swipe and in
            // the stop sheet — the one stop a driver actually needs to navigate
            // to right now is the next one, and that has the big button.
            if let onNavigate, isNext {
                Button(action: onNavigate) {
                    Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.brand)
                        .frame(width: 54, height: 54)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Navigation starten")
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
    let onTap: () -> Void
    let onToggleDelivered: () -> Void
    let onDelete: () -> Void
    let onNavigate: () -> Void

    private var isCustomer: Bool { stop.kind == .customer }

    var body: some View {
        StopRow(
            stop: stop,
            isNext: false,
            sameDoorCount: sameDoorCount,
            number: number,
            onToggleDelivered: isCustomer ? onToggleDelivered : nil,
            onNavigate: isCustomer ? onNavigate : nil)
            // Opens the editor. The trailing buttons are `.borderless`, so they
            // handle their own taps rather than falling through to this.
            .contentShape(.rect)
            .onTapGesture(perform: onTap)
            .swipeActions(edge: .leading) {
                if isCustomer {
                    Button(action: onToggleDelivered) {
                        Label(
                            stop.delivered ? "Offen" : "Geliefert",
                            systemImage: stop.delivered ? "arrow.uturn.backward" : "checkmark")
                    }
                    .tint(stop.delivered ? Color.orange : Color.success)
                }
            }
            .swipeActions(edge: .trailing) {
                if isCustomer {
                    Button(role: .destructive, action: onDelete) {
                        Label("Löschen", systemImage: "trash")
                    }
                    Button(action: onNavigate) {
                        Label("Navigation", systemImage: "arrow.triangle.turn.up.right.circle")
                    }
                    .tint(.blue)
                }
            }
    }
}

/// What the driver is carrying to this door.
///
/// A multi-item drop is a *filled* badge with the count in it, a single item a
/// tinted one — the difference is deliberately loud, because "two meals here"
/// is the thing you need to know before you shut the van door and walk up.
struct PaketBadge: View {
    let text: String
    let quantity: Int
    let dimmed: Bool

    private var multi: Bool { quantity > 1 }

    var body: some View {
        HStack(spacing: 5) {
            if multi {
                Text("\(quantity)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(dimmed ? Color.secondary : Color.brand)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(dimmed ? AnyShapeStyle(.clear) : AnyShapeStyle(.white)))
            } else {
                Image(systemName: "shippingbox.fill").font(.caption2)
            }
            Text(text).lineLimit(2)
        }
        .font(.caption.weight(multi ? .bold : .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(background, in: .rect(cornerRadius: 6))
    }

    private var foreground: Color {
        if dimmed { return .secondary }
        return multi ? .white : .brand
    }

    private var background: AnyShapeStyle {
        if dimmed { return AnyShapeStyle(.quaternary) }
        return multi ? AnyShapeStyle(Color.brand) : AnyShapeStyle(Color.brand.opacity(0.13))
    }
}

/// The free-text note — a door code, a dog, "bitte laut klingeln". Amber
/// because it is a thing to read before arriving, not a thing to skim past.
struct NotizBadge: View {
    let text: String
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "note.text").font(.caption2)
            Text(text).italic().lineLimit(3)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(dimmed ? Color.secondary : Color.warningText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            dimmed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.warning.opacity(0.16)),
            in: .rect(cornerRadius: 6))
    }
}
