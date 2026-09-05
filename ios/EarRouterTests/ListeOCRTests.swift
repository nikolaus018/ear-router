import Testing
import Foundation
@testable import EarRouter

/// Reading the printed tour list off a photograph of it.
///
/// These work on `OCRWord`s — text plus the box it sat in — which is the whole
/// point of that seam: what can actually go wrong here is which row and which
/// column a word belongs to, and that has to be testable without a camera, a
/// photograph or a device.
///
/// The page below is built the way the real one is printed, including the two
/// things that make it hard. Its cells **wrap**, so one customer occupies two
/// or three printed lines and a Hinweis can be taller than everything beside
/// it; and its rows are set with **no clear space between them**, so the step
/// from the last line of one row to the first line of the next is exactly the
/// step between two wrapped lines inside a cell. That is not an exaggeration
/// for the sake of a test — it is measured off a real page, and it is why
/// every "group the lines by the gaps between them" approach to this fails.
struct ListeOCRTests {

    // MARK: - Building a page

    /// The eleven printed columns, at the positions and widths a real page has
    /// them at: where each starts, and how much room it has before it wraps.
    private enum Col {
        static let tour = (x: 0.053, width: 0.070)
        static let stopp = (x: 0.125, width: 0.017)
        static let beleg = (x: 0.144, width: 0.053)
        static let datum = (x: 0.200, width: 0.062)
        static let kdnr = (x: 0.263, width: 0.060)
        static let parat = (x: 0.325, width: 0.042)
        static let kd = (x: 0.369, width: 0.076)
        static let strasse = (x: 0.447, width: 0.100)
        static let plz = (x: 0.550, width: 0.028)
        static let paket = (x: 0.581, width: 0.120)
        static let hinweis = (x: 0.703, width: 0.210)
    }

    /// Lays out a page of the list, row by row down the sheet.
    private struct Page {
        static let leading = 0.012
        static let textHeight = 0.008
        static let charWidth = 0.0055

        var words: [OCRWord] = []
        /// The height of the next block's *top* line. Blocks are laid out
        /// down the page with a single line's step between them and nothing
        /// else — no rule, no padding — because that is what the real page
        /// does, and it is the whole reason finding the rows is hard.
        private var cursor = 0.86
        /// How far the photograph is from square. `columns` leans every column
        /// sideways as it goes down the page; `rowsAtTop` tilts every row, by
        /// an amount that itself eases off further down — which is what a
        /// perspective view of a sheet of paper actually does, and what no
        /// single shear can undo.
        var lean = (columns: 0.0, rowsAtTop: 0.0)

        /// The column headings, which wrap in their own narrow cells exactly
        /// as the data does — "Referenzbeleg" comes out three lines tall on
        /// the real sheet, and that is what makes the header row as tall as it
        /// is.
        mutating func header() {
            block([
                (Col.tour, "Tour"), (Col.stopp, "Stopp"), (Col.beleg, "Referenzbeleg"),
                (Col.datum, "Datum"), (Col.kdnr, "KDNr."), (Col.parat, "Parat"),
                (Col.kd, "KD"), (Col.strasse, "Straße"), (Col.plz, "Plz"),
                (Col.paket, "Paket"), (Col.hinweis, "Hinweis"),
            ])
        }

        /// One delivery, laid out as the printer does it: every cell wrapped
        /// to its column's width, and every cell sitting on the *bottom* of
        /// the row so that a tall one grows upwards.
        mutating func row(
            stopp: Int? = nil, kd: String, strasse: String, plz: String? = "1210",
            paket: String? = "1x Vitalmenü EP TGM5", hinweis: String? = nil,
            beleg: String = "S17207", datum: String? = "04.09.2026",
            kdnr: String? = "26064642", parat: String? = "547179"
        ) {
            var cells: [(column: (x: Double, width: Double), text: String)] = [
                (Col.tour, "VM 5 FR Vormittag"), (Col.beleg, beleg), (Col.kd, kd),
                (Col.strasse, strasse), (Col.paket, paket ?? ""),
                (Col.hinweis, hinweis ?? ""),
            ]
            if let stopp { cells.append((Col.stopp, String(stopp))) }
            if let datum { cells.append((Col.datum, datum)) }
            if let kdnr { cells.append((Col.kdnr, kdnr)) }
            if let parat { cells.append((Col.parat, parat)) }
            if let plz { cells.append((Col.plz, plz)) }
            block(cells)
        }

        /// A line of the page's own furniture: the date above the table, the
        /// page number below it.
        mutating func caption(_ text: String) {
            block([((x: 0.44, width: 0.2), text)])
        }

        private mutating func block(
            _ cells: [(column: (x: Double, width: Double), text: String)]
        ) {
            let wrapped = cells.map {
                (column: $0.column, lines: Page.wrap($0.text, into: $0.column.width))
            }
            let tallest = wrapped.map(\.lines.count).max() ?? 1
            let bottom = cursor - Page.leading * Double(tallest - 1)
            for cell in wrapped {
                for (i, line) in cell.lines.enumerated() {
                    place(
                        line, in: cell.column,
                        y: bottom + Page.leading * Double(cell.lines.count - 1 - i))
                }
            }
            cursor = bottom - Page.leading
        }

        private mutating func place(
            _ text: String, in column: (x: Double, width: Double), y: Double
        ) {
            var pen = column.x
            for word in text.split(separator: " ") {
                let width = Double(word.count) * Page.charWidth
                words.append(warped(String(word), x0: pen, width: width, y: y))
                pen += width + Page.charWidth
            }
        }

        private func warped(_ text: String, x0: Double, width: Double, y: Double) -> OCRWord {
            let xShift = lean.columns * (y - 0.6)
            let tilt = lean.rowsAtTop * ((y - 0.4) / 0.4)
            let yShift = tilt * (x0 + width / 2 - 0.45)
            return OCRWord(
                text: text, x0: x0 + xShift, x1: x0 + width + xShift,
                y0: y + yShift - Page.textHeight / 2, y1: y + yShift + Page.textHeight / 2)
        }

        /// Greedy wrap, the way a table cell does it.
        private static func wrap(_ text: String, into width: Double) -> [String] {
            var lines: [String] = []
            var line = ""
            for word in text.split(separator: " ") {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if !line.isEmpty, Double(candidate.count) * charWidth > width {
                    lines.append(line)
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            if !line.isEmpty { lines.append(line) }
            return lines.isEmpty ? [""] : lines
        }
    }

    /// A page of the real tour, including the rows that break naive parses:
    /// wrapped names, wrapped addresses, and a three-line Hinweis on row 3
    /// whose top line sits level with the row above it.
    private func realPage(lean: (columns: Double, rowsAtTop: Double) = (0, 0)) -> Page {
        var page = Page()
        page.lean = lean
        page.caption("Freitag, 04.09.2026")
        page.header()
        page.row(
            stopp: 1, kd: "Thomas Kaltenbacher", strasse: "Mühlschüttelgasse 55-57/6/5",
            paket: "1x Vitalmenü EP DLM5 (LVK)", hinweis: "lfd")
        page.row(stopp: 2, kd: "Peter Tenor", strasse: "Floridusgasse 51/10")
        page.row(
            stopp: 3, kd: "Gerald Kreutzbruck", strasse: "Mühlschüttelgasse 37/4/2",
            hinweis: "wenn Kd nicht anwesend, abgeben bei Sonja DOMBROWSKI "
                + "(Tür 7, einen Stock höher) (Genehmigung)")
        page.row(
            stopp: 4, kd: "Ivkica Müllner", strasse: "Nordmanngasse 15/6",
            hinweis: "persönlich übergeben, braucht länger")
        page.row(
            stopp: 5, kd: "Franz Roller", strasse: "Donaufelder Straße 40-42/2/24",
            hinweis: "vdt")
        page.row(stopp: 6, kd: "Alex Langer", strasse: "Nordmanngasse 27/1/7")
        page.caption("Seite 1 von 5")
        return page
    }

    /// Three plain rows, for the cases that need a page but not a hard one.
    private func plainPage(_ build: (inout Page) -> Void = { _ in }) -> Page {
        var page = Page()
        page.header()
        build(&page)
        page.row(stopp: 8, kd: "Peter Tenor", strasse: "Floridusgasse 51/10")
        page.row(stopp: 9, kd: "Alex Langer", strasse: "Nordmanngasse 27/1/7")
        return page
    }

    private func read(_ page: Page) -> [ScannedStop] { ListeOCR.stops(in: page.words) }

    // MARK: - An ordinary page

    @Test func readsEveryDeliveryAndNothingElse() {
        let stops = read(realPage())
        #expect(stops.count == 6)
        #expect(stops.compactMap(\.problem).isEmpty)
        #expect(stops.first?.kunde == "Thomas Kaltenbacher")
        #expect(stops.last?.kunde == "Alex Langer")
    }

    /// Wrapped cells, joined back together in reading order: down the page,
    /// then across.
    @Test func joinsCellsThatWrapOntoASecondLine() {
        let stops = read(realPage())
        #expect(stops[0].kunde == "Thomas Kaltenbacher")
        #expect(stops[0].strasse == "Mühlschüttelgasse 55-57/6/5")
        #expect(stops[0].plz == "1210")
        #expect(stops[0].paket == "1x Vitalmenü EP DLM5 (LVK)")
        #expect(stops[0].notiz == "lfd")
    }

    /// The case this whole approach exists for. Row 3's Hinweis runs to three
    /// lines while every cell beside it uses one, so its top line sits level
    /// with the row above — nearer to that row's centre than to its own. Any
    /// scheme that gives a line to the closest row hands this note to Peter
    /// Tenor, and the customer with the most delivery instructions is the one
    /// whose instructions go missing.
    @Test func aTallHinweisStaysWithItsOwnRow() {
        let stops = read(realPage())
        #expect(stops[1].kunde == "Peter Tenor")
        #expect(stops[1].notiz == nil)
        #expect(stops[2].kunde == "Gerald Kreutzbruck")
        #expect(
            stops[2].notiz
                == "wenn Kd nicht anwesend, abgeben bei Sonja DOMBROWSKI "
                    + "(Tür 7, einen Stock höher) (Genehmigung)")
    }

    /// The page's own furniture is not a delivery: the date printed above the
    /// table, the column headings, the page number below it.
    @Test func skipsTheTitleTheHeaderAndTheFooter() {
        let stops = read(realPage())
        let everything = stops.map { "\($0.kunde) \($0.strasse) \($0.notiz ?? "")" }
            .joined(separator: " ")
        #expect(!everything.contains("Freitag"))
        #expect(!everything.contains("Seite"))
        #expect(!everything.contains("KDNr"))
    }

    /// The header's "Straße" cell is a column heading, not an address.
    @Test func aBareStreetSuffixIsAHeadingNotAnAddress() {
        #expect(!ListeOCR.isStreetName("Straße"))
        #expect(!ListeOCR.isStreetName("Gasse"))
        #expect(ListeOCR.isStreetName("Floridusgasse"))
        #expect(ListeOCR.isStreetName("Skraupstraße"))
        #expect(ListeOCR.isStreetName("Erna-Musik-Gasse"))
    }

    // MARK: - What a photograph does to a page

    /// A sheet photographed one-handed on a van seat. The columns lean, the
    /// rows tilt — and the tilt eases off down the page, which is the part
    /// that matters: it means the sheet cannot be straightened by any single
    /// shear, and the rows have to be found on a page that is still crooked.
    ///
    /// The amount is the one measured off a real photograph, where the Bezirk
    /// sat a full printed line below the Datum on the same row at the top of
    /// the sheet, and level with it at the bottom.
    @Test func readsAPageThatWasNotHeldSquare() {
        let stops = read(realPage(lean: (columns: 0.30, rowsAtTop: -0.032)))
        #expect(stops.count == 6)
        #expect(stops.compactMap(\.problem).isEmpty)
        #expect(stops[0].kunde == "Thomas Kaltenbacher")
        #expect(stops[0].strasse == "Mühlschüttelgasse 55-57/6/5")
        #expect(stops[2].kunde == "Gerald Kreutzbruck")
        #expect(stops[2].notiz?.hasPrefix("wenn Kd nicht anwesend") == true)
        #expect(stops[5].kunde == "Alex Langer")
    }

    /// Leaning the other way, which is the same problem mirrored.
    @Test func readsAPageThatLeansTheOtherWay() {
        let stops = read(realPage(lean: (columns: -0.30, rowsAtTop: 0.032)))
        #expect(stops.count == 6)
        #expect(stops.compactMap(\.problem).isEmpty)
        #expect(stops[2].notiz?.hasPrefix("wenn Kd nicht anwesend") == true)
    }

    /// The column rules are printed under a millimetre wide and the recogniser
    /// reads straight across them, gluing the customer number to the surname
    /// beside it. The rule itself comes through as a pipe, which is the one
    /// reliable marker of where the join was.
    @Test func splitsWordsGluedAcrossAColumnRule() {
        var page = realPage()
        guard let name = page.words.first(where: { $0.text == "Kaltenbacher" }),
              let parat = page.words.first(where: { $0.text == "547179" })
        else { Issue.record("fixture changed"); return }
        page.words.removeAll { $0.text == "547179" || $0.text == "Kaltenbacher" }
        page.words.append(
            OCRWord(
                text: "547179|Kaltenbacher", x0: parat.x0, x1: name.x1,
                y0: parat.y0, y1: parat.y1))

        let stops = ListeOCR.stops(in: page.words)
        #expect(stops[0].kunde == "Thomas Kaltenbacher")
        #expect(stops[0].strasse == "Mühlschüttelgasse 55-57/6/5")
    }

    // MARK: - Markers the camera missed

    /// Every row announces where it ends four times over — its Datum, its
    /// KDNr., its Parat and its Plz all sit on its last line. Losing one of
    /// them costs the field, never the row.
    @Test func findsARowWhosePostcodeWasNotRead() {
        let stops = read(
            plainPage {
                $0.row(
                    stopp: 7, kd: "Eleonora und Thomas Rieder", strasse: "Patrizigasse 9/10",
                    plz: nil, hinweis: "4. Stock")
            })
        #expect(stops.count == 3)
        #expect(stops[0].kunde == "Eleonora und Thomas Rieder")
        #expect(stops[0].strasse == "Patrizigasse 9/10")
        #expect(stops[0].notiz == "4. Stock")
        #expect(stops[0].problem == "Kein Bezirk erkannt.")
    }

    @Test func findsARowWhoseDateAndCustomerNumberWereNotRead() {
        let stops = read(
            plainPage {
                $0.row(
                    stopp: 7, kd: "Maria Strasser", strasse: "Freytaggasse 2-14/31/1",
                    datum: nil, kdnr: nil)
            })
        #expect(stops.count == 3)
        #expect(stops[0].kunde == "Maria Strasser")
        #expect(stops[0].plz == "1210")
        #expect(stops[0].isUsable)
    }

    /// What the rule beside that narrow column does to the postcode: read as
    /// part of the menu code after it, or with the rule itself picked up in
    /// front of it as a bracket.
    @Test func readsAPostcodeTheColumnRuleRanInto() {
        #expect(ListeOCR.postcode("1210TGMS5") == "1210")
        #expect(ListeOCR.postcode("[1210") == "1210")
        #expect(ListeOCR.postcode("1210") == "1210")
        #expect(ListeOCR.withoutPostcode("1210TGMS5") == "TGMS5")
        #expect(ListeOCR.withoutPostcode("[1210") == "")
    }

    @Test func doesNotFindAPostcodeInsideALongerNumber() {
        #expect(ListeOCR.postcode("26064642") == nil)
        #expect(ListeOCR.postcode("12100") == nil)
        #expect(ListeOCR.postcode("4210") == nil)
        #expect(ListeOCR.postcode("Gasse1210") == nil)
    }

    // MARK: - Where content corrects geometry

    /// One word crossing the column rule by a hair's width is what "Rudolf
    /// Schenkendorfgasse Zimmermann" looks like. A street name among the
    /// customer's name belongs to the address, and so does everything right of
    /// it.
    @Test func movesAStreetNameStrandedInTheCustomerColumn() {
        var page = plainPage {
            $0.row(stopp: 7, kd: "Maria Strasser", strasse: "Freytaggasse 2-14/31/1")
        }
        // The street, printed a shade to the left of where it belongs.
        for i in page.words.indices where page.words[i].text == "Freytaggasse" {
            page.words[i].x0 -= 0.020
            page.words[i].x1 -= 0.020
        }
        let stops = read(page)
        #expect(stops[0].kunde == "Maria Strasser")
        #expect(stops[0].strasse == "Freytaggasse 2-14/31/1")
    }

    /// The reference number printed beside the name is not part of it.
    @Test func keepsTheNameAndNotTheNumbersPrintedBesideIt() {
        let stops = read(
            plainPage {
                $0.row(
                    stopp: 7, kd: "S52714 Caritas der Erzdiözese Wien gem.",
                    strasse: "Axel-Corti-Gasse 12/3/1A")
            })
        #expect(stops[0].kunde == "Caritas der Erzdiözese Wien gem")
    }

    /// A house number with the street name missing off the front reads as a
    /// filled-in address and is not one. Nothing else here would catch it, and
    /// a geocoder handed "29/142/8" answers with whatever it likes.
    @Test func flagsAnAddressWithNoStreetNameInIt() {
        let stops = read(plainPage { $0.row(stopp: 7, kd: "Peter Holli", strasse: "29/142/8") })
        #expect(stops[0].strasse == "29/142/8")
        #expect(stops[0].problem == "Straßenname fehlt.")
    }

    @Test func flagsARowWithNoNameRatherThanDroppingIt() {
        let stops = read(
            plainPage { $0.row(stopp: 7, kd: "", strasse: "Nordmanngasse 27/1/6") })
        #expect(stops.count == 3)
        #expect(stops[0].problem == "Kein Name erkannt.")
    }

    /// `#NV` is the spreadsheet failing to look something up, printed onto the
    /// paper. As a delivery note it is worse than nothing.
    @Test func dropsSpreadsheetErrorValues() {
        let stops = read(
            plainPage {
                $0.row(
                    stopp: 7, kd: "Dagmar Fernbach", strasse: "Rittingergasse 48",
                    hinweis: "#NV")
            })
        #expect(stops[0].notiz == nil)
        #expect(stops[0].isUsable)
    }

    @Test func readsNothingOffAPageThatIsNotOneOfTheseLists() {
        #expect(ListeOCR.stops(in: []).isEmpty)
        #expect(
            ListeOCR.stops(in: [
                OCRWord(text: "Einkaufszettel", x0: 0.4, x1: 0.5, y0: 0.89, y1: 0.9)
            ]).isEmpty)
    }

    // MARK: - A stack of pages

    /// Six identical meals to one address is a real day on this tour — the
    /// Caritas block on page four is exactly that. Nothing may collapse them.
    @Test func keepsRepeatedDeliveriesToTheSameDoor() {
        var page = Page()
        page.header()
        for _ in 1...6 {
            page.row(
                kd: "Caritas der Erzdiözese Wien gem.", strasse: "Axel-Corti-Gasse 12/3/1A")
        }
        #expect(read(page).count == 6)
    }

    /// A page photographed twice is recognised as a whole page, because
    /// nothing about a single row can tell a duplicate from the Caritas block
    /// above.
    @Test func aPagePhotographedTwiceHasTheSameSignature() {
        let once = read(realPage())
        #expect(ListeOCR.signature(of: once) == ListeOCR.signature(of: read(realPage())))
        #expect(ListeOCR.signature(of: once).count == 6)

        let other = read(
            plainPage { $0.row(stopp: 7, kd: "Jemand Anderer", strasse: "Edergasse 4/1") })
        #expect(ListeOCR.signature(of: once) != ListeOCR.signature(of: other))
    }

    // MARK: - Handing over to the import

    /// What the review list produces has to be exactly what the JSON paste
    /// produces, because it goes through the same import — including "no
    /// Paket" being absent rather than an empty string.
    @Test func becomesAnImportEntry() {
        let stop = ScannedStop(
            kunde: "Odette BLAZEJOVSKY", strasse: "Haidschüttgasse 1/3/4/29",
            plz: "1210", paket: "1x Vitalmenü EP TGM5", notiz: "")
        let entry = stop.asJSON
        #expect(entry.kunde == "Odette BLAZEJOVSKY")
        #expect(entry.strasse == "Haidschüttgasse 1/3/4/29")
        #expect(entry.plz == "1210")
        #expect(entry.paket == "1x Vitalmenü EP TGM5")
        #expect(entry.notiz == nil)
    }

    /// A scanned list handed to the JSON editor has to come back out of it as
    /// the same list.
    @Test func survivesTheRoundTripThroughTheJSONEditor() throws {
        let stops = read(realPage())
        let text = RouteStore.exportJSON(stops.map(\.asJSON))
        let back = try RouteStore.parseImport(text)
        #expect(back == stops.map(\.asJSON))
    }
}
