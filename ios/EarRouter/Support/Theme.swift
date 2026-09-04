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

    /// An approximate pin — "double check this one before you set off".
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1) // #FF9F0A
            : UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1)   // #FF9500
    })
}

enum Format {
    /// "12,4 km" — Austrian decimal comma, one place, which is as precise as a
    /// routed distance is meaningfully accurate.
    static func km(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return value.formatted(
            .number.precision(.fractionLength(1)).locale(Locale(identifier: "de_AT"))) + " km"
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
    static func leg(km: Double?, minutes minutesValue: Double?) -> String? {
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
        date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "de_AT")))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(
            .dateTime.day().month().year().hour().minute()
                .locale(Locale(identifier: "de_AT")))
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
