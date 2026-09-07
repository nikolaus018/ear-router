import SwiftUI

/// The stop the driver is on, pinned to the bottom of the tour.
///
/// It used to be a card wedged into the middle of the list, between the tour's
/// fixed points and its customers — which meant two things. It scrolled away,
/// so the one question a driver asks all day ("who is next, and what do I carry
/// up") was answerable only from the top of the screen. And it sat directly
/// above a list row describing the same customer, so the screen showed the same
/// stop twice, four rows apart, in two different sizes.
///
/// Pinning it to the bottom fixes both at once and is how this phone has always
/// handled "the thing you are doing now, while you look at something else":
/// the Now Playing bar, the route card in Maps, the call banner. The list above
/// goes back to being one uninterrupted sequence — which is what a tour is —
/// and the card becomes chrome rather than a row that got promoted.
///
/// It also stopped asking for the floor. That question is asked automatically
/// the moment a delivery is ticked off (see `StockwerkStore.shouldAsk`), which
/// is the one moment the driver is standing in front of the answer; a second
/// prompt here bought nothing and cost the card a line it could not spare.
struct NowCard: View {
    let stop: Stop
    let number: Int?
    /// What is known about this door's floor, or `nil` if nobody has said yet.
    let stockwerk: String?
    /// How many customers share this front door, this one included.
    let sameDoorCount: Int

    let onNavigate: () -> Void
    let onDelivered: () -> Void
    /// Opens the stop's editor — the card's own chevron, and a tap anywhere on
    /// the text.
    let onOpen: () -> Void

    /// The width the card should occupy, measured from the screen by whoever
    /// presents it.
    ///
    /// A real number rather than "as wide as you can be": `safeAreaInset`
    /// proposes an *unspecified* width to its content, so left to itself the
    /// card sizes to whichever customer happens to have the longest name.
    var width: CGFloat = 320

    /// The badge grows with the user's text size. A driver who has turned the
    /// type up is usually the same driver who wants a bigger target.
    @ScaledMetric(relativeTo: .headline) private var badge: CGFloat = 30

    /// The two buttons do not survive an accessibility text size side by side —
    /// they had half a phone each for a word and an icon — so they stack.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How many times "Geliefert" has been pressed on this card, and nothing
    /// more — it drives the haptic and is read by nothing else.
    ///
    /// The obvious trigger is `stop.delivered`, and it never fired once: this
    /// card only ever shows the next open stop, so its stop is undelivered by
    /// definition. Tick one off and the same card is handed the *next*
    /// undelivered stop in the same update, so the value goes `false → false`
    /// and `sensoryFeedback` correctly does nothing. A counter incremented in
    /// the action fires on the press itself, which is the thing being
    /// confirmed.
    @State private var ticks = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            actions
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .symbolRenderingMode(.monochrome)
        // A material and a shadow, not glass. Glass is the right treatment for
        // a control floating over a photograph or a map; over a list of text it
        // let a customer's name from the row underneath show through the
        // customer's name on the card, and the two are regularly the same name.
        // `.regularMaterial` is what the Now Playing bar and every system
        // toolbar sit on, and it stays legible over anything.
        .background(
            .regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
        .padding(.horizontal, 12)
    }

    // MARK: - Who, where, and what to carry

    private var headline: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number.map(String.init) ?? "•")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: badge, height: badge)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)

            details

            Spacer(minLength: 6)

            // Says that the card opens. Tapping it has edited the stop since
            // the tap existed, and nothing on the card admitted it: a large,
            // inviting surface that a thumb reaching for "Geliefert" can catch,
            // answering with a full editing form on the one screen a driver
            // looks at while they are still moving.
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onOpen)
        // The whole block is one thing to VoiceOver, and that thing is a
        // button — the tap gesture is otherwise invisible to it entirely.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Doppeltippen zum Bearbeiten")
    }

    /// Who, where, and what to carry — and, at accessibility text sizes, only
    /// as much of that as still leaves a tour behind the card.
    ///
    /// The card has no natural ceiling: `safeAreaInset` hands its content as
    /// much height as it asks for, and at a large accessibility size a name, an
    /// address, a Paket, a floor and a note ask for the whole screen. It grew
    /// until it covered the entire list and pushed "Geliefert" — the button the
    /// screen exists for — off the bottom behind the tab bar. The driver who
    /// most needs big text was the one who could no longer deliver anything.
    ///
    /// A scroll view inside the card was the obvious fix and the wrong one: it
    /// is a second scroller inside a screen that is already a list, and every
    /// `Text` in it that used the hierarchical `.secondary` style stopped
    /// drawing — the address and the note's words vanished, leaving a card that
    /// looked plausible and was missing the two lines read at the door.
    ///
    /// So the content adapts instead. At those sizes the card answers the two
    /// questions it cannot delegate — **who is next** and **what comes out of
    /// the van** — and the address, the note, the door count and the precision
    /// warning stay on the row directly above it, one tap from the editor that
    /// holds every one of them.
    private var details: some View {
        let brief = typeSize.isAccessibilitySize

        return VStack(alignment: .leading, spacing: 2) {
            Text(stop.kunde ?? "Stopp")
                .font(.headline)
                .lineLimit(brief ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)

            if !stop.listAddress.isEmpty, !brief {
                Text(stop.listAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let paket = StopFacts.paket(stop.paket) {
                paket
                    .font(.subheadline)
                    .lineLimit(brief ? 2 : nil)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let floor = StopFacts.floor(stockwerk) {
                floor
                    .font(.subheadline)
                    .lineLimit(brief ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if sameDoorCount > 1, !brief {
                StopFacts.run("person.2.fill", "\(sameDoorCount) an dieser Tür")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Two lines, not three. The card is chrome over a list the driver
            // still has to be able to read; a note that runs long is one tap
            // away in full, and the tap is the whole card.
            if let notiz = stop.notiz?.trimmed, !notiz.isEmpty, !brief {
                StopFacts.note(notiz, lineLimit: 2)
                    .font(.subheadline)
                    .padding(.top, 2)
            }

            if let precision = stop.precision, !brief {
                StopFacts.precision(precision)
                    .font(.caption)
                    .padding(.top, 1)
            }
        }
    }

    // MARK: - The two things you do here

    /// Navigate, then tick off — the two ends of the same errand, pressed one
    /// on the way out and the other on the way back.
    ///
    /// One of them is filled and it is "Navigation": it is what the driver
    /// presses first, and it is the action that continues the tour.
    /// "Geliefert" is the same size in green, bordered — unmistakable by hue
    /// rather than by weight. Two filled pills of equal weight made the eye
    /// choose between them every single stop.
    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))

        return layout {
            Button(action: onNavigate) {
                WideButtonLabel("Navigation", systemImage: "arrow.trianglehead.turn.up.right")
            }
            .buttonStyle(.borderedProminent)

            Button {
                // Counted here rather than read off the stop — see `ticks`.
                ticks += 1
                onDelivered()
            } label: {
                WideButtonLabel("Geliefert", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .tint(.delivered)
            .sensoryFeedback(.impact(weight: .medium), trigger: ticks)
        }
        .controlSize(.large)
    }
}
