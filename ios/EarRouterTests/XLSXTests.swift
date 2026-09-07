import Testing
import Foundation
@testable import EarRouter

/// Reading a `.xlsx`, which is a ZIP of XML documents.
///
/// This is the part of the import path that has never met a real file, so it is
/// tested against archives built as genuine OOXML — see `XLSXFixtures` — rather
/// than against something shaped to suit the reader.
struct XLSXTests {

    // MARK: - The ZIP underneath

    @Test func readsADeflateCompressedArchive() throws {
        let archive = try ZipArchive(XLSXFixtures.tour)
        #expect(archive.contains("xl/workbook.xml"))
        #expect(archive.contains("xl/sharedStrings.xml"))
        #expect(archive.contains("xl/worksheets/sheet1.xml"))

        let workbook = try #require(try archive.contents(of: "xl/workbook.xml"))
        let text = String(decoding: workbook, as: UTF8.self)
        #expect(text.contains("<sheets>"))
        #expect(text.contains("Tour"))
    }

    /// A ZIP entry may be stored rather than deflated, and small XML sometimes
    /// is.
    @Test func readsAnUncompressedArchive() throws {
        let archive = try ZipArchive(XLSXFixtures.tour_stored)
        let workbook = try #require(try archive.contents(of: "xl/workbook.xml"))
        #expect(String(decoding: workbook, as: UTF8.self).contains("<sheets>"))
    }

    @Test func anEntryThatIsNotThereIsAQuestionNotAFailure() throws {
        let archive = try ZipArchive(XLSXFixtures.tour)
        #expect(try archive.contents(of: "xl/nope.xml") == nil)
    }

    @Test func refusesSomethingThatIsNotAnArchive() {
        #expect(throws: AppError.self) { try ZipArchive(Data(repeating: 0x41, count: 512)) }
    }

    @Test func refusesATruncatedArchive() {
        let half = XLSXFixtures.tour.prefix(XLSXFixtures.tour.count / 2)
        #expect(throws: AppError.self) { try ZipArchive(Data(half)) }
    }

    // MARK: - Column references

    /// Excel's columns are base-26 with no zero.
    @Test func decodesColumnLetters() {
        #expect(XLSX.Sheet.columnIndexForTesting("A1") == 0)
        #expect(XLSX.Sheet.columnIndexForTesting("B7") == 1)
        #expect(XLSX.Sheet.columnIndexForTesting("Z1") == 25)
        #expect(XLSX.Sheet.columnIndexForTesting("AA1") == 26)
        #expect(XLSX.Sheet.columnIndexForTesting("AB12") == 27)
        #expect(XLSX.Sheet.columnIndexForTesting("BA1") == 52)
    }

    // MARK: - The sheet

    @Test func readsTheCellsOfAWorksheet() throws {
        let tables = try XLSX.tables(from: XLSXFixtures.tour)
        #expect(tables.count == 1)
        let rows = tables[0]

        #expect(rows.first?.first == "Tour")
        #expect(rows.first?.contains("Straße") == true)
        #expect(rows.first?.contains("Hinweis") == true)
        // Header plus five data rows.
        #expect(rows.count == 6)
    }

    /// Numbers arrive as numbers in the file, and a postcode column is a column
    /// of numbers.
    @Test func aNumericCellComesBackAsItsDigits() throws {
        let entries = try Tagesliste.parse(XLSXFixtures.tour, filename: "tour.xlsx")
        #expect(entries.allSatisfy { $0.plz == "1210" })
    }

    /// An empty cell is not written at all. Without reading each cell's `r`
    /// reference, the next value slides into its place and every column after
    /// it is wrong.
    @Test func anAbsentCellDoesNotShiftTheRestOfTheRow() throws {
        let entries = try Tagesliste.parse(XLSXFixtures.tour)
        let tenor = try #require(entries.first { $0.kunde == "Peter Tenor" })
        #expect(tenor.strasse == "Floridusgasse 51/10")
        #expect(tenor.plz == "1210")
        #expect(tenor.paket == "1x Vitalmenü EP TGM5")
        #expect(tenor.notiz == nil)
    }

    /// `#NV` is stored as a typed error cell, and is worth nothing.
    @Test func aFormulaErrorCellIsBlank() throws {
        let entries = try Tagesliste.parse(XLSXFixtures.tour)
        let pusch = try #require(entries.first { $0.kunde == "Edith Pusch" })
        #expect(pusch.notiz == nil)
        #expect(pusch.paket == "1x Vitalmenü EP TGMS7")
    }

    /// Strings normally live in a shared table and the cells point at them by
    /// index — but a workbook may inline them instead, and both have to read.
    @Test func readsInlineStringsAsWellAsSharedOnes() throws {
        let shared = try Tagesliste.parse(XLSXFixtures.tour)
        let inline = try Tagesliste.parse(XLSXFixtures.tour_inline)
        #expect(shared.map(\.kunde) == inline.map(\.kunde))
        #expect(shared.map(\.strasse) == inline.map(\.strasse))
    }

    /// A workbook out of an office has a cover sheet in front of the list as
    /// often as not, so the day's list is found rather than assumed to be sheet
    /// one.
    @Test func findsTheListOnASheetThatIsNotTheFirst() throws {
        let tables = try XLSX.tables(from: XLSXFixtures.tour_second_sheet)
        #expect(tables.count == 2)
        let entries = try Tagesliste.parse(XLSXFixtures.tour_second_sheet)
        #expect(entries.count == 5)
        #expect(entries[0].kunde == "Thomas Kaltenbacher")
    }

    // MARK: - The whole way through

    /// The same list, in both formats, has to come out the same — that is the
    /// promise of the two readers meeting at "a table of strings".
    @Test func aWorkbookAndACSVOfTheSameListAgree() throws {
        let fromWorkbook = try Tagesliste.parse(XLSXFixtures.tour, filename: "tour.xlsx")

        let csv = [
            "Tour;Stopp;Referenzbeleg;Datum;KDNr.;Parat;KD;Straße;Plz;Paket;Hinweis",
            "VM 5 FR Vormittag;1;S17207;04.09.2026;26064642;547179;Thomas Kaltenbacher;"
                + "Mühlschüttelgasse 55-57/6/5;1210;1x Vitalmenü EP DLM5 (LVK);lfd",
            "VM 5 FR Vormittag;2;S17305;04.09.2026;26063583;555502;Peter Tenor;"
                + "Floridusgasse 51/10;1210;1x Vitalmenü EP TGM5;",
            "VM 5 FR Vormittag;21;S15165;04.09.2026;26087300;0;Edith Pusch;"
                + "Edergasse 4/1;1210;1x Vitalmenü EP TGMS7;#NV",
            "VM 5 FR Vormittag;39;S17068;04.09.2026;26063126;552714;"
                + "Caritas der Erzdiözese Wien gem.;Axel-Corti-Gasse 12/3/1A;1210;"
                + "1x Vitalmenü EP TGM5;",
            "VM 5 FR Vormittag;40;S17069;04.09.2026;26063126;552714;"
                + "Caritas der Erzdiözese Wien gem.;Axel-Corti-Gasse 12/3/1A;1210;"
                + "1x Vitalmenü EP TGM5;",
        ].joined(separator: "\r\n")
        let fromCSV = try Tagesliste.parse(Data(csv.utf8), filename: "tour.csv")

        #expect(fromWorkbook.map(\.kunde) == fromCSV.map(\.kunde))
        #expect(fromWorkbook.map(\.strasse) == fromCSV.map(\.strasse))
        #expect(fromWorkbook.map(\.plz) == fromCSV.map(\.plz))
        #expect(fromWorkbook.map(\.paket) == fromCSV.map(\.paket))
        #expect(fromWorkbook.map(\.notiz) == fromCSV.map(\.notiz))
    }

    /// Umlauts survive the whole way — through deflate, through XML, through
    /// the shared-string table.
    @Test func theAddressesSurviveIntact() throws {
        let entries = try Tagesliste.parse(XLSXFixtures.tour)
        #expect(entries[0].strasse == "Mühlschüttelgasse 55-57/6/5")
        #expect(entries.last?.kunde == "Caritas der Erzdiözese Wien gem.")
        #expect(entries.last?.strasse == "Axel-Corti-Gasse 12/3/1A")
    }

    /// And every entry a workbook produces is one the import will accept.
    @Test func everyEntryIsReadyForTheImport() throws {
        for entry in try Tagesliste.parse(XLSXFixtures.tour) {
            #expect(Districts.isValid(entry.plz))
            #expect(!entry.kunde.isEmpty)
            #expect(throws: Never.self) {
                try RouteStore.validateCustomerFields(
                    kunde: entry.kunde, strasse: entry.strasse,
                    paket: entry.paket, notiz: entry.notiz)
            }
        }
    }

    /// A ZIP that is not a workbook — an `.ods`, a folder someone zipped — is
    /// named for what it is rather than reported as a broken Excel file.
    @Test func aZipThatIsNotAWorkbookSaysSo() {
        // A structurally valid but empty archive — an end-of-central-directory
        // record and nothing else.
        let empty = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
        #expect(throws: AppError.self) { try Tagesliste.parse(empty, filename: "x.ods") }
    }

    /// The old binary `.xls` is still refused, and says what to do.
    @Test func theOldBinaryFormatIsStillRefused() {
        let xls = Data([0xD0, 0xCF, 0x11, 0xE0] + Array(repeating: 0, count: 64))
        do {
            _ = try Tagesliste.parse(xls, filename: "Tour.xls")
            Issue.record("expected a refusal")
        } catch let e as AppError {
            #expect(e.message.contains("Tour.xls"))
            #expect(e.message.contains("xlsx") || e.message.contains("CSV"))
        } catch {
            Issue.record("expected an AppError")
        }
    }
}

/// The reader against a workbook shaped the way Excel actually shapes one.
///
/// The fixture above is minimal; this one carries everything a real export has
/// that a minimal one does not — a merged title block, a gap in the row
/// numbers, style indices on every cell, a date as a serial number, formulas
/// with cached results, a formula that errored, a name split into rich-text
/// runs, `xml:space="preserve"`, and the `mc:Ignorable` namespace soup.
///
/// It is still not a file from the office's Excel. It is as close as can be
/// built without one.
struct XLSXExcelShapedTests {

    private func parse() throws -> [CustomerJSON] {
        try Tagesliste.parse(XLSXFixtures.excelLike, filename: "Tour VM5.xlsx")
    }

    /// The header is on row 3, under a merged title and a row Excel did not
    /// write at all.
    @Test func findsTheHeaderUnderAMergedTitleAndASkippedRow() throws {
        let entries = try parse()
        #expect(entries.count == 5)
        #expect(entries[0].kunde == "Thomas Kaltenbacher")
    }

    /// A name Excel stored as two runs — "Thomas " bolded, then "Kaltenbacher"
    /// — is one name, not two and not the first half.
    @Test func richTextRunsBecomeOneName() throws {
        #expect(try parse()[0].kunde == "Thomas Kaltenbacher")
    }

    /// `xml:space="preserve"` keeps the padding Excel stored; the import
    /// trims it, because " lfd " is the note "lfd".
    @Test func preservedWhitespaceIsStillTrimmed() throws {
        #expect(try parse()[0].notiz == "lfd")
    }

    /// The Hinweis column is a VLOOKUP. Its cached result is what the driver
    /// sees on the printed sheet, and it is what the cell is worth here.
    @Test func aFormulaCellReadsAsItsCachedResult() throws {
        #expect(try parse()[0].notiz == "lfd")
    }

    /// And where that VLOOKUP failed, the cell is a typed error — which is the
    /// `#NV` on three of the four photographed pages.
    @Test func aFormulaThatErroredIsWorthNothing() throws {
        let pusch = try #require(try parse().first { $0.kunde == "Edith Pusch" })
        #expect(pusch.notiz == nil)
    }

    /// Row 5's Hinweis cell is absent entirely. Every column after it must
    /// stay where it belongs.
    @Test func anAbsentTrailingCellDoesNotDisturbTheRow() throws {
        let tenor = try #require(try parse().first { $0.kunde == "Peter Tenor" })
        #expect(tenor.strasse == "Floridusgasse 51/10")
        #expect(tenor.plz == "1210")
        #expect(tenor.paket == "1x Vitalmenü EP TGM5")
        #expect(tenor.notiz == nil)
    }

    /// The Datum column is a date serial number with a date format. It is not
    /// read — but it must not be mistaken for anything either.
    @Test func theDateColumnIsIgnoredRatherThanMisread() throws {
        for entry in try parse() {
            #expect(!entry.strasse.contains("46265"))
            #expect(entry.plz == "1210")
        }
    }

    /// Style indices on every cell change nothing about what a cell says.
    @Test func styledCellsReadTheSame() throws {
        let entries = try parse()
        #expect(entries[0].strasse == "Mühlschüttelgasse 55-57/6/5")
        #expect(entries[0].paket == "1x Vitalmenü EP DLM5 (LVK)")
    }

    /// And the whole list is ready for the import, same as every other source.
    @Test func everyEntryIsReadyForTheImport() throws {
        for entry in try parse() {
            #expect(Districts.isValid(entry.plz))
            #expect(!entry.kunde.isEmpty)
            #expect(!entry.strasse.isEmpty)
            #expect(throws: Never.self) {
                try RouteStore.validateCustomerFields(
                    kunde: entry.kunde, strasse: entry.strasse,
                    paket: entry.paket, notiz: entry.notiz)
            }
        }
    }
}
