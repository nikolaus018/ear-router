import SwiftUI
import UIKit

extension Color {
    /// The app's own colour — a deep indigo (#4338CA, #8E9BFF in the dark).
    ///
    /// This used to be the organisation's red, and the reason it is not any
    /// more is not taste. Red was doing two jobs it cannot do at once: it was
    /// the identity *and* it is the one colour every phone, every road sign and
    /// every error message already spends on "something is wrong". An ordinary
    /// undelivered stop therefore wore the same colour as a failure, on every
    /// row of every list.
    ///
    /// The sharper problem was the pair. A stop's numbered circle was red and
    /// turned green when delivered — red against green is precisely the pair
    /// that roughly one man in twelve cannot separate, and this is an app read
    /// one-handed, in a stairwell, at a glance, by drivers. Indigo sits on the
    /// blue–yellow axis, which every common colour vision deficiency leaves
    /// intact; against it green (done), amber (check this) and red (broken) are
    /// separable for everyone.
    ///
    /// Dark mode gets the light periwinkle rather than the same value: the deep
    /// indigo is a 7.9:1 colour on white and a 2.4:1 colour on black, so holding
    /// it fixed would keep the hue and throw away the contrast.
    static let brand = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.557, green: 0.608, blue: 1.000, alpha: 1) // #8E9BFF
            : UIColor(red: 0.263, green: 0.220, blue: 0.792, alpha: 1) // #4338CA
    })

    /// Text and glyphs drawn *on top of* a `brand`-filled surface — the stop
    /// number in its circle, the count in a multi-item Paket badge.
    ///
    /// Not simply white. The dark-mode brand above is a light, high-luminance
    /// periwinkle, and white on it measures about 2.9:1 — below what small text
    /// needs. So the label flips to near-black there, which is what makes a
    /// 13pt bold digit on a coloured circle actually readable in the dark.
    static let onBrand = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.07, alpha: 1)
            : UIColor.white
    })

    /// Delivered. Matches Apple's system green in each appearance so a tick in
    /// this app looks like a tick everywhere else on the phone.
    static let success = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1) // #30D158
            : UIColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1) // #34C759
    })

    /// An approximate pin — "double check this one before you set off".
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1) // #FF9F0A
            : UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1)   // #FF9500
    })

    /// Text on a `warning`-tinted surface. The fill colour itself is
    /// unreadable as text against its own 15% background — this is the darker
    /// amber that actually carries contrast, and its lighter counterpart for
    /// dark mode.
    static let warningText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1)   // #FFBF59
            : UIColor(red: 0.478, green: 0.294, blue: 0.0, alpha: 1) // #7A4B00
    })

    /// The next-stop card's surface — the one place in the app a whole block
    /// wears the accent.
    ///
    /// Two alphas rather than one, because a wash does not scale between
    /// appearances. Seven percent of a colour laid over white still lifts a
    /// card off the page; seven percent of the same colour over black is within
    /// a shade of black, and the most important card on the screen stopped
    /// looking picked out at all in the dark.
    static let brandWash = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.557, green: 0.608, blue: 1.000, alpha: 0.16)
            : UIColor(red: 0.263, green: 0.220, blue: 0.792, alpha: 0.07)
    })

    /// `brandWash`, one step up: the row the driver has just asked to see, which
    /// has to be findable the moment the list scrolls to it.
    static let brandWashStrong = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.557, green: 0.608, blue: 1.000, alpha: 0.26)
            : UIColor(red: 0.263, green: 0.220, blue: 0.792, alpha: 0.12)
    })

    /// The scaffolding of a tour rather than the deliveries in it: the depot it
    /// starts from, a via point, the finish flag.
    ///
    /// Graphite, because these are the fixed points a driver already knows.
    /// They were brand-coloured, which made the depot as loud as a customer
    /// nobody has been to yet; a list is only skimmable if the things that
    /// change state are the only things wearing a colour.
    static let structure = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.62, alpha: 1)
            : UIColor(white: 0.42, alpha: 1)
    })

    /// The floor badge's fill — and it is deliberately colourless.
    ///
    /// Blue was the one tint left that carried no meaning here, which is a good
    /// argument for using it and a bad argument for what it does to the row:
    /// "3. Stock" is something to *know*, not something to *do*, and a fourth
    /// saturated chip beside the Paket badge and the delivered tick makes the
    /// strip of small facts under a name harder to read, not easier. Grey says
    /// label. The Paket badge next to it keeps the tint, so the difference
    /// between "two menus" and "third floor" is still instant.
    static let floor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.75, alpha: 1)
            : UIColor(white: 0.38, alpha: 1)
    })

    /// Text on a `floor`-tinted surface, for the same reason `warningText`
    /// exists: the fill at 18% is a background, not a colour to set 12pt
    /// semibold type in.
    static let floorText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.82, alpha: 1)
            : UIColor(white: 0.26, alpha: 1)
    })

    /// Drawn under the route line on the map, a few points wider than it.
    ///
    /// A 5pt line alone disappears into a motorway shield or a contour on the
    /// standard map, and into anything at all on satellite. The casing is what
    /// Apple's own route lines have: it does not colour the route, it gives the
    /// route an edge, so the line reads as one continuous thing over whatever
    /// it happens to cross.
    static let routeCasing = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.0, alpha: 0.55)
            : UIColor(white: 1.0, alpha: 0.9)
    })
}

extension View {
    /// The label of a filled brand-indigo button.
    ///
    /// `.borderedProminent` chooses its own label colour, and against the
    /// dark-mode brand — a light, high-luminance periwinkle — it chooses white,
    /// which measures about 2.9:1. That is below what any text needs, and these
    /// buttons are the app's primary action every time one appears: "Navigation",
    /// "Tour abschließen", "Neue Tour". `Color.onBrand` is the near-black that
    /// actually reads on that fill, and stays white in light mode, where white
    /// is the right answer.
    func onBrandLabel() -> some View {
        foregroundStyle(Color.onBrand)
    }
}

enum Format {
    /// Built once. Every one of these functions is called from a list row —
    /// several times per row, once more for its accessibility label — and
    /// `Locale(identifier:)` is not free enough to pay for on each of them.
    private static let atLocale = Locale(identifier: "de_AT")

    /// "12,4 km" — Austrian decimal comma, one place, which is as precise as a
    /// routed distance is meaningfully accurate.
    static func km(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return value.formatted(
            .number.precision(.fractionLength(1)).locale(atLocale)) + " km"
    }

    /// "1 h 12 min" / "12 min" — minutes only below an hour, because a delivery
    /// leg is a handful of minutes and "0 h 7 min" reads as noise.
    static func minutes(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        let total = Int(value.rounded())
        if total < 60 { return "\(total) min" }
        return "\(total / 60) h \(total % 60) min"
    }

    /// The "3,2 km · 8 min" line under a stop row.
    ///
    /// Nothing at all for a leg that rounds away to nothing. Two households in
    /// one Gemeindebau are a routed leg of zero metres, and "→ 0,0 km · 0 min"
    /// under one of them reads as missing data rather than as "you are already
    /// there".
    static func leg(km: Double?, minutes minutesValue: Double?) -> String? {
        let roundsToNothing = (km ?? 0) < 0.05 && (minutesValue ?? 0) < 0.5
        if roundsToNothing { return nil }
        // `Self.` on both: the parameter names shadow the two functions.
        let parts = [Self.km(km), Self.minutes(minutesValue)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1 Stopp" / "2 Stopps". Spelled out rather than using automatic
    /// grammatical agreement: `inflect:` agrees against a localisation
    /// catalogue for the language in question, and this app ships German
    /// strings without one — so it silently rendered the singular for every
    /// count.
    static func stops(_ count: Int) -> String {
        count == 1 ? "1 Stopp" : "\(count) Stopps"
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month().year().locale(atLocale))
    }
}

extension Precision {
    /// What the driver is told about an approximate pin. A `nil` precision — an
    /// exact match or a hand-placed pin — says nothing at all.
    var label: String {
        switch self {
        case .exact: "Genau"
        case .street: "Nur Straße — Hausnummer nicht gefunden"
        case .district: "Nur Bezirk — Adresse nicht gefunden"
        }
    }

    /// The two-word form, for a list row and the import report. Joined with a
    /// non-breaking space: it is two tokens that mean nothing apart, and in the
    /// stop row's wrapping strip an ordinary space let "≈" end one line and
    /// "Bezirk" start the next.
    var shortLabel: String {
        switch self {
        case .exact: "genau"
        case .street: "≈\u{00A0}Straße"
        case .district: "≈\u{00A0}Bezirk"
        }
    }

    var symbol: String {
        switch self {
        case .exact: "checkmark.circle"
        case .street, .district: "exclamationmark.triangle.fill"
        }
    }
}
