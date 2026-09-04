import Foundation

/// Address string handling, ported from the `text` module of the Rust
/// backend. Every geocoding decision in the app runs through these: which
/// query gets sent to the register, whether the answer that came back is
/// really the address that was asked for, and whether two spellings of an
/// address are the same door.
///
/// `NSRegularExpression` supports lookahead, which the Rust `regex` crate
/// does not — so the abbreviation rule is written back in its natural
/// lookahead form rather than the capture-and-reinsert workaround the Rust
/// version needed.
enum AddressText {

    // MARK: - Regexes

    private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)
    /// "Hauptstr. 5" / "Hauptstr." / "Hauptstr.5" → "Hauptstraße …". The
    /// lookahead is what keeps it from firing inside a word.
    private static let strAbbr = try! NSRegularExpression(
        pattern: #"str\.(?=\s|$|\d)"#, options: [.caseInsensitive])
    private static let strasse = try! NSRegularExpression(
        pattern: #"strasse\b"#, options: [.caseInsensitive])

    /// Viennese addresses are routinely written as
    /// "{street} {housenumber or range}/{Stiege}/{Tür or Stock}[...]" —
    /// e.g. "Gentzgasse 129/1/2/23" or "Dr.-Heinrich-Maier-Straße 28-34/Haus 2/12".
    /// Neither geocoder indexes that per-apartment detail, so sending it
    /// through verbatim just fails to match.
    ///
    /// The housenumber/range itself ("28-34") is kept whole rather than
    /// collapsed to its first number: Vienna's own register indexes a
    /// combined range as its *own* address, distinct from the standalone
    /// numbers inside it ("Gutzkowplatz 2-5" is a separate entry from
    /// "Gutzkowplatz 2"), so dropping the range could silently match the
    /// wrong building instead of just failing to match.
    private static let housenumber = try! NSRegularExpression(
        pattern: #"^(.+?)\s+(\d+[a-zA-Z]?(?:-\d+[a-zA-Z]?)?)(?:[/\s(].*)?$"#)

    /// Same shape as `housenumber`, but requires (and captures) whatever
    /// follows the number — the sub-address. Separated by a slash OR by
    /// whitespace, because both spellings turn up in real lists
    /// ("9/Parz.68" and "9 Parz. 68"); anything past the first slash is
    /// ignored, so "129/1/2/23" yields sub = "1".
    private static let subAddress = try! NSRegularExpression(
        pattern: #"^(.+?)\s+(\d+[a-zA-Z]?(?:-\d+[a-zA-Z]?)?)(?:/|\s+)([^/]+)"#)

    /// The tail after "{street} {housenumber}" in an address string the
    /// register itself produced — used to read back which sub-address it
    /// actually matched.
    private static let housenumberTail = try! NSRegularExpression(
        pattern: #"^.+?\s+\d+[a-zA-Z]?(?:-\d+[a-zA-Z]?)?(.*)$"#)

    // MARK: - Normalization

    /// Collapses whitespace and unifies the three ways Viennese streets get
    /// spelled ("str.", "strasse", "straße").
    static func normalize(_ strasse: String) -> String {
        var s = replacing(whitespace, in: strasse.trimmed, with: " ")
        s = replacing(strAbbr, in: s, with: "straße")
        return replacing(Self.strasse, in: s, with: "straße")
    }

    /// Best-effort "{street} {housenumber}" simplification for geocoding —
    /// returns the input unchanged if it doesn't look like "street + number"
    /// at all (e.g. a place name with no housenumber).
    static func simplifyHousenumber(_ strasse: String) -> String {
        guard let m = firstMatch(housenumber, in: strasse),
              let street = m.group(1, in: strasse),
              let num = m.group(2, in: strasse)
        else { return strasse }
        return "\(street) \(num)"
    }

    /// Just the street-name portion, no housenumber — used to cross-check
    /// that a geocoder result landed on the street we asked for rather than
    /// a fuzzy string-similarity match onto a different street entirely.
    static func streetNameOnly(_ strasse: String) -> String {
        guard let m = firstMatch(housenumber, in: strasse),
              let street = m.group(1, in: strasse)
        else { return strasse.trimmed }
        return street.trimmed
    }

    /// The address's *sub-address* — what comes after the housenumber: a
    /// Stiege ("129/1"), a Kleingarten-Parzelle ("9/Parz.68"), a Top.
    /// Returns the query form to ask the register with, plus a normalized
    /// key for verifying what came back.
    ///
    /// Vienna's register indexes these as addresses in their own right, at
    /// their own front door: "Gentzgasse 129/1" and "129/2" are ~30 m apart
    /// on one Gemeindebau block, and "Großfeldstraße 9 Parz. 68" is ~130 m
    /// from the "Großfeldstraße 9" the colony as a whole answers to — asking
    /// for the bare housenumber there returns an arbitrary neighbouring plot,
    /// so the bare form is actively misleading.
    ///
    /// Only the first segment after the housenumber is kept: what follows is
    /// Tür/Stock ("129/1/2/23"), which no register indexes and which only
    /// makes the query fail to match.
    static func housenumberWithSub(_ strasse: String) -> (query: String, key: String)? {
        guard let m = firstMatch(subAddress, in: strasse),
              let street = m.group(1, in: strasse),
              let num = m.group(2, in: strasse),
              let sub = m.group(3, in: strasse)?.trimmed
        else { return nil }

        let key = subAddressKey(sub)
        // "Hauptstraße 12 " or "Gentzgasse 129/" carry no sub-address, and a
        // key with nothing alphanumeric in it can never verify anything.
        guard !key.isEmpty else { return nil }

        // Slash-joined regardless of how the driver wrote it: that is the
        // form the register accepts for both a Stiege ("129/1") and a
        // Parzelle ("9/Parz. 68"), whereas a space-joined query drops back
        // to matching the housenumber alone.
        return ("\(street) \(num)/\(sub)", key)
    }

    /// The form two addresses are compared in when deciding whether they are
    /// the *same address* — used to match a re-pasted list against the stops
    /// already on a route, where getting it wrong means deleting and
    /// re-inserting a stop, and losing the tick saying it was delivered.
    ///
    /// On top of the "straße" spellings `normalize` handles, this collapses
    /// every run of punctuation and whitespace to one space, so the same door
    /// survives being re-exported by a different system: "Großfeldstraße
    /// 9/Parz.68", "…9 Parz. 68" and "…9 / Parz. 68" are one address.
    /// Collapsed rather than deleted, because deleting separators would make
    /// "Gentzgasse 129/1" and "Gentzgasse 12/91" collide.
    static func matchKey(_ strasse: String) -> String {
        let normalized = normalize(strasse).lowercased()
        var out = ""
        out.reserveCapacity(normalized.count)
        var pendingSpace = false
        for c in normalized {
            if c.isLetter || c.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(c)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Compares sub-addresses the way a human would, ignoring the many ways
    /// the same one gets written: the driver types "9/Parz.68", the register
    /// answers "Großfeldstraße 9 Parz. 68", and a Stiege comes back as "/1".
    /// Everything that isn't a letter or a digit is noise here, and so is case.
    static func subAddressKey(_ sub: String) -> String {
        sub.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    /// The sub-address of an address string as the *register* spells it —
    /// everything after "{street} {housenumber}", normalized by
    /// `subAddressKey`. `nil` when the register answered with a bare
    /// housenumber and no sub-address at all.
    static func subAddressOf(_ adresse: String) -> String? {
        guard let m = firstMatch(housenumberTail, in: adresse),
              let tail = m.group(1, in: adresse)?.trimmed
        else { return nil }
        let key = subAddressKey(tail)
        return key.isEmpty ? nil : key
    }

    // MARK: - Regex plumbing

    private static func firstMatch(
        _ re: NSRegularExpression, in s: String
    ) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func replacing(
        _ re: NSRegularExpression, in s: String, with template: String
    ) -> String {
        re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

extension NSTextCheckingResult {
    /// The capture group as a `String`, or `nil` when the group did not
    /// participate in the match (`NSNotFound` range).
    func group(_ i: Int, in s: String) -> String? {
        guard i < numberOfRanges, let r = Range(range(at: i), in: s) else { return nil }
        return String(s[r])
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
