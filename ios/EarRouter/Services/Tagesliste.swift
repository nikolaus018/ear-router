import Foundation

/// The office's own daily list, as a file.
///
/// The list arrives as a table with these columns:
///
///     Tour | Stopp | Referenzbeleg | Datum | KDNr. | Parat | KD | Straße | Plz | Paket | Hinweis
///
/// Five of those are the tour: `KD`, `Straße`, `Plz`, `Paket`, `Hinweis`. The
/// rest belong to the office's own systems and are read past — but they are
/// matched by *name* rather than by position, so a column appearing, moving or
/// being renamed does not silently shift the address into the postcode.
///
/// Two shapes of file arrive here and leave as the same thing. A workbook goes
/// to `XLSX`, which unzips it and reads the cells; a text export is parsed
/// below. Everything after that — finding the header, mapping the columns,
/// cleaning what Excel put in the cells — is one path, because the difference
/// between the two formats ends at "here is a table of strings".
enum Tagesliste {

    // MARK: - Entry point

    /// Reads a day's list out of a file's bytes.
    ///
    /// `filename` is used only to say something useful when the bytes turn out
    /// not to be a list at all — the decision itself is made on content, because
    /// an extension is a claim and the bytes are the fact.
    static func parse(_ data: Data, filename: String = "") throws -> [CustomerJSON] {
        guard !data.isEmpty else {
            throw AppError.message("Die Datei ist leer.")
        }

        // The old binary `.xls` is refused outright and on purpose. It is a
        // compound-file document from 1997 with a wholly different structure to
        // everything below, it is not what a current Excel saves by default,
        // and adding a second binary reader on the chance the office still uses
        // it would be a lot of untested code for a file nobody has sent.
        if starts(data, with: [0xD0, 0xCF, 0x11, 0xE0]) {
            throw AppError.message(oldExcelHint(filename))
        }

        for table in try tables(data, filename: filename) {
            guard let header = headerRow(in: table) else { continue }
            let entries = rows(table, from: header.index, columns: header.columns)
            if !entries.isEmpty { return entries }
        }

        throw AppError.message(
            "In der Datei ist keine Kopfzeile mit „KD“ und „Straße“ mit Einträgen darunter "
                + "zu finden. Bitte prüfen, ob das die richtige Datei ist.")
    }

    /// The candidate tables in a file — a workbook's worksheets, or the single
    /// table a text export is.
    ///
    /// Several, because a workbook mailed out of an office regularly has a
    /// cover sheet or last week's tab in front of this week's, and "sheet one"
    /// is a worse rule than "the first sheet that looks like a tour".
    private static func tables(_ data: Data, filename: String) throws -> [[[String]]] {
        // Every ZIP starts this way, which is what an `.xlsx` is.
        if starts(data, with: [0x50, 0x4B, 0x03, 0x04]) {
            return try XLSX.tables(from: data)
        }
        guard let text = decode(data) else {
            throw AppError.message(
                "Die Datei lässt sich nicht als Text lesen. Bitte aus Excel über "
                    + "„Speichern unter“ als CSV oder .xlsx exportieren.")
        }
        return [bestTable(from: text)]
    }

    private static func starts(_ data: Data, with signature: [UInt8]) -> Bool {
        data.count >= signature.count && Array(data.prefix(signature.count)) == signature
    }

    private static func oldExcelHint(_ filename: String) -> String {
        let name = filename.isEmpty ? "Diese Datei" : "„\(filename)“"
        return "\(name) ist eine alte Excel-Datei (.xls). Bitte in Excel über "
            + "„Datei → Speichern unter“ als „Excel-Arbeitsmappe (.xlsx)“ oder als "
            + "„CSV UTF-8“ neu speichern."
    }

    // MARK: - Bytes to text

    /// The encodings a list can plausibly arrive in, in the order it is worth
    /// trying them.
    ///
    /// The byte-order marks first, because a BOM is not a guess. After that
    /// UTF-8, then Windows-1252: Excel's plain "CSV" on Windows is still written
    /// in the system code page, and read as UTF-8 that turns every ß, ä, ö and ü
    /// into a decoding failure — which is exactly the list this app is for.
    static func decode(_ data: Data) -> String? {
        let bytes = Array(data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(data: data, encoding: .utf16LittleEndian).map(strippingBOM)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(data: data, encoding: .utf16BigEndian).map(strippingBOM)
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let cp1252 = String(data: data, encoding: .windowsCP1252) { return cp1252 }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func strippingBOM(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    // MARK: - Text to a table

    /// The separators Excel writes, in the order they are worth believing.
    ///
    /// Semicolon first on purpose. An Austrian or German Excel writes CSV with
    /// semicolons, because the comma is already the decimal separator — so the
    /// most likely file this app will ever be handed is the one a comma-first
    /// reader gets wrong.
    private static let separators: [Character] = [";", "\t", ","]

    /// Parses the text once per candidate separator and keeps the reading that
    /// produces the widest consistent table.
    ///
    /// Sniffing by counting characters is the usual trick and it is wrong here:
    /// these lists carry free text written by dispatchers — "wenn Kd nicht
    /// anwesend, abgeben bei Sonja DOMBROWSKI (Tür 7, einen Stock höher)" has
    /// more commas in one cell than a semicolon-separated row has separators.
    /// Parsing properly and asking which reading actually yields a table cannot
    /// be fooled by that, and it costs one pass over a file of a few kilobytes.
    static func bestTable(from text: String) -> [[String]] {
        var best: [[String]] = []
        var bestWidth = 0
        for separator in separators {
            let table = parseDelimited(text, separator: separator)
            let width = modalWidth(table)
            if width > bestWidth {
                bestWidth = width
                best = table
            }
        }
        // Nothing separated anything: a single column is still a table, and the
        // header check downstream is what turns it into a real error message.
        return bestWidth > 1 ? best : parseDelimited(text, separator: ";")
    }

    /// The row width that occurs most often, which is the table's real shape —
    /// a title line above the header and a page footer below it are each one
    /// cell wide and must not get a vote.
    private static func modalWidth(_ table: [[String]]) -> Int {
        var counts: [Int: Int] = [:]
        for row in table where !(row.count == 1 && row[0].trimmed.isEmpty) {
            counts[row.count, default: 0] += 1
        }
        // Ties go to the wider table: a file that reads as 11 columns as often
        // as it reads as 2 is an 11-column file.
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?.key ?? 0
    }

    /// RFC 4180, plus the two things real files do that it does not mention:
    /// lone `\r` line endings, and a quoted field containing newlines — which is
    /// how every one of these lists carries a two-line Hinweis.
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        /// One character read ahead of its turn — the quote branch has to look
        /// at the next character to tell `""` (a literal quote) from `"` (the
        /// end of the field), and hands back whatever it found that was not a
        /// quote.
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while let c = pending ?? iterator.next() {
            pending = nil

            if quoted {
                if c == "\"" {
                    // A doubled quote is one literal quote; a single one closes
                    // the field.
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            pending = next
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }

            switch c {
            case "\"" where field.isEmpty:
                quoted = true
            case separator:
                endField()
            // All three line endings, and `\r\n` is listed first because in
            // Swift it is *one* `Character`: a CRLF is a single extended
            // grapheme cluster, so matching `\r` and then looking ahead for the
            // `\n` — which is how this is written in every other language —
            // matches neither half and treats a whole Windows file as one line.
            // Which is to say: as no file at all. Excel on Windows writes CRLF.
            case "\r\n", "\n", "\r":
                endRow()
            default:
                field.append(c)
            }
        }

        if !field.isEmpty || !row.isEmpty { endRow() }
        // A trailing newline leaves one empty row behind it.
        if let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
        return rows
    }

    // MARK: - Finding the columns

    /// Which of the file's columns is which of ours.
    struct Columns {
        var kunde: Int?
        var vorname: Int?
        var nachname: Int?
        var strasse: Int?
        var plz: Int?
        var paket: Int?
        var notiz: Int?

        /// Enough to build a stop from. A name alone is not a delivery and an
        /// address alone is not a customer.
        var isUsable: Bool { (kunde != nil || nachname != nil) && strasse != nil }
    }

    /// The header is found rather than assumed to be the first row: these lists
    /// are printed with the date above the table, and an exported one carries
    /// that line too.
    private static func headerRow(in table: [[String]]) -> (index: Int, columns: Columns)? {
        for (index, row) in table.enumerated() {
            let columns = map(header: row)
            if columns.isUsable { return (index, columns) }
        }
        return nil
    }

    /// Matches on the folded, punctuation-free form of the heading, so
    /// "Straße", "STRASSE" and "Strasse " are one column — and, importantly, so
    /// "KD" and "KDNr." are two. Anything not recognised is a column belonging
    /// to the office and is read past.
    static func map(header row: [String]) -> Columns {
        var columns = Columns()
        for (index, cell) in row.enumerated() {
            switch headerKey(cell) {
            case "kd", "kunde", "kundin", "name", "kundenname", "empfaenger", "klient":
                columns.kunde = columns.kunde ?? index
            case "vorname":
                columns.vorname = columns.vorname ?? index
            case "nachname", "zuname", "familienname":
                columns.nachname = columns.nachname ?? index
            case "strasse", "adresse", "anschrift", "strassehausnummer", "strassenr",
                 "strassehausnr":
                columns.strasse = columns.strasse ?? index
            case "plz", "postleitzahl", "bezirk", "plzort":
                columns.plz = columns.plz ?? index
            case "paket", "menue", "menu", "artikel", "lieferung", "bestellung", "ware":
                columns.paket = columns.paket ?? index
            case "hinweis", "notiz", "anmerkung", "bemerkung", "info", "kommentar":
                columns.notiz = columns.notiz ?? index
            default:
                continue
            }
        }
        return columns
    }

    /// Letters and digits only, umlauts folded — the same rule
    /// `AddressText.matchKey` uses on an address, minus the spaces, because a
    /// heading is one token rather than a sentence.
    static func headerKey(_ raw: String) -> String {
        AddressText.germanFold(raw.lowercased()).filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Rows to stops

    private static func rows(
        _ table: [[String]], from headerIndex: Int, columns: Columns
    ) -> [CustomerJSON] {
        var out: [CustomerJSON] = []
        for row in table.dropFirst(headerIndex + 1) {
            let strasse = clean(cell(row, columns.strasse))
            // The only row this refuses outright. A page break, a totals line, a
            // blank spacer row — none of them carry an address, and none of them
            // is a customer the driver should be shown as "nicht übernommen".
            guard !strasse.isEmpty else { continue }

            out.append(
                CustomerJSON(
                    kunde: name(row, columns),
                    strasse: strasse,
                    plz: postcode(clean(cell(row, columns.plz))),
                    paket: clean(cell(row, columns.paket)).nilIfEmpty,
                    notiz: clean(cell(row, columns.notiz)).nilIfEmpty))
        }
        return out
    }

    private static func cell(_ row: [String], _ index: Int?) -> String {
        guard let index, row.indices.contains(index) else { return "" }
        return row[index]
    }

    /// One name, however the file spells it: a single `KD` column, or a first
    /// and last name to be put back together.
    private static func name(_ row: [String], _ columns: Columns) -> String {
        let combined = clean(cell(row, columns.kunde))
        if !combined.isEmpty { return combined }
        let parts = [clean(cell(row, columns.vorname)), clean(cell(row, columns.nachname))]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The four digits of a Vienna postcode, out of whatever the cell holds —
    /// "1210", "1210 Wien", "A-1210". Anything else is passed through so the
    /// import reports it by name rather than silently blanking it.
    private static func postcode(_ raw: String) -> String {
        var run = ""
        for c in raw {
            if c.isNumber {
                run.append(c)
                if run.count == 4 { return run }
            } else {
                run = ""
            }
        }
        return raw
    }

    /// What a cell is worth once Excel is done with it.
    ///
    /// Formula errors are blanked. `#NV` — German for `#N/A` — is on three of
    /// the four pages of a real list, in the Hinweis column, because the sheet
    /// looks something up per customer and not every customer is found. Left
    /// alone it becomes a stop whose note reads "#NV", which is a driver
    /// standing at a door reading a spreadsheet error.
    ///
    /// All whitespace collapses to single spaces, newlines included. A Hinweis
    /// wraps over several lines in the cell it was typed into, and the two
    /// halves have to come back as words with a space between them rather than
    /// as "stellenwenn".
    static func clean(_ raw: String) -> String {
        let trimmed = raw.trimmed
        guard !isExcelError(trimmed) else { return "" }
        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Excel's error values, in both the German and the English versions —
    /// which of the two a file carries depends on the office's Excel, not on
    /// anything this app can see.
    static func isExcelError(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let known: Set<String> = [
            "#NV", "#N/A", "#WERT!", "#VALUE!", "#BEZUG!", "#REF!", "#NAME?",
            "#DIV/0!", "#DIV/0", "#NULL!", "#ZAHL!", "#NUM!", "#GESPERRT!",
            "#KALK!", "#CALC!", "#FELD!", "#SPILL!", "#ÜBERLAUF!", "#UNBEKANNT!",
        ]
        return known.contains(value.uppercased())
    }
}
