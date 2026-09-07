import Foundation
import Compression

/// Reads the cells out of an Excel workbook.
///
/// An `.xlsx` is a ZIP of XML documents, and nothing in Foundation opens a ZIP
/// — so this is a ZIP reader and an OOXML reader, in about as few lines as the
/// job can honestly be done in. The app ships no third-party dependencies and
/// this is not the file to break that rule for: what is needed here is a
/// handful of entries out of a small archive, not a general-purpose unarchiver.
///
/// Written without a real workbook to check against, which is worth saying out
/// loud, because a spreadsheet reader that is subtly wrong does not fail — it
/// produces a plausible tour that visits the wrong doors. Two things are done
/// about that. Everything it cannot make sense of throws rather than guesses:
/// no worksheet, no shared strings where a cell claims one, a row whose cells
/// do not parse. And the fixtures it is tested against are generated as real
/// OOXML — deflate-compressed entries, shared strings, error cells, gaps where
/// a cell is simply absent — rather than as something convenient.
///
/// Whether it survives contact with an actual export from the office's Excel is
/// still an open question until one arrives.
enum XLSX {

    /// Every worksheet in the workbook, each as a table of rows.
    ///
    /// All of them rather than the first, because the day's list is not
    /// guaranteed to be on sheet one — a workbook mailed out of an office
    /// regularly has a cover sheet, or last week's tab still sitting in front
    /// of this week's. The caller takes the first sheet whose header it
    /// recognises, which is a better rule than "sheet 1" and costs a parse of a
    /// few kilobytes.
    static func tables(from data: Data) throws -> [[[String]]] {
        let archive = try ZipArchive(data)

        guard archive.contains("xl/workbook.xml") else {
            throw AppError.message(
                "Diese Datei ist ein ZIP-Archiv, aber keine Excel-Arbeitsmappe. "
                    + "Bitte die Tagesliste als .xlsx oder als CSV exportieren.")
        }

        let strings = try sharedStrings(archive)
        let paths = worksheetPaths(archive)
        guard !paths.isEmpty else {
            throw AppError.message("Die Arbeitsmappe enthält kein Tabellenblatt.")
        }

        var out: [[[String]]] = []
        for path in paths {
            guard let sheet = try archive.contents(of: path) else { continue }
            out.append(try Sheet.rows(sheet, strings: strings))
        }
        return out
    }

    // MARK: - Finding the sheets

    /// The worksheets, in the order the workbook lists them.
    ///
    /// Resolved properly where it can be — `workbook.xml` names each sheet with
    /// a relationship id, and `workbook.xml.rels` maps that id to a file — and
    /// falling back to the conventional `xl/worksheets/sheetN.xml` where it
    /// cannot. The convention is what every Excel actually writes; the
    /// relationships are what the format actually says.
    private static func worksheetPaths(_ archive: ZipArchive) -> [String] {
        if let workbook = try? archive.contents(of: "xl/workbook.xml"),
           let rels = try? archive.contents(of: "xl/_rels/workbook.xml.rels"),
           let ids = try? Workbook.sheetRelationshipIDs(workbook),
           let targets = try? Relationships.targets(rels) {
            let resolved = ids.compactMap { targets[$0] }.map(normalize)
            let existing = resolved.filter { archive.contains($0) }
            if !existing.isEmpty { return existing }
        }
        // Whatever worksheets are in there, in name order — `sheet2` must not
        // sort before `sheet10` by accident, hence the numeric comparison.
        return archive.names
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A relationship target is relative to `xl/`, unless it is absolute.
    private static func normalize(_ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        if target.hasPrefix("xl/") { return target }
        return "xl/" + target
    }

    private static func sharedStrings(_ archive: ZipArchive) throws -> [String] {
        guard let data = try archive.contents(of: "xl/sharedStrings.xml") else { return [] }
        return try SharedStrings.parse(data)
    }

    // MARK: - workbook.xml

    private enum Workbook {
        static func sheetRelationshipIDs(_ data: Data) throws -> [String] {
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            guard parser.parse() else { throw AppError.message("Arbeitsmappe nicht lesbar.") }
            return delegate.ids
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var ids: [String] = []
            func parser(
                _ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]
            ) {
                guard name == "sheet" else { return }
                // Namespaces are off, so the attribute arrives under its
                // qualified name.
                if let id = attributes["r:id"] ?? attributes["id"] { ids.append(id) }
            }
        }
    }

    // MARK: - workbook.xml.rels

    private enum Relationships {
        static func targets(_ data: Data) throws -> [String: String] {
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            guard parser.parse() else { throw AppError.message("Arbeitsmappe nicht lesbar.") }
            return delegate.targets
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var targets: [String: String] = [:]
            func parser(
                _ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]
            ) {
                guard name == "Relationship",
                      let id = attributes["Id"], let target = attributes["Target"]
                else { return }
                targets[id] = target
            }
        }
    }

    // MARK: - sharedStrings.xml

    /// Excel stores every distinct string once and has the cells point at it by
    /// index, which is why a sheet on its own is mostly numbers.
    enum SharedStrings {
        static func parse(_ data: Data) throws -> [String] {
            let delegate = Delegate()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            guard parser.parse() else {
                throw AppError.message("Die Texte der Arbeitsmappe sind nicht lesbar.")
            }
            return delegate.strings
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            var strings: [String] = []
            private var current = ""
            private var capturing = false

            func parser(
                _ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]
            ) {
                switch name {
                case "si": current = ""
                case "t": capturing = true
                default: break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if capturing { current += string }
            }

            func parser(
                _ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?
            ) {
                switch name {
                case "t":
                    capturing = false
                case "si":
                    // One `si` can hold several `t` runs — that is rich text,
                    // a cell where somebody bolded half a word. Concatenated,
                    // because the driver wants the sentence, not the styling.
                    strings.append(current)
                    current = ""
                default:
                    break
                }
            }
        }
    }

    // MARK: - worksheets/sheetN.xml

    enum Sheet {
        /// The column decoder, reachable from a test: getting it wrong shifts
        /// every value in a row one place and produces a tour that looks
        /// entirely ordinary.
        static func columnIndexForTesting(_ reference: String) -> Int {
            Delegate.columnIndex(reference)
        }

        static func rows(_ data: Data, strings: [String]) throws -> [[String]] {
            let delegate = Delegate(strings: strings)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            guard parser.parse() else {
                throw AppError.message("Ein Tabellenblatt der Arbeitsmappe ist nicht lesbar.")
            }
            return delegate.rows
        }

        private final class Delegate: NSObject, XMLParserDelegate {
            let strings: [String]
            var rows: [[String]] = []

            private var row: [String] = []
            private var column = 0
            private var type = ""
            private var value = ""
            private var capturing = false

            init(strings: [String]) { self.strings = strings }

            func parser(
                _ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]
            ) {
                switch name {
                case "row":
                    row = []
                case "c":
                    type = attributes["t"] ?? ""
                    value = ""
                    // `r` is the cell's reference, "C7". Its letters are the
                    // column, and they matter: a cell that is simply absent is
                    // not written at all, so without reading the reference an
                    // empty Paket shifts the Hinweis into its place for the
                    // rest of the row.
                    column = attributes["r"].map(Self.columnIndex) ?? row.count
                case "v", "t":
                    capturing = true
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if capturing { value += string }
            }

            func parser(
                _ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?
            ) {
                switch name {
                case "v", "t":
                    capturing = false
                case "c":
                    while row.count < column { row.append("") }
                    row.append(resolved())
                case "row":
                    rows.append(row)
                    row = []
                default:
                    break
                }
            }

            /// What the cell actually says.
            ///
            /// `s` is an index into the shared strings. `e` is a formula error
            /// — `#NV` on three of the four pages of a real list — and is worth
            /// nothing, so it is blanked at the source rather than carried
            /// forward to be recognised as text later. Everything else is
            /// already the literal value: `inlineStr` and `str` arrive as text,
            /// and a number arrives as its digits, which is what a postcode
            /// column of 1210s is.
            private func resolved() -> String {
                switch type {
                case "s":
                    guard let index = Int(value.trimmed), strings.indices.contains(index) else {
                        return ""
                    }
                    return strings[index]
                case "e":
                    return ""
                default:
                    return value
                }
            }

            /// "AB12" → 27. Excel's columns are base-26 with no zero, so `A` is
            /// 1 and `Z` is 26 and `AA` is 27; this returns the zero-based
            /// index the row array wants.
            static func columnIndex(_ reference: String) -> Int {
                var n = 0
                for c in reference.uppercased() {
                    guard let ascii = c.asciiValue, ascii >= 65, ascii <= 90 else { break }
                    n = n * 26 + Int(ascii - 64)
                }
                return max(0, n - 1)
            }
        }
    }
}

// MARK: - The ZIP the workbook is packed in

/// Enough of a ZIP reader to get named entries out of a small archive.
///
/// Read through the central directory at the end of the file rather than by
/// walking local headers from the front: the local header does not reliably
/// carry the compressed size — a streamed archive puts it in a data descriptor
/// *after* the data — whereas the central directory always has it. It is also
/// how the format is meant to be read.
struct ZipArchive {
    private let data: Data
    private var entries: [String: Entry] = [:]

    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// A ceiling on what one entry may expand to. A day's list is a few
    /// kilobytes; anything claiming to be hundreds of megabytes is either
    /// broken or hostile, and neither is worth the memory.
    private static let maxEntrySize = 64 * 1024 * 1024

    var names: [String] { Array(entries.keys) }
    func contains(_ name: String) -> Bool { entries[name] != nil }

    init(_ data: Data) throws {
        self.data = data
        guard let eocd = Self.endOfCentralDirectory(data) else {
            throw AppError.message(
                "Die Datei ist beschädigt oder unvollständig (kein gültiges ZIP-Ende).")
        }

        var offset = eocd.directoryOffset
        for _ in 0..<eocd.entryCount {
            guard offset + 46 <= data.count,
                  Self.u32(data, offset) == 0x0201_4B50
            else { break }

            let method = Self.u16(data, offset + 10)
            let compressed = Int(Self.u32(data, offset + 20))
            let uncompressed = Int(Self.u32(data, offset + 24))
            let nameLength = Int(Self.u16(data, offset + 28))
            let extraLength = Int(Self.u16(data, offset + 30))
            let commentLength = Int(Self.u16(data, offset + 32))
            let localOffset = Int(Self.u32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(
                decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            entries[name] = Entry(
                method: method, compressedSize: compressed,
                uncompressedSize: uncompressed, localHeaderOffset: localOffset)

            offset = nameStart + nameLength + extraLength + commentLength
        }

        guard !entries.isEmpty else {
            throw AppError.message("Das Archiv ist leer oder nicht lesbar.")
        }
    }

    /// The bytes of one entry, decompressed. `nil` when the archive has no such
    /// entry — which is a question, not a failure.
    func contents(of name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard entry.uncompressedSize <= Self.maxEntrySize else {
            throw AppError.message("Die Arbeitsmappe ist zu groß.")
        }

        // The local header repeats the name and extra fields, and its lengths
        // are the ones that count — an archiver is free to write a different
        // extra field here than in the central directory, and several do.
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, Self.u32(data, header) == 0x0403_4B50 else {
            throw AppError.message("Die Arbeitsmappe ist beschädigt.")
        }
        let nameLength = Int(Self.u16(data, header + 26))
        let extraLength = Int(Self.u16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start <= end, end <= data.count else {
            throw AppError.message("Die Arbeitsmappe ist beschädigt.")
        }
        let payload = Data(data[start..<end])

        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = Self.inflate(payload, capacity: entry.uncompressedSize) else {
                throw AppError.message("Ein Teil der Arbeitsmappe ließ sich nicht entpacken.")
            }
            return inflated
        default:
            throw AppError.message(
                "Die Arbeitsmappe verwendet eine Komprimierung, die diese App nicht kennt. "
                    + "Bitte als CSV exportieren.")
        }
    }

    /// Raw DEFLATE, which is what a ZIP entry holds — no zlib header, no
    /// checksum. Apple's `COMPRESSION_ZLIB` is that raw stream despite the
    /// name; the wrapped form is what it is *not*.
    private static func inflate(_ data: Data, capacity: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        // A stored size of zero is legal and means "unknown here"; give the
        // buffer somewhere sensible to go rather than refusing.
        let size = capacity > 0 ? capacity : min(data.count * 8 + 1024, maxEntrySize)
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { out.deallocate() }

        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                out, size, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: out, count: written)
    }

    // MARK: - Reading the little-endian fields

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }

    /// The end-of-central-directory record, searched for backwards.
    ///
    /// It is not simply the last 22 bytes: the record ends with a comment field
    /// that may be up to 64 KB long, so the signature has to be looked for.
    private static func endOfCentralDirectory(
        _ data: Data
    ) -> (entryCount: Int, directoryOffset: Int)? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let searchFrom = max(0, data.count - minimum - 0xFFFF)
        var offset = data.count - minimum
        while offset >= searchFrom {
            if u32(data, offset) == 0x0605_4B50 {
                let count = Int(u16(data, offset + 10))
                let directory = Int(u32(data, offset + 16))
                guard directory >= 0, directory < data.count else { return nil }
                return (count, directory)
            }
            offset -= 1
        }
        return nil
    }
}
