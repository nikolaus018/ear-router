import Foundation

/// Telephone numbers written into a stop's note — "bitte 1 Stunde vorher
/// anrufen: 0664 123 45 67" — so the app can offer to call them.
///
/// Found with the system's own data detector rather than a hand-written
/// pattern: Austrian numbers are written every way there is — "0664/1234567",
/// "+43 1 234 56 78", "01 234 5678", "0043 664 …" — and the detector already
/// knows all of them.
///
/// Two rules on top of the detector, because the detector is generous:
///
/// * **Seven digits at the least.** The notes are full of short numbers that
///   are not telephone numbers — a door code, "Tür 14", "Stiege 3", "2. Stock",
///   a four-digit postcode.
/// * **A leading 0, or a "+".** Every number that can be dialled from an
///   Austrian mobile starts with one or the other — "0664 …", "01 …",
///   "+43 …", "0043 …". A customer number or an order reference does not, and
///   on the phone the detector happily offered "KDNr 26064642" as a number to
///   call.
enum PhoneNumbers {
    struct Found: Hashable, Identifiable {
        /// As written in the note, so the button shows the number the driver
        /// can see in the note right above it.
        let display: String
        /// Digits only, with a leading "+" where the note had one — what `tel:`
        /// is given to dial.
        let dial: String

        var id: String { dial }
        var url: URL? { URL(string: "tel:\(dial)") }
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    static func find(in text: String?) -> [Found] {
        // Most notes carry no digits at all, and this is asked for every row
        // in a tour's list; the detector is not free enough to run on those.
        guard let text, text.contains(where: \.isNumber), let detector else { return [] }

        var out: [Found] = []
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let written = (match.phoneNumber ?? String(text[range])).trimmed
            let digits = written.filter(\.isNumber)
            guard (7...15).contains(digits.count),
                  written.hasPrefix("+") || digits.hasPrefix("0")
            else { continue }
            let found = Found(
                display: written,
                dial: (written.hasPrefix("+") ? "+" : "") + digits)
            // One button per number, however many times the note repeats it —
            // and however it is spelled each time. Compared on `sameNumberKey`
            // rather than on `dial`, because "0664 1234567" and
            // "+43 664 1234567" in one note are one number written twice.
            if !out.contains(where: { sameNumberKey($0.dial) == sameNumberKey(found.dial) }) {
                out.append(found)
            }
        }
        return out
    }

    /// The form two numbers are compared in when deciding whether they are the
    /// *same* number — as opposed to `dial`, which is what actually gets
    /// dialled and must stay exactly as written.
    ///
    /// Austrian numbers reach this app in three notations for one number: the
    /// Zusteller-Portal hands over `customer.phone` as "+4369910842229", and a
    /// driver's own note for the same household says "0699 10842229" or
    /// "0043 699 10842229". Compared as text those are three different numbers,
    /// which is how the customer's own "Anrufen" button and a note's
    /// "0699 10842229 anrufen" ended up side by side on Jetzt, dialling the
    /// same person.
    ///
    /// So the country code and the trunk zero — the two things that differ
    /// between the notations and not between the numbers — are taken off, and
    /// what is left is the national number. Nothing is stripped when that would
    /// leave nothing behind, so a fragment cannot collapse onto the empty
    /// string and swallow every other number with it.
    static func sameNumberKey(_ dial: String) -> String {
        var digits = dial.hasPrefix("+") ? String(dial.dropFirst()) : dial
        // "0043" only ever means the international prefix: an Austrian national
        // number has exactly one trunk zero, never two.
        if dial.hasPrefix("+"), digits.hasPrefix("43"), digits.count > 2 {
            digits.removeFirst(2)
        } else if digits.hasPrefix("0043"), digits.count > 4 {
            digits.removeFirst(4)
        }
        if digits.hasPrefix("0"), digits.count > 1 { digits.removeFirst() }
        return digits
    }

    /// The numbers in a note that deserve a button of their own: everything
    /// `find` turns up, minus the customer's own number.
    ///
    /// Here rather than at each call site because both screens that offer these
    /// buttons — the stop row's menu and the Jetzt card — have to subtract the
    /// same number, and two copies of that rule are two chances for one of them
    /// to keep offering the duplicate.
    static func inNote(_ notiz: String?, besides telefon: String?) -> [Found] {
        guard let own = telefon?.trimmed.nilIfEmpty
            .flatMap(normalizedDial).map(sameNumberKey)
        else { return find(in: notiz) }
        return find(in: notiz).filter { sameNumberKey($0.dial) != own }
    }

    /// Digits only, with a leading "+" kept where the source had one — the
    /// same normalization `find`'s `Found.dial` applies, but for a number that
    /// is already known to be a phone number (the customer's own `telefon`)
    /// rather than free text to run the data detector over.
    static func normalizedDial(_ raw: String) -> String? {
        let trimmed = raw.trimmed
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return (trimmed.hasPrefix("+") ? "+" : "") + digits
    }

    /// What `openURL` is given to dial a trusted number directly.
    static func dialURL(for raw: String) -> URL? {
        normalizedDial(raw).flatMap { URL(string: "tel:\($0)") }
    }
}
