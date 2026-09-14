import SwiftUI

/// The palette, and the rule behind it: **there are no colours in this app that
/// iOS does not already ship.**
///
/// The previous palette was ten hand-mixed values — a bespoke indigo and its
/// dark-mode counterpart, two label colours to put on top of them, two washes
/// for card backgrounds, a graphite for fixed points, a grey for floor badges
/// and a second grey to set type in, an amber fill and a darker amber for text
/// on it. Every one of them had a paragraph of contrast arithmetic justifying
/// it, and all of that arithmetic was work Apple has already done: the system
/// colours are the ones that shift correctly between light and dark, under
/// Increase Contrast, under Reduce Transparency, and against every material.
///
/// So the whole palette is now four semantic names over system colours, and the
/// names say what the colour *means* rather than what it looks like:
///
/// | | |
/// |---|---|
/// | `Color.accentColor` | Anything you can touch, plus the route itself |
/// | `.delivered` | The meal is handed over |
/// | `.attention` | Look at this before you drive off |
/// | `.fixture` | Depot, warehouse, finish — the scaffolding of a tour |
///
/// Red is not in that table on purpose. It belongs to destruction and to
/// nothing else, so it is never the colour of an ordinary undelivered stop.
/// And the three that are in it — blue, green, orange — sit far enough apart on
/// the blue–yellow axis that every common colour vision deficiency leaves them
/// separable, which the old red-against-green pairing did not.
extension Color {
    /// Delivered. System green, so a tick in this app looks like a tick
    /// everywhere else on the phone.
    static var delivered: Color { .green }

    /// An approximate pin, a route that no longer matches its stops, a build
    /// about to expire — "check this before you set off". System orange.
    static var attention: Color { .orange }

    /// Drawn under the route line on the map, a few points wider than it.
    ///
    /// Not really a colour: it is an *outline*. A 5pt line alone disappears
    /// into a motorway shield or a contour on the standard map, and into
    /// anything at all on satellite, so Apple's own route lines are drawn over
    /// a casing that gives the line an edge without colouring it. The system
    /// background is white on light and black on dark, which is exactly the
    /// pair a casing wants.
    static var routeCasing: Color { Color(.systemBackground).opacity(0.85) }

    /// The fixed points of a tour rather than the deliveries on it. Grey,
    /// because these are the three addresses the driver already knows; a list
    /// is only skimmable if the things that change state are the only things
    /// wearing a colour.
    static var fixture: Color { .secondary }
}

enum Format {
    /// Built once. Every one of these is called from a list row — several times
    /// per row, once more for its accessibility label — and `Locale(identifier:)`
    /// is not free enough to pay for on each of them.
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

    /// "07:12" — the 24-hour clock, always, whatever the phone is set to.
    ///
    /// An arrival time is read at a glance from a holder on the dashboard, and
    /// "12:40" is one token where "12:40 PM" is two. Austria writes the time
    /// this way; a driver whose phone happens to be set to a 12-hour locale is
    /// still driving in Vienna.
    ///
    /// A fixed pattern on `en_US_POSIX` rather than a locale that formats this
    /// way by convention: a locale's clock follows the phone's own 24-hour
    /// setting, which is a switch in Settings and therefore not a guarantee.
    /// This is the one way to actually promise "HH:mm".
    static func time(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "3" is a floor and reads better said out; anything the driver spelled
    /// out themselves — "2/Tür 14", "Dachgeschoss" — is left exactly as they
    /// wrote it.
    static func floor(_ text: String) -> String {
        let t = text.trimmed
        return t.allSatisfy(\.isNumber) && !t.isEmpty ? "\(t). Stock" : t
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
    /// non-breaking space: it is two tokens that mean nothing apart, and in a
    /// wrapping strip an ordinary space let "≈" end one line and "Bezirk" start
    /// the next.
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
