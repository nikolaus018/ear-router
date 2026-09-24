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

    /// "1 Globale Info" / "3 Globale Infos" — entries in the list of what is
    /// kept about customers across tours. Not "Stockwerke": an entry may hold
    /// only a note.
    static func globaleInfos(_ count: Int) -> String {
        count == 1 ? "1 Globale Info" : "\(count) Globale Infos"
    }

    /// "Floridsdorfer Hauptstraße 1, 1210" with the house number held to its
    /// street, and the postcode to the number, by no-break spaces.
    ///
    /// For the screen only. In a row narrowed by its two trailing controls,
    /// the ordinary spaces let the line end right before the number, and the
    /// driver read "Floridsdorfer Hauptstraße" over a stray "1, 1210". Held
    /// together, the line breaks inside the street name instead —
    /// "Floridsdorfer / Hauptstraße 1, 1210" — which is the break a person
    /// would make. The shared report and Siri keep the plain text.
    static func address(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // The postcode to whatever comes before it — "1," then "1210".
        if words.count >= 2, words[words.count - 2].hasSuffix(","),
           words[words.count - 1].allSatisfy(\.isNumber)
        {
            let plz = words.removeLast()
            words[words.count - 1] += "\u{00A0}" + plz
        }
        // The first house number to the word before it.
        if let i = words.indices.first(where: { $0 > 0 && words[$0].first?.isNumber == true }) {
            words[i - 1] += "\u{00A0}" + words[i]
            words.remove(at: i)
        }
        return words.joined(separator: " ")
    }

    /// A "·"-separated line whose pieces each stay in one piece: "1 von 8
    /// geliefert · 1 nicht angetroffen" may wrap at a separator, never inside
    /// "nicht angetroffen". The Touren row broke exactly there, leaving
    /// "angetroffen" to start the next line on its own.
    static func strip(_ line: String) -> String {
        line.components(separatedBy: " · ").map(unbroken).joined(separator: " · ")
    }

    /// The same text with its spaces made no-break, for one short phrase that
    /// must not be split across two lines.
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// "24.09.2026" — the form a tour's default name carries its day in (see
    /// `RouteStore.defaultRouteName`), so a screen can tell when the name
    /// already says which day it was.
    static func numericDate(_ date: Date) -> String {
        numericDateFormatter.string(from: date)
    }

    private static let numericDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_AT")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

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
    /// out themselves — "2/Tür 14", "Mezzanin" — is left exactly as they
    /// wrote it.
    ///
    /// "EG" and "DG" are left alone as well, and deliberately: they are the two
    /// quick picks that are not numbers, they are what is written on the
    /// doorbell panel, and "EG. Stock" is not a thing anybody says. VoiceOver
    /// gets the spelled-out form from `StockwerkForm.spokenFloor`; this is the
    /// line a driver reads at a glance, where the short form is the point.
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
