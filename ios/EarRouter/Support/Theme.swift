import SwiftUI
import UIKit

extension Color {
    /// ASBÖ red, sampled from the organisation's own logo (#ED1639).
    ///
    /// Dynamic rather than a fixed value: the full-strength brand red is a
    /// saturated mid-tone that reads correctly on white, but on a black
    /// background a colour that saturated at that luminance visibly vibrates
    /// against the surface and drops below a comfortable contrast ratio for
    /// small text. Dark mode gets a lighter, slightly desaturated variant —
    /// which is exactly what Apple does with its own system red (#FF3B30 →
    /// #FF453A) and what "keeping the brand colour" actually means on a
    /// display that inverts.
    static let brand = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.35, blue: 0.44, alpha: 1)   // #FF5A70
            : UIColor(red: 0.929, green: 0.086, blue: 0.224, alpha: 1) // #ED1639
    })

    /// Text and glyphs drawn *on top of* a `brand`-filled surface — the stop
    /// number in its circle, the count in a multi-item Paket badge.
    ///
    /// Not simply white. The dark-mode brand above is a light, high-luminance
    /// pink, and white on it measures about 3:1 — below what small text needs.
    /// So the label flips to near-black there, which is what makes a 13pt bold
    /// digit on a coloured circle actually readable in the dark.
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

    /// Text on a `warning`-tinted surface. The fill colour itself is
    /// unreadable as text against its own 15% background — this is the darker
    /// amber that actually carries contrast, and its lighter counterpart for
    /// dark mode.
    static let warningText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.75, blue: 0.35, alpha: 1)   // #FFBF59
            : UIColor(red: 0.478, green: 0.294, blue: 0.0, alpha: 1) // #7A4B00
    })

    /// Drawn under the route line on the map, a few points wider than it.
    ///
    /// A 5pt red line alone disappears into a red motorway shield or a brown
    /// contour on the standard map, and into anything at all on satellite. The
    /// casing is what Apple's own route lines have: it does not colour the
    /// route, it gives the route an edge, so the line reads as one continuous
    /// thing over whatever it happens to cross.
    static let routeCasing = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.0, alpha: 0.55)
            : UIColor(white: 1.0, alpha: 0.9)
    })

    /// The floor badge's fill. Blue is the one tint left that carries no
    /// meaning in this app yet — red is the delivery itself, amber is a warning
    /// or a note, green is done — so a floor reads as a fact rather than as
    /// something that needs acting on.
    static let floor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1) // #0A84FF
            : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1)   // #007AFF
    })

    /// Text on a `floor`-tinted surface, for the same reason `warningText`
    /// exists: the fill at 16% is a background, not a colour to set 12pt
    /// semibold type in.
    static let floorText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.71, blue: 1.0, alpha: 1)   // #6BB5FF
            : UIColor(red: 0.0, green: 0.32, blue: 0.68, alpha: 1)   // #0052AD
    })

    /// An approximate pin — "double check this one before you set off".
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1) // #FF9F0A
            : UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1)   // #FF9500
    })
}

extension View {
    /// The label of a filled brand-red button.
    ///
    /// `.borderedProminent` chooses its own label colour, and against the
    /// dark-mode brand — a light, high-luminance pink — it chooses white, which
    /// measures about 3:1. That is below what any text needs, and these buttons
    /// are the app's primary action every single time one appears: "Navigation",
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

    var shortLabel: String {
        switch self {
        case .exact: "genau"
        case .street: "≈ Straße"
        case .district: "≈ Bezirk"
        }
    }

    var symbol: String {
        switch self {
        case .exact: "checkmark.circle"
        case .street, .district: "exclamationmark.triangle.fill"
        }
    }
}
