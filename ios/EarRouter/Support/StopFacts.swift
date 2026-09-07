import SwiftUI

/// The handful of sentences this app writes about a stop, in one place.
///
/// The stop row, the card at the bottom of the tour, the map's callout and the
/// import review all describe the same customer, and they had each grown their
/// own way of saying it — one set them as filled chips, one as coloured
/// sentences, one as plain `Label`s. A driver reading the same fact in three
/// costumes has to re-learn it three times.
///
/// The rule they now share: **a glyph carries the colour, the words stay
/// words.** Colour says which kind of fact a line is — what to carry, what to
/// watch out for — and never tries to be legible type at 12pt on a tinted
/// ground, which is what forced the old palette to keep a second, darker
/// version of every colour just for text.
enum StopFacts {
    /// What comes out of the van, on a line of its own.
    ///
    /// Built as a `Text` rather than as an `HStack`, so glyph and words are one
    /// paragraph: it wraps mid-line at large text sizes instead of overflowing
    /// off the right edge.
    ///
    /// The glyph takes the accent only when there is more than one thing to
    /// carry. That is the fact which changes what the driver picks up before
    /// shutting the van door, and it is the one place an ordinary row spends a
    /// colour at all.
    ///
    /// Paket and floor used to share one line, separated by a double space, on
    /// the theory that they are one errand: what to carry and which stairs to
    /// carry it up. They read as one run-on fact — and the moment either ran
    /// long, the pair wrapped into a shape where it was no longer obvious where
    /// one ended and the other began. A line each. They are two things a driver
    /// checks separately, standing in two different places.
    static func paket(_ paket: String?, dimmed: Bool = false) -> Text? {
        guard let paket = paket?.trimmed, !paket.isEmpty else { return nil }
        let many = PaketParser.totalQty(paket) > 1
        let glyph = Text(Image(systemName: "shippingbox.fill"))
            .foregroundStyle(dimmed || !many ? Color.secondary : Color.accentColor)
        let label = Text(paket)
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .fontWeight(many ? .semibold : .regular)
        return Text("\(glyph)\u{202F}\(label)")
    }

    /// Which stairs, on a line of its own. See `paket(_:dimmed:)`.
    static func floor(_ stockwerk: String?, dimmed: Bool = false) -> Text? {
        guard let stockwerk = stockwerk?.trimmed, !stockwerk.isEmpty else { return nil }
        let glyph = Text(Image(systemName: "stairs")).foregroundStyle(Color.secondary)
        let label = Text(Format.floor(stockwerk))
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
        return Text("\(glyph)\u{202F}\(label)")
    }

    /// The driver's own words about the door, which have to be read before the
    /// bell rather than after it.
    ///
    /// Italic and secondary, with an amber glyph. It used to be set inside a
    /// filled amber block, and a note is regularly two lines of somebody's
    /// handwriting — two lines in a coloured box was the heaviest thing on a
    /// row whose subject is the customer's name.
    @ViewBuilder
    static func note(_ text: String, lineLimit: Int = 3) -> some View {
        Label {
            Text(text)
                .italic()
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "note.text")
        }
        .labelStyle(TintedIconLabelStyle(tint: .attention))
        .foregroundStyle(.secondary)
        .symbolRenderingMode(.monochrome)
    }

    /// How much the pin can be trusted. Says nothing at all when the geocoder
    /// found the building itself.
    @ViewBuilder
    static func precision(_ precision: Precision) -> some View {
        Label {
            Text(precision.label).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: precision.symbol)
        }
        .labelStyle(TintedIconLabelStyle(tint: .attention))
        .foregroundStyle(.secondary)
        .symbolRenderingMode(.monochrome)
    }

    /// One icon-and-words run of a small-print strip.
    ///
    /// A narrow *no-break* space between the glyph and its words, not an
    /// ordinary one: a strip is a single wrapping paragraph, so an ordinary
    /// space is a place the line is allowed to end — and that is exactly where
    /// it ended, leaving a warning triangle alone at the end of one line and
    /// the words it belongs to at the start of the next.
    static func run(_ symbol: String, _ text: String) -> Text {
        Text("\(Image(systemName: symbol))\u{202F}\(text)")
    }
}
