import Testing
import Foundation
@testable import EarRouter

/// Reading the office's own daily list out of a file.
///
/// Every fixture here is built from a real printed list — the column names, the
/// addresses with their Stiege and Tür, the `#NV` where a lookup in the sheet
/// found nothing, the five consecutive meals for one institution at one door.
/// The parser is the only part of this path that has never seen the real file,
/// so it is the part that gets pinned down hardest.
struct TageslisteTests {

    /// The header, exactly as the list prints it.
    private let header = "Tour;Stopp;Referenzbeleg;Datum;KDNr.;Parat;KD;Straße;Plz;Paket;Hinweis"

    private func row(
        stopp: String = "1", kd: String, strasse: String, plz: String = "1210",
        paket: String = "1x Vitalmenü EP TGM5", hinweis: String = ""
    ) -> String {
        "VM 5 FR Vormittag;\(stopp);S17207;04.09.2026;26064642;547179;"
            + "\(kd);\(strasse);\(plz);\(paket);\(hinweis)"
    }

    private func parse(_ text: String) throws -> [CustomerJSON] {
        try Tagesliste.parse(Data(text.utf8))
    }

    // MARK: - The list as it actually arrives

    @Test func readsARealRow() throws {
        let list = try parse(
            [header,
             row(kd: "Thomas Kaltenbacher", strasse: "Mühlschüttelgasse 55-57/6/5",
                 paket: "1x Vitalmenü EP DLM5 (LVK)", hinweis: "lfd")].joined(separator: "\n"))

        #expect(list.count == 1)
        #expect(list[0].kunde == "Thomas Kaltenbacher")
        #expect(list[0].strasse == "Mühlschüttelgasse 55-57/6/5")
        #expect(list[0].plz == "1210")
        #expect(list[0].paket == "1x Vitalmenü EP DLM5 (LVK)")
        #expect(list[0].notiz == "lfd")
    }

    /// The five columns that belong to the office — Tour, Stopp,
    /// Referenzbeleg, Datum, KDNr., Parat — are read past, and crucially
    /// `KDNr.` is not mistaken for `KD`.
    @Test func readsPastTheOfficesOwnColumns() throws {
        let list = try parse(
            [header, row(kd: "Peter Tenor", strasse: "Floridusgasse 51/10")]
                .joined(separator: "\n"))
        #expect(list[0].kunde == "Peter Tenor")
        #expect(list[0].kunde != "26064642")
    }

    /// The whole reason a file is read by column name rather than by position.
    @Test func survivesTheColumnsMovingAround() throws {
        let list = try parse("""
            Hinweis;Plz;KD;Paket;Straße;KDNr.
            lfd;1210;Franz Roller;1x Vitalmenü EP TGMS5;Donaufelder Straße 40-42/2/24;26063386
            """)
        #expect(list[0].kunde == "Franz Roller")
        #expect(list[0].strasse == "Donaufelder Straße 40-42/2/24")
        #expect(list[0].plz == "1210")
        #expect(list[0].paket == "1x Vitalmenü EP TGMS5")
        #expect(list[0].notiz == "lfd")
    }

    /// An unknown column is somebody else's business, not an error.
    @Test func ignoresColumnsItDoesNotKnow() throws {
        let list = try parse("""
            KD;Kostenstelle;Straße;Plz;Abrechnung
            Anita Zouhar;44711;Rubingasse 32;1210;pauschal
            """)
        #expect(list.count == 1)
        #expect(list[0].kunde == "Anita Zouhar")
    }

    // MARK: - Separators, because Excel has three

    /// The most likely file this app will ever be handed: an Austrian Excel
    /// writes CSV with semicolons, because the comma is the decimal separator.
    @Test func readsSemicolonSeparatedCSV() throws {
        let list = try parse("KD;Straße;Plz\nPeter Holli;Scottgasse 29/142/8;1210")
        #expect(list[0].strasse == "Scottgasse 29/142/8")
    }

    @Test func readsCommaSeparatedCSV() throws {
        let list = try parse("KD,Straße,Plz\nPeter Holli,Scottgasse 29/142/8,1210")
        #expect(list[0].strasse == "Scottgasse 29/142/8")
    }

    /// "Text (Tabstopp-getrennt)", the other thing the Speichern-unter menu
    /// offers.
    @Test func readsTabSeparatedText() throws {
        let list = try parse("KD\tStraße\tPlz\nPeter Holli\tScottgasse 29/142/8\t1210")
        #expect(list[0].strasse == "Scottgasse 29/142/8")
    }

    /// The case that defeats counting characters to guess the separator: a
    /// dispatcher's note has more commas in one cell than the row has
    /// semicolons. Parsing each way and keeping the reading that yields a table
    /// cannot be fooled by it.
    @Test func aNoteFullOfCommasDoesNotLookLikeACommaSeparatedFile() throws {
        let list = try parse("""
            KD;Straße;Plz;Hinweis
            Gerald Kreutzbruck;Mühlschüttelgasse 37/4/2;1210;wenn Kd nicht anwesend, abgeben bei Sonja DOMBROWSKI (Tür 7, einen Stock höher) (Genehmigung)
            """)
        #expect(list.count == 1)
        #expect(list[0].strasse == "Mühlschüttelgasse 37/4/2")
        #expect(list[0].notiz?.contains("Sonja DOMBROWSKI") == true)
    }

    // MARK: - What Excel puts in the cells

    /// `#NV` is on three of the four pages of a real list, in the Hinweis
    /// column, because the sheet looks something up per customer and does not
    /// always find it. Left alone it becomes a driver at a door reading a
    /// spreadsheet error.
    @Test func excelErrorValuesBecomeNothing() throws {
        let list = try parse(
            [header, row(kd: "Edith Pusch", strasse: "Edergasse 4/1", hinweis: "#NV")]
                .joined(separator: "\n"))
        #expect(list[0].notiz == nil)
    }

    @Test func knowsTheEnglishErrorValuesToo() {
        #expect(Tagesliste.isExcelError("#NV"))
        #expect(Tagesliste.isExcelError("#N/A"))
        #expect(Tagesliste.isExcelError("#WERT!"))
        #expect(Tagesliste.isExcelError("#REF!"))
        #expect(Tagesliste.isExcelError("#DIV/0!"))
        // A note that merely starts with a hash is a note.
        #expect(!Tagesliste.isExcelError("#3 klingeln"))
        #expect(!Tagesliste.isExcelError("lfd"))
    }

    /// A Hinweis is typed into a cell and wraps. Quoted, it reaches the file
    /// with its newline intact, and the two halves have to come back as words
    /// with a space between them rather than as "stellenwenn".
    @Test func aCellThatWrapsComesBackAsOneSentence() throws {
        let list = try parse("""
            KD;Straße;Plz;Hinweis
            Josef Krispel;Puffergasse 1/4/4/8;1210;"bitte immer anläuten, persönlich übergeben
            wenn möglich vor 12 Uhr"
            """)
        #expect(list.count == 1)
        #expect(list[0].notiz == "bitte immer anläuten, persönlich übergeben wenn möglich vor 12 Uhr")
    }

    @Test func handlesQuotedFieldsAndDoubledQuotes() throws {
        // Written by hand rather than as a multi-line literal: the cell being
        // tested ends in three quote marks, which is also how a Swift
        // multi-line literal ends.
        let q = "\""
        let text = "KD;Straße;Plz;Hinweis\n"
            + "\(q)Müllner, Ivkica\(q);Nordmanngasse 15/6;1210;"
            + "\(q)sagt \(q)\(q)bitte laut klingeln\(q)\(q)\(q)"
        let list = try parse(text)
        #expect(list[0].kunde == "Müllner, Ivkica")
        #expect(list[0].notiz == #"sagt "bitte laut klingeln""#)
    }

    /// Windows Excel writes CRLF.
    @Test func handlesWindowsLineEndings() throws {
        let list = try parse("KD;Straße;Plz\r\nAlex Langer;Nordmanngasse 27/1/7;1210\r\n")
        #expect(list.count == 1)
        #expect(list[0].kunde == "Alex Langer")
    }

    // MARK: - Encodings

    @Test func readsUTF8WithAByteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("KD;Straße;Plz\nElfriede Wittmann;Frömmlgasse 5/10/7;1210".utf8))
        let list = try Tagesliste.parse(data)
        #expect(list[0].kunde == "Elfriede Wittmann")
        #expect(list[0].strasse == "Frömmlgasse 5/10/7")
    }

    /// Excel's plain "CSV" on Windows is still written in the system code page.
    /// Read as UTF-8 that fails on every ß, ä, ö and ü — which is to say, on
    /// this list.
    @Test func fallsBackToWindowsCodePageForUmlauts() throws {
        let text = "KD;Straße;Plz\nElfriede Wittmann;Frömmlgasse 5/10/7;1210"
        let data = text.data(using: .windowsCP1252)!
        #expect(String(data: data, encoding: .utf8) == nil)
        let list = try Tagesliste.parse(data)
        #expect(list[0].strasse == "Frömmlgasse 5/10/7")
    }

    @Test func readsUTF16() throws {
        var data = Data([0xFF, 0xFE])
        data.append("KD;Straße;Plz\nMaria Strasser;Freytaggasse 2-14/31/1;1210"
            .data(using: .utf16LittleEndian)!)
        let list = try Tagesliste.parse(data)
        #expect(list[0].kunde == "Maria Strasser")
    }

    // MARK: - The shape of the page

    /// The list prints the date above the table, and an export carries that
    /// line. The header is found rather than assumed to be row one.
    @Test func findsTheHeaderUnderAPreamble() throws {
        let list = try parse("""
            Freitag, 04.09.2026

            \(header)
            \(row(kd: "Rudolf Zimmermann", strasse: "Schenkendorfgasse 49-53/3/5/21"))
            """)
        #expect(list.count == 1)
        #expect(list[0].kunde == "Rudolf Zimmermann")
    }

    /// A page footer, a blank spacer, a totals line: none of them carry an
    /// address, and none of them is a customer worth reporting as rejected.
    @Test func skipsRowsWithNoAddress() throws {
        let list = try parse("""
            \(header)
            \(row(kd: "Peter Tenor", strasse: "Floridusgasse 51/10"))
            ;;;;;;;;;;
            Seite 1 von 5
            \(row(kd: "Franz Roller", strasse: "Donaufelder Straße 40-42/2/24"))
            """)
        #expect(list.count == 2)
        #expect(list.map(\.kunde) == ["Peter Tenor", "Franz Roller"])
    }

    /// Five meals to one institution at one door, all under the same name. They
    /// have to survive as five entries: they are five meals carried up.
    @Test func keepsEveryMealAtAnInstitutionalAddress() throws {
        let five = (0..<5).map {
            row(stopp: "\(39 + $0)", kd: "Caritas der Erzdiözese Wien gem.",
                strasse: "Axel-Corti-Gasse 12/3/1A")
        }
        let list = try parse(([header] + five).joined(separator: "\n"))
        #expect(list.count == 5)
        #expect(list.allSatisfy { $0.kunde == "Caritas der Erzdiözese Wien gem." })
    }

    /// A separate first and last name is put back together, for the day the
    /// export splits the column.
    @Test func joinsASplitName() throws {
        let list = try parse("""
            Vorname;Nachname;Straße;Plz
            Eleonora und Thomas;Rieder;Patrizigasse 9/10;1210
            """)
        #expect(list[0].kunde == "Eleonora und Thomas Rieder")
    }

    @Test func pullsAPostcodeOutOfWhateverTheCellHolds() throws {
        let list = try parse("""
            KD;Straße;Plz
            A;Gasse 1;1210 Wien
            B;Gasse 2;A-1100
            C;Gasse 3;1210
            """)
        #expect(list.map(\.plz) == ["1210", "1100", "1210"])
    }

    // MARK: - Refusing what it cannot read

    /// A workbook is a ZIP and is now read rather than refused — see
    /// `XLSXTests`. What is still refused is a ZIP that only *claims* to be
    /// one: four bytes of signature and nothing behind them is a damaged file,
    /// and is named as one.
    @Test func refusesSomethingThatOnlyStartsLikeAnArchive() {
        let truncated = Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 64))
        #expect(throws: AppError.self) {
            try Tagesliste.parse(truncated, filename: "Tour.xlsx")
        }
    }

    /// The old binary `.xls`, which is a 1997 compound-file document and a
    /// different problem entirely. Refused, and told what to do about it.
    @Test func refusesTheOldBinaryExcelFormat() {
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

    @Test func refusesAFileWithNoRecognisableHeader() {
        let text = "Alpha;Beta;Gamma\n1;2;3"
        #expect(throws: AppError.self) { try Tagesliste.parse(Data(text.utf8)) }
    }

    @Test func refusesAHeaderWithNoRowsUnderIt() {
        #expect(throws: AppError.self) { try Tagesliste.parse(Data(header.utf8)) }
    }

    @Test func refusesAnEmptyFile() {
        #expect(throws: AppError.self) { try Tagesliste.parse(Data()) }
    }

    // MARK: - Straight into the tour

    /// The parsed list has to be the same shape the paste path produces, since
    /// both go to the same review screen and the same import.
    @Test func producesEntriesTheImportAlreadyUnderstands() throws {
        let list = try parse([
            header,
            row(kd: "Brigitte Kratky", strasse: "Koloniestraße 2-10/14/8",
                paket: "1x Vitalmenü EP DBM7 (DIA)", hinweis: "persönlich"),
        ].joined(separator: "\n"))

        #expect(throws: Never.self) {
            try RouteStore.validateCustomerFields(
                kunde: list[0].kunde, strasse: list[0].strasse,
                paket: list[0].paket, notiz: list[0].notiz)
        }
        #expect(Districts.isValid(list[0].plz))
        // And the address survives the app's own normalisation with its Stiege
        // and Tür intact, which is what places the van at the right door.
        #expect(AddressText.matchKey(list[0].strasse) == "koloniestrasse 2 10 14 8")
    }
}

/// The whole file path, from bytes on disk to entries ready for the review
/// screen — the same three steps `RouteDetailView.readList` takes once the
/// document picker hands it a URL.
///
/// The fixture is written the way the office's export actually is and not the
/// way a test is convenient: Windows-1252 rather than UTF-8, CRLF rather than
/// LF, semicolons rather than commas, a date line above the header, `#NV` where
/// the sheet's own lookup failed, a quoted Hinweis that wraps, five identical
/// institutional rows, and a page footer underneath.
struct TageslisteFileTests {

    private func writeFixture() throws -> URL {
        let rows: [String] = [
            "Freitag, 04.09.2026",
            "Tour;Stopp;Referenzbeleg;Datum;KDNr.;Parat;KD;Straße;Plz;Paket;Hinweis",
            "VM 5 FR Vormittag;1;S17207;04.09.2026;26064642;547179;Thomas Kaltenbacher;"
                + "Mühlschüttelgasse 55-57/6/5;1210;1x Vitalmenü EP DLM5 (LVK);lfd",
            "VM 5 FR Vormittag;3;S17295;04.09.2026;26064641;553991;Gerald Kreutzbruck;"
                + "Mühlschüttelgasse 37/4/2;1210;1x Vitalmenü EP TGM5;"
                + "\"wenn Kd nicht anwesend, abgeben bei Sonja DOMBROWSKI\r\n"
                + "(Tür 7, einen Stock höher) (Genehmigung)\"",
            "VM 5 FR Vormittag;21;S15165;04.09.2026;26087300;0;Edith Pusch;"
                + "Edergasse 4/1;1210;1x Vitalmenü EP TGMS7;#NV",
            "VM 5 FR Vormittag;39;S17068;04.09.2026;26063126;552714;"
                + "Caritas der Erzdiözese Wien gem.;Axel-Corti-Gasse 12/3/1A;1210;"
                + "1x Vitalmenü EP TGM5;",
            "VM 5 FR Vormittag;40;S17069;04.09.2026;26063126;552714;"
                + "Caritas der Erzdiözese Wien gem.;Axel-Corti-Gasse 12/3/1A;1210;"
                + "1x Vitalmenü EP TGM5;",
            ";;;;;;;;;;",
            "Seite 1 von 5",
        ]
        let text = rows.joined(separator: "\r\n")
        // Excel's plain CSV on a German Windows. Not UTF-8.
        let data = text.data(using: .windowsCP1252)!
        // A folder of its own per call. Both tests in this suite write this
        // fixture and Swift Testing runs them in parallel; at one shared path,
        // each test's cleanup could delete the other's file between its write
        // and its read, and the suite failed now and then for no reason of its
        // own.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Tour VM5 FR 04.09.2026.csv")
        try data.write(to: url, options: .atomic)
        return url
    }

    @Test func readsTheOfficesFileOffDiskExactlyAsItArrives() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let data = try Data(contentsOf: url)
        let list = try Tagesliste.parse(data, filename: url.lastPathComponent)

        #expect(list.count == 5)
        #expect(list.map(\.kunde) == [
            "Thomas Kaltenbacher",
            "Gerald Kreutzbruck",
            "Edith Pusch",
            "Caritas der Erzdiözese Wien gem.",
            "Caritas der Erzdiözese Wien gem.",
        ])

        // The umlauts survived a code page that is not UTF-8 …
        #expect(list[0].strasse == "Mühlschüttelgasse 55-57/6/5")
        // … the wrapped Hinweis came back as one sentence …
        #expect(list[1].notiz == "wenn Kd nicht anwesend, abgeben bei Sonja DOMBROWSKI "
            + "(Tür 7, einen Stock höher) (Genehmigung)")
        // … the spreadsheet's own error did not become a note …
        #expect(list[2].notiz == nil)
        // … and the page furniture is not a customer.
        #expect(!list.contains { $0.kunde.contains("Seite") })
    }

    /// And every entry it produces is one the import will accept — which is the
    /// promise the review screen makes when it shows a row without a warning.
    @Test func everyEntryIsReadyForTheImport() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let list = try Tagesliste.parse(try Data(contentsOf: url))

        for entry in list {
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
