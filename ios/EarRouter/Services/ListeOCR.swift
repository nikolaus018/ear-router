import Foundation
import Vision
import CoreImage
import OSLog

private let log = Logger(subsystem: "win.ringtwo.EarRouter", category: "ocr")

/// One word Vision read off a page, and where it sat on it.
///
/// Coordinates are Vision's own: normalized to the page, origin bottom left,
/// so a larger `y` is further *up* the page. Everything below is written
/// against this and nothing else, which is what lets the whole parse be tested
/// without a camera, a photograph or a device.
struct OCRWord: Sendable, Hashable {
    var text: String
    /// The word's box: left, right, bottom, top.
    var x0: Double
    var x1: Double
    var y0: Double
    var y1: Double
}

extension OCRWord {
    var xMid: Double { (x0 + x1) / 2 }
    var yMid: Double { (y0 + y1) / 2 }
    var width: Double { x1 - x0 }
    var height: Double { y1 - y0 }

    func shifted(x: Double = 0, y: Double = 0) -> OCRWord {
        var out = self
        out.x0 += x
        out.x1 += x
        out.y0 += y
        out.y1 += y
        return out
    }
}

/// One row read off a photographed tour list, before it becomes a stop.
///
/// Deliberately not a `CustomerJSON`: a scanned row can be incomplete in ways
/// a pasted entry cannot — a name the camera missed, a Bezirk the shadow of
/// the page edge fell across — and the review list has to be able to show and
/// correct exactly that. `asJSON` is where it becomes an import entry, once it
/// is good enough to be one.
struct ScannedStop: Identifiable, Sendable, Hashable {
    var id = UUID()
    var kunde: String
    var strasse: String
    var plz: String
    var paket: String?
    var notiz: String?
}

extension ScannedStop {
    var isUsable: Bool { problem == nil }

    /// What is wrong with the row, in the sentence the review list shows under
    /// it. Checked in the order the eye reads the columns, so the message
    /// names the leftmost thing to fix.
    var problem: String? {
        if kunde.isEmpty { return "Kein Name erkannt." }
        if strasse.isEmpty { return "Keine Straße erkannt." }
        if !strasse.contains(where: \.isLetter) { return "Straßenname fehlt." }
        if plz.isEmpty { return "Kein Bezirk erkannt." }
        if !Districts.isValid(plz) { return "„\(plz)“ ist kein Wiener Bezirk." }
        return nil
    }

    var asJSON: CustomerJSON {
        CustomerJSON(
            kunde: kunde, strasse: strasse, plz: plz,
            paket: paket?.nilIfEmpty, notiz: notiz?.nilIfEmpty)
    }
}

/// What one pass over a stack of photographed pages found.
struct ListeScanResult: Sendable {
    var stops: [ScannedStop] = []
    /// Pages — numbered as they were handed in — that produced nothing.
    /// Reported by number rather than counted, because the answer the driver
    /// needs is *which photo to take again*.
    var pagesWithoutTable: [Int] = []
}

/// Reads the printed tour list off a photo of it.
///
/// ## The shape of the problem
///
/// The page is one wide table — eleven columns, of which five matter: KD,
/// Straße, Plz, Paket, Hinweis. Two things make it hard, and both of them are
/// about *rows*, not about reading the letters:
///
/// - **A row is not a line.** Every column is narrow enough to wrap, so one
///   customer routinely occupies two or three printed lines — "Thomas" over
///   "Kaltenbacher", "Mühlschüttelgasse" over "55-57/6/5" — and a Hinweis can
///   run to three lines on its own while the cells beside it use one. Anything
///   that reads the page line by line tears customers in half and staples the
///   halves to their neighbours.
/// - **The page is never square to the camera.** It is photographed
///   one-handed on a van seat, so the text slopes and the columns lean. Over
///   the width of the table the slope alone is worth half a line — enough, by
///   itself, to put the right-hand end of one row into the row above it.
///
/// Vision's document reader has the same trouble: it finds the table, but its
/// cells cannot be trusted (the printed gutters are under a millimetre, so it
/// reads straight across them and hands back "26064642547179" glued to the
/// surname beside it), and its rows cut wrapped cells in half. So this takes
/// the words and their positions from Vision, and works out the table itself.
///
/// ## How
///
/// 1. **Square up the photograph** where Vision can find the sheet in it, so
///    that the page is a rectangle again before anything is read off it. This
///    is the only preparation the image gets, and the only one worth doing —
///    see `squared(_:)`.
/// 2. **Unglue.** Where the recogniser read across a column rule it leaves a
///    pipe behind. That is the one reliable mark of where a column ended.
/// 3. **Straighten**, in the two directions the lean has: the slope of the
///    text, found the way a document scanner finds it, and the sideways drift
///    of the columns, fitted through the postcodes.
/// 4. **Measure the line spacing**, so that everything downstream which has to
///    tell a wrapped line from the next row is counted in printed lines rather
///    than in guesses.
/// 5. **Find the rows**, which is the heart of it — and not by any of the
///    obvious means, all of which fail here. The table's cells are
///    bottom-aligned, so a row's Datum, KDNr., Parat and Plz all sit on its
///    *last* line and taller cells grow upwards from there. Each of those four
///    is unmistakable by content, and each is read as its own column so that
///    the page's tilt cancels out within it; matched up row by row they give
///    a line across the page saying where that row ends. See `rows(in:_:)`.
/// 6. **Find the columns** — clusters of word starts, each identified by what
///    is in it: a Vienna postcode, a "1x", a word ending in "-gasse", a date.
/// 7. **Read each row**, letting content correct geometry — a street name
///    found among the customer's name belongs to the address, a postcode found
///    in the address belongs to the Bezirk.
///
/// What this deliberately does *not* do is guess. A row whose postcode was
/// never read still comes back — with an empty Bezirk and a sentence saying so
/// — and the review list puts it in front of the driver rather than dropping a
/// delivery on the quiet.
enum ListeOCR {

    // MARK: - Reading

    /// Runs OCR over the pages in the order they were handed in.
    ///
    /// `onProgress` is called with `(done, total)` before each page. A page is
    /// a second or two of on-device work, and a stack of five behind a
    /// featureless spinner is long enough that a driver starts wondering
    /// whether it is stuck.
    ///
    /// A page that fails outright is recorded and the rest still run: one
    /// blurred photo out of five should cost that page, not the batch.
    ///
    /// `@MainActor` for the progress callback's sake, and it costs nothing:
    /// `perform` is a nonisolated `async` call, so the recognition itself hops
    /// straight off the main actor and only the parsing — a few milliseconds
    /// of arithmetic per page — runs here.
    @MainActor
    static func read(
        pages: [Data], onProgress: ((Int, Int) -> Void)? = nil
    ) async -> ListeScanResult {
        var request = RecognizeDocumentsRequest()
        // German, and no language correction. The list is nothing but Viennese
        // street names, surnames and package codes — "Mühlschüttelgasse",
        // "Ivkica Müllner", "DBMS5 (DIA)" — none of which are in any
        // dictionary, and all of which correction is only able to make worse.
        // The same reason every text field in this app has autocorrect off.
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        request.textRecognitionOptions.recognitionLanguages = [
            Locale.Language(identifier: "de-AT"),
            Locale.Language(identifier: "de-DE"),
        ]
        request.textRecognitionOptions.useLanguageCorrection = false
        // The words every row contains and a German recogniser has never seen.
        request.textRecognitionOptions.customWords = [
            "Vitalmenü", "Menü", "Stiege", "Bezirk", "Tür", "Stock", "vdt", "lfd",
        ]
        // Barcode detection is a second detector's worth of work on a page
        // that has no barcode on it.
        request.barcodeDetectionOptions.enabled = false

        var out = ListeScanResult()
        var seen = Set<[String]>()
        for (index, page) in pages.enumerated() {
            onProgress?(index, pages.count)

            let squared = await squared(page)
            var found = await read(squared ?? page, with: request)
            // A rectification that turned out to have squared up the wrong
            // quadrilateral is worth one more go at the photograph as it came.
            if found.isEmpty, squared != nil {
                found = await read(page, with: request)
            }
            guard !found.isEmpty else {
                out.pagesWithoutTable.append(index + 1)
                continue
            }
            // The same page photographed twice — the retake of the one that
            // came out blurred, still sitting in the camera roll beside it.
            // Compared as whole pages rather than row by row, because a tour
            // really does deliver six identical meals to one address, and no
            // comparison of one row against another can tell those from a
            // duplicate. Two reads of one page agree on all of it, or they are
            // not the same page.
            guard seen.insert(signature(of: found)).inserted else { continue }
            out.stops.append(contentsOf: found)
        }
        return out
    }

    private static func read(
        _ page: Data, with request: RecognizeDocumentsRequest
    ) async -> [ScannedStop] {
        do {
            return stops(in: try await request.perform(on: page).flatMap(words(in:)))
        } catch {
            log.error("page failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Squares up a photographed page before it is read.
    ///
    /// The one piece of preparation worth doing to the image, and the one
    /// Vision does not already do for you. Exposure, contrast and noise the
    /// recogniser handles itself, and better than a filter can: running
    /// Apple's own `CIDocumentEnhancer` over these pages first measurably made
    /// things *worse*, turning "Nordmanngasse" into "Nardmanneassel" by eating
    /// the thin strokes it would otherwise have read. What it does not undo is
    /// the *shape* of the page. A sheet photographed at an angle is a
    /// trapezium, its far edge smaller and its rows sloping, and squaring that
    /// up fixed every single difference it made on a real page:
    /// "Mühischüttelgasse" became "Mühlschüttelgasse", "onauelde Straße"
    /// became "Donaufelder Straße", "11•11.45" became "11-11.45".
    ///
    /// Applied only when what Vision found actually looks like a page. On
    /// three of four real photographs the detector came back with a
    /// quadrilateral two and a half times wider than a sheet of A4 — a slice
    /// of car seat, or half the page and the shadow beside it — and squaring
    /// the list up to *that* stretches it into something nothing can read.
    /// Checking the shape costs nothing; reading the page twice to find out
    /// costs a second and a half.
    private static func squared(_ page: Data) async -> Data? {
        // Oriented the way Vision reads it, so the quadrilateral it hands back
        // describes the same picture this is about to cut up.
        guard let image = CIImage(data: page, options: [.applyOrientationProperty: true]),
              let document = try? await DetectDocumentSegmentationRequest().perform(on: page)
        else { return nil }

        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        func point(_ p: NormalizedPoint) -> CGPoint {
            p.toImageCoordinates(size, origin: .lowerLeft)
        }
        let topLeft = point(document.topLeft), topRight = point(document.topRight)
        let bottomLeft = point(document.bottomLeft), bottomRight = point(document.bottomRight)

        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
        let width = (distance(topLeft, topRight) + distance(bottomLeft, bottomRight)) / 2
        let height = (distance(topLeft, bottomLeft) + distance(topRight, bottomRight)) / 2
        guard height > 0 else { return nil }
        // A4 is 1.41 either way up. The slack is for a page whose far edge ran
        // off the top of the frame; anything outside it is not a page.
        guard (0.55...1.95).contains(width / height),
              (width * height) / (size.width * size.height) > 0.45
        else { return nil }

        let corrected = image.applyingFilter(
            "CIPerspectiveCorrection",
            parameters: [
                "inputTopLeft": CIVector(cgPoint: topLeft),
                "inputTopRight": CIVector(cgPoint: topRight),
                "inputBottomLeft": CIVector(cgPoint: bottomLeft),
                "inputBottomRight": CIVector(cgPoint: bottomRight),
            ])
        // 0.95, for the same reason the scanner saves at 0.9: the smallest
        // text on the page is the Hinweis column at about 7pt, and JPEG
        // artefacts around characters that small are the difference between
        // "vdt" and "vdl".
        return CIContext().jpegRepresentation(
            of: corrected, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
    }

    /// A page's words and their boxes — the whole of this file's dependency on
    /// Vision's shape, and the seam the parse below is tested through.
    ///
    /// Words, not lines and not table cells. A recognised *line* runs straight
    /// across the printed column rules and a table *cell* is wrong about where
    /// those rules are; a word is the largest piece of this page that is
    /// reliably one thing.
    static func words(in observation: DocumentObservation) -> [OCRWord] {
        let text = observation.document.text
        let recognised = text.words ?? observation.document.paragraphs.flatMap { $0.words ?? [] }
        return recognised.map { word in
            let xs = [word.topLeft.x, word.topRight.x, word.bottomLeft.x, word.bottomRight.x]
                .map(Double.init)
            let ys = [word.topLeft.y, word.topRight.y, word.bottomLeft.y, word.bottomRight.y]
                .map(Double.init)
            return OCRWord(
                text: word.transcript,
                x0: xs.min() ?? 0, x1: xs.max() ?? 0,
                y0: ys.min() ?? 0, y1: ys.max() ?? 0)
        }
    }

    // MARK: - The parse

    /// Reads the customer rows off one page's words.
    nonisolated static func stops(in words: [OCRWord]) -> [ScannedStop] {
        let straight = columnDriftRemoved(from: levelled(words.flatMap(unpiped)))
        let leading = lineSpacing(of: straight)
        let bands = rows(in: withoutHeadings(straight, leading: leading), leading: leading)

        guard var columns = ColumnModel(straight), !bands.isEmpty else { return [] }
        columns.hinweis = hinweisEdge(in: bands, after: columns.paket) ?? columns.hinweis
        return bands.compactMap { stop(from: $0, columns: columns, leading: leading) }
    }

    // MARK: - Ungluing

    /// Splits a word OCR glued together across a column rule.
    ///
    /// The rule itself is read as a pipe — "26064642547179|Kaltenbacher",
    /// "Müllner|15/6" — which makes it the one reliable marker of where one
    /// column ended and the next began. The box is shared out by character
    /// count, which is close enough in a printed table for each half to land
    /// on its own side of the boundary.
    nonisolated static func unpiped(_ word: OCRWord) -> [OCRWord] {
        let parts = word.text.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return [word] }
        let total = Double(word.text.count)
        var out: [OCRWord] = []
        var offset = 0.0
        for part in parts {
            let start = word.x0 + offset / total * word.width
            let width = Double(part.count) / total * word.width
            offset += Double(part.count) + 1
            guard !part.isEmpty else { continue }
            var piece = word
            piece.text = String(part)
            piece.x0 = start
            piece.x1 = start + width
            out.append(piece)
        }
        return out.isEmpty ? [word] : out
    }

    // MARK: - Straightening the page

    /// Takes out the sideways drift of the columns.
    ///
    /// Fitted through the postcodes: the one column with exactly one short,
    /// unmistakable entry on every single row, and therefore the one that
    /// describes the page's lean and nothing else. Left in, the drift is worth
    /// more than a column's width down the height of a sheet — enough for the
    /// bottom of the page to read as though every field had shifted one column
    /// to the left.
    nonisolated static func columnDriftRemoved(from words: [OCRWord]) -> [OCRWord] {
        let anchors = words.filter { postcode($0.text) != nil }
        guard anchors.count >= 3, let pivot = median(anchors.map(\.yMid)),
              let drift = slope(of: anchors.map { (along: $0.yMid, across: $0.x0) }),
              abs(drift) < 0.4
        else { return words }
        return words.map { $0.shifted(x: -drift * ($0.yMid - pivot)) }
    }

    /// Takes out the slope of the text.
    ///
    /// Vision hands back an upright box for every word however the page was
    /// held, so the slope cannot be read off any single word — and it cannot
    /// be fitted from the rows either, because finding the rows is what needs
    /// the page level in the first place.
    ///
    /// So it is found the way a document scanner finds it, and has since long
    /// before any of this was on a phone: try each candidate angle, project
    /// every word onto the vertical, and keep the angle whose projection is
    /// spikiest. Level text stacks into a few tall peaks, one per printed
    /// line; sloped text smears those peaks into each other. Summing the
    /// squares of the bin counts is what "spiky" means here, and it needs no
    /// prior idea of where the rows are.
    ///
    /// Worth half a line of text across the width of this table, which is
    /// enough on its own to put the Hinweis at the end of one row into the row
    /// above it.
    nonisolated static func levelled(_ words: [OCRWord]) -> [OCRWord] {
        guard words.count >= 8, let pivot = median(words.map(\.xMid)) else { return words }
        let height = median(words.map(\.height).filter { $0 > 0 }) ?? 0.01
        // A quarter of the text's own height: fine enough to tell two printed
        // lines apart, coarse enough that a word sitting a hair proud of its
        // line still lands in the same bin as the rest.
        let bin = height * 0.25

        var best = (slope: 0.0, score: 0)
        // Wide enough for a sheet of paper held carelessly, in steps small
        // enough that the worst rounding error left is a fifth of a bin.
        for step in -80...80 {
            let slope = Double(step) * 0.001
            var histogram: [Int: Int] = [:]
            for word in words {
                let y = word.yMid - slope * (word.xMid - pivot)
                histogram[Int((y / bin).rounded()), default: 0] += 1
            }
            let score = histogram.values.reduce(0) { $0 + $1 * $1 }
            if score > best.score { best = (slope, score) }
        }
        guard best.slope != 0 else { return words }
        return words.map { $0.shifted(y: -best.slope * ($0.xMid - pivot)) }
    }

    /// Least squares, for the column-drift fit above.
    private nonisolated static func slope(
        of samples: [(along: Double, across: Double)]
    ) -> Double? {
        let n = Double(samples.count)
        guard n >= 3 else { return nil }
        let meanAlong = samples.map(\.along).reduce(0, +) / n
        let meanAcross = samples.map(\.across).reduce(0, +) / n
        var covariance = 0.0, variance = 0.0
        for s in samples {
            covariance += (s.along - meanAlong) * (s.across - meanAcross)
            variance += (s.along - meanAlong) * (s.along - meanAlong)
        }
        guard variance > 1e-9 else { return nil }
        return covariance / variance
    }

    /// The distance from one printed line to the next.
    ///
    /// Measured rather than assumed, because it is the unit that everything
    /// separating a wrapped line from the next row is expressed in, and it
    /// depends entirely on how close the driver was standing.
    ///
    /// Taken as the lower quartile of the gaps between printed lines: on a
    /// page like this roughly half those gaps are wrapped lines inside a cell
    /// and half are the step from one row to the next, so the quartile lands
    /// squarely on the first kind. Then held to within a sane multiple of the
    /// text's own height — on a page where no cell happens to wrap *every* gap
    /// is a row step, and believing that measurement would fuse the whole page
    /// into a single row.
    nonisolated static func lineSpacing(of words: [OCRWord]) -> Double {
        let height = median(words.map(\.height).filter { $0 > 0 }) ?? 0.01
        let floor = height * 1.15
        let ceiling = height * 2.2

        var lines: [Double] = []
        for centre in words.map(\.yMid).sorted(by: >) {
            if let last = lines.last, last - centre < height * 0.45 { continue }
            lines.append(centre)
        }
        let gaps = zip(lines, lines.dropFirst()).map(-).filter { $0 > 0 }.sorted()
        guard gaps.count >= 4 else { return min(max(height * 1.5, floor), ceiling) }
        return min(max(gaps[gaps.count / 4], floor), ceiling)
    }

    /// A set of words split into the printed lines they sit on.
    private nonisolated static func lines(in words: [OCRWord], leading: Double) -> [[OCRWord]] {
        var out: [[OCRWord]] = []
        for word in words.sorted(by: { $0.yMid > $1.yMid }) {
            if let head = out.last?.first, head.yMid - word.yMid < leading * 0.5 {
                out[out.count - 1].append(word)
            } else {
                out.append([word])
            }
        }
        return out
    }

    // MARK: - Finding the rows

    /// Drops the column headings.
    ///
    /// They print once, at the top of the first page, and they sit close
    /// enough above the first delivery to be swept up with it — where they
    /// read as a customer called "KDNr Parat KD" living at "Straße Plz". The
    /// rows below cannot exclude them on geometry alone: a heading is one line
    /// above the first row's top line, which is exactly where that row's own
    /// wrapped second line would be.
    ///
    /// Dropped a whole line at a time rather than word by word, because
    /// "Straße" on its own is a column heading *and* half of "Donaufelder
    /// Straße". A line of a delivery carries names, addresses and numbers; a
    /// line of headings carries nothing else.
    nonisolated static func withoutHeadings(
        _ words: [OCRWord], leading: Double
    ) -> [OCRWord] {
        lines(in: words, leading: leading)
            .filter { line in
                let headings = line.count { isColumnHeading($0.text) }
                return !(headings >= 3 && headings * 2 >= line.count)
            }
            .flatMap { $0 }
    }

    private nonisolated static let columnHeadings: Set<String> = [
        "tour", "stopp", "referenzbeleg", "datum", "kdnr", "parat", "kd",
        "straße", "strasse", "plz", "paket", "hinweis",
    ]

    private nonisolated static func isColumnHeading(_ text: String) -> Bool {
        columnHeadings.contains(
            text.trimmingCharacters(in: CharacterSet.letters.inverted).lowercased())
    }

    /// The last printed line of one row — as a line *across* the page, not as
    /// a single height.
    ///
    /// It has to be a line, because a photographed page is never flat. The
    /// camera's perspective tilts each printed row, and by different amounts
    /// down the page: on a real photograph of this list the Bezirk sits a full
    /// printed line lower than the Datum on the same row at the top of the
    /// sheet, and level with it at the bottom. No single number describes
    /// where such a row ends, and no single shear straightens the page,
    /// because the tilt itself changes as you go down it. A row that knows its
    /// own slope needs neither.
    struct RowBaseline: Sendable {
        var intercept: Double
        var slope: Double

        func height(at x: Double) -> Double { intercept + slope * x }
    }

    /// Groups a page's words into the rows they are printed in.
    ///
    /// This is the hard part, and the obvious ways to do it are all wrong.
    /// Grouping by line fails because a row is two or three lines. Grouping by
    /// the gap between lines fails because there isn't one: on this list the
    /// step from the last line of one row to the first line of the next is
    /// *the same* as the step between two wrapped lines inside a cell —
    /// measured at 0.013 against 0.014 on a real page, which is no signal at
    /// all. Grouping by nearest row centre fails on exactly the rows that
    /// matter most: a tall row's three-line Hinweis reaches up past the
    /// halfway mark and gets handed to the row above, so the customer with the
    /// most delivery instructions is the one whose instructions go missing.
    ///
    /// What does work is a fact about how the table is *typeset*: its cells
    /// are bottom-aligned. Whatever else a row contains, the Datum, the KDNr.,
    /// the Parat and the Plz all sit on its **last** line, and a taller cell
    /// beside them grows upwards. Those four are also unmistakable by content
    /// — a date, eight digits, six digits, a Vienna postcode — so every row
    /// announces where it ends, four times over, and a row is everything
    /// between the line below the previous announcement and its own.
    ///
    /// A row is capped at four lines tall as well. Without it the first row
    /// would swallow the column headings and the date printed above the table,
    /// there being no announcement further up the page to stop it.
    nonisolated static func rows(in words: [OCRWord], leading: Double) -> [[OCRWord]] {
        let ends = footerBaselines(in: words, leading: leading)
        guard !ends.isEmpty else { return [] }

        var out: [[OCRWord]] = []
        for (i, end) in ends.enumerated() {
            let row = words.filter { word in
                let bottom = end.height(at: word.xMid) - leading * 0.6
                let ceiling = end.height(at: word.xMid) + leading * 3.0
                let top = i == 0
                    ? ceiling
                    : min(ends[i - 1].height(at: word.xMid) - leading * 0.6, ceiling)
                return word.yMid > bottom && word.yMid <= top
            }
            if !row.isEmpty { out.append(row) }
        }
        return out
    }

    /// Where each row ends, in the order the rows come down the page.
    ///
    /// The four markers are read as four separate *columns* rather than as one
    /// heap of heights, and that is the whole trick. Within a column the page's
    /// tilt cancels out — every Datum on the page is at the same x, so their
    /// heights can be compared directly however the sheet was held — while a
    /// Datum and a Bezirk on the same row cannot be. So each column is ordered
    /// on its own, the columns are matched up row by row, and only then is a
    /// line drawn through each row's four markers to give the slope that row
    /// is printed at.
    ///
    /// A row whose Datum the camera missed is still found by its Bezirk, and
    /// one that lost both by its two customer numbers. All four would have to
    /// fail together for a delivery to go missing.
    nonisolated static func footerBaselines(
        in words: [OCRWord], leading: Double
    ) -> [RowBaseline] {
        let columns: [[OCRWord]] = [
            words.filter { isDate($0.text) },
            words.filter { isCustomerNumber($0.text) },
            words.filter { isParatNumber($0.text) },
            words.filter { postcode($0.text) != nil },
        ]
        .map { $0.sorted { $0.yMid > $1.yMid } }
        .filter { $0.count >= 2 }

        guard let spineIndex = columns.indices.max(by: { columns[$0].count < columns[$1].count })
        else { return [] }
        let spine = columns[spineIndex]
        let pitch = median(zip(spine, spine.dropFirst()).map { $0.yMid - $1.yMid })
            ?? leading * 3

        var rows: [[OCRWord]] = spine.map { [$0] }
        var unmatched: [OCRWord] = []
        for (i, column) in columns.enumerated() where i != spineIndex {
            for word in column {
                let nearest = rows.indices.min {
                    abs(rows[$0][0].yMid - word.yMid) < abs(rows[$1][0].yMid - word.yMid)
                }
                // Half a row apart is the most a marker on the same row can be,
                // even on a badly tilted page. Further than that and it belongs
                // to a row the spine column never saw.
                guard let nearest, abs(rows[nearest][0].yMid - word.yMid) < pitch * 0.5 else {
                    unmatched.append(word)
                    continue
                }
                rows[nearest].append(word)
            }
        }
        // Rows the spine column missed entirely, recovered from the markers
        // that were left over.
        for word in unmatched.sorted(by: { $0.yMid > $1.yMid }) {
            if let last = rows.last, let head = last.first,
               abs(head.yMid - word.yMid) < pitch * 0.5, rows.count > spine.count {
                rows[rows.count - 1].append(word)
            } else {
                rows.append([word])
            }
        }

        // The slope most of this page's rows are printed at, for the rows that
        // have too few markers left to say anything about their own.
        let fitted = rows.compactMap { $0.count >= 3 ? baseline(through: $0) : nil }
        let typical = median(fitted.map(\.slope)) ?? 0

        return rows
            .map { row in
                row.count >= 3
                    ? baseline(through: row) ?? RowBaseline(
                        intercept: row[0].yMid - typical * row[0].xMid, slope: typical)
                    : RowBaseline(intercept: row[0].yMid - typical * row[0].xMid, slope: typical)
            }
            .sorted { $0.height(at: 0.5) > $1.height(at: 0.5) }
    }

    /// A least-squares line through one row's markers.
    private nonisolated static func baseline(through row: [OCRWord]) -> RowBaseline? {
        let n = Double(row.count)
        let meanX = row.map(\.xMid).reduce(0, +) / n
        let meanY = row.map(\.yMid).reduce(0, +) / n
        var covariance = 0.0, variance = 0.0
        for word in row {
            covariance += (word.xMid - meanX) * (word.yMid - meanY)
            variance += (word.xMid - meanX) * (word.xMid - meanX)
        }
        guard variance > 1e-9 else { return nil }
        let slope = covariance / variance
        // A row is printed level to within a few degrees of the page. Anything
        // steeper is two markers that were never on the same row.
        guard abs(slope) < 0.15 else { return nil }
        return RowBaseline(intercept: meanY - slope * meanX, slope: slope)
    }

    /// Where the Hinweis column starts: the leftmost thing on a row, right of
    /// the Paket column, that is not part of a Paket.
    ///
    /// Measured per row and then medianed rather than over the page at once.
    /// A Hinweis is a sentence, and the *insides* of one are scattered across
    /// the whole width of the column — page-wide, they drag the answer far to
    /// the right of where the column actually begins. Only the first word of
    /// each row's Hinweis says anything about the edge.
    nonisolated static func hinweisEdge(in rows: [[OCRWord]], after paket: Double) -> Double? {
        median(
            rows.compactMap { row in
                row.filter { $0.x0 > paket + 0.01 && !isPaketWord($0.text) }.map(\.x0).min()
            })
    }

    // MARK: - Finding the columns

    /// Where each column of the printed list starts.
    ///
    /// Every edge is measured from a landmark that is unmistakable by content
    /// — a Vienna postcode, a "1x", a word ending in "-gasse", a date — and
    /// taken as a median over the whole page, so one badly read row cannot
    /// move a column. Each is then rounded onto the nearest cluster of word
    /// starts, because an edge that twenty words agree on is a better number
    /// than the median of the four that happened to match a pattern.
    struct ColumnModel: Sendable {
        var datum: Double
        var strasse: Double
        var plz: Double
        var paket: Double
        var hinweis: Double

        /// A hair's width of slack on every boundary. These columns are
        /// printed hard against each other, and a letter that starts two
        /// thousandths of a page-width left of a measured edge is on the same
        /// side of the rule as the rest of its word.
        static let slack = 0.005

        /// Where the Straße column gives way to the Paket. Measured from the
        /// midpoint rather than from the Paket's own edge because the Plz
        /// column between them is narrow and right-aligned, so its left edge
        /// moves about — and a "1x" that starts a whisker early would
        /// otherwise read as part of the postcode.
        var paketStart: Double { (plz + paket) / 2 }

        init?(_ words: [OCRWord]) {
            // Without a street and a "1x" somewhere on the page, this is not
            // one of these lists and no amount of geometry will make it one.
            guard let streetMark = median(words.filter { isStreetName($0.text) }.map(\.x0)),
                  let paketMark = median(words.filter { isQuantity($0.text) }.map(\.x0))
            else { return nil }

            let edges = ColumnModel.edges(of: words)
            let strasseEdge = ColumnModel.snap(streetMark, to: edges)
            let paketEdge = ColumnModel.snap(paketMark, to: edges)
            strasse = strasseEdge
            paket = paketEdge
            // Filled in once the rows are known — see `hinweisEdge(in:after:)`.
            // Until then, everything right of the Paket is Paket.
            hinweis = 1
            datum = median(words.filter { isDate($0.text) }.map(\.x0))
                .map { ColumnModel.snap($0, to: edges) } ?? 0
            plz = median(words.compactMap { postcode($0.text) != nil ? $0.x0 : nil })
                ?? (strasseEdge + paketEdge) / 2
        }

        /// The left edges of the page's columns, as the clusters that the
        /// words' starting positions fall into.
        private static func edges(of words: [OCRWord]) -> [Double] {
            var edges: [Double] = []
            var group: [Double] = []
            for x in words.map(\.x0).sorted() {
                if let last = group.last, x - last > 0.012 {
                    if group.count >= 3, let m = median(group) { edges.append(m) }
                    group = []
                }
                group.append(x)
            }
            if group.count >= 3, let m = median(group) { edges.append(m) }
            return edges
        }

        private static func snap(_ x: Double, to edges: [Double]) -> Double {
            guard let nearest = edges.min(by: { abs($0 - x) < abs($1 - x) }),
                  abs(nearest - x) < 0.02
            else { return x }
            return nearest
        }
    }

    // MARK: - Reading one row

    /// Turns one printed row into a stop, letting content correct geometry
    /// wherever the two disagree.
    private nonisolated static func stop(
        from row: [OCRWord], columns: ColumnModel, leading: Double
    ) -> ScannedStop? {
        let slack = ColumnModel.slack
        var rest = row.filter { $0.x0 >= columns.datum }

        // --- the Bezirk ---
        // Taken from wherever on the row it actually landed rather than from
        // the Plz column, and searched from the street rightwards so that an
        // eight-digit customer number can never be read as one. Where the rule
        // beside that narrow column is faint the postcode joins the street
        // cell, or runs into the menu code beside it as "1210TGMS5" — and
        // looking for it only where it was supposed to be is how a delivery
        // ends up with no Bezirk at all.
        var plz = ""
        let candidates = rest.indices.filter {
            rest[$0].x0 >= columns.strasse - slack && postcode(rest[$0].text) != nil
        }
        if let index = candidates.min(by: {
            abs(rest[$0].x0 - columns.plz) < abs(rest[$1].x0 - columns.plz)
        }) {
            plz = postcode(rest[index].text) ?? ""
            // Whatever was glued to it stays where it was.
            let remainder = withoutPostcode(rest[index].text)
            if remainder.isEmpty {
                rest.remove(at: index)
            } else {
                rest[index].text = remainder
            }
        }

        // --- the columns, as the page's geometry has them ---
        var kunde = rest.filter { $0.x0 >= columns.datum && $0.x0 < columns.strasse - slack }
        var strasse = rest.filter {
            $0.x0 >= columns.strasse - slack && $0.x0 < columns.paketStart
        }
        var paket = rest.filter {
            $0.x0 >= columns.paketStart && $0.x0 < columns.hinweis - slack
        }
        var notiz = rest.filter { $0.x0 >= columns.hinweis - slack }

        // --- and where the content says otherwise ---
        // A street name among the customer's name is a boundary in the wrong
        // place for this row: the page leans, the columns are printed hard
        // against each other, and "Rudolf Schenkendorfgasse Zimmermann" is
        // what one word crossing that line by a hair's width looks like. The
        // street name and everything right of it belong to the address.
        if let street = kunde.filter({ isStreetName($0.text) }).map(\.x0).min() {
            strasse += kunde.filter { $0.x0 >= street }
            kunde.removeAll { $0.x0 >= street }
        }
        // A Paket that reads as empty while the Hinweis beside it opens with
        // "1x Vitalmenü" is the same mistake at the other end of the row.
        if paket.isEmpty {
            let run = notiz.sorted { $0.x0 < $1.x0 }.prefix { isPaketWord($0.text) }
            if run.contains(where: { isQuantity($0.text) }) {
                paket = Array(run)
                notiz.removeAll { word in paket.contains(word) }
            }
        }

        let stop = ScannedStop(
            kunde: names(in: kunde, leading: leading),
            strasse: street(in: strasse, leading: leading),
            plz: plz,
            paket: joined(paket, leading: leading).nilIfEmpty,
            notiz: cleanNote(joined(notiz, leading: leading)))

        // A row carrying neither a postcode nor a street name is not a
        // delivery: it is the column headings, or the date printed above the
        // table, or the page number below it. A row missing only *one* of the
        // two is a delivery whose other half the camera lost, and is reported
        // as one rather than dropped.
        guard row.contains(where: { postcode($0.text) != nil || isStreetName($0.text) })
        else { return nil }
        return stop
    }

    // MARK: - Reading the words in a cell

    /// A cell's words as one string, in reading order: down the page, then
    /// across. A narrow column wraps, and "Mühlschüttelgasse" above
    /// "55-57/6/5" is one address just as "Thomas" above "Kaltenbacher" is one
    /// name.
    ///
    /// The tolerance on the line is what keeps two words on the *same* printed
    /// line from being ordered by the fraction of a millimetre their baselines
    /// differ by.
    nonisolated static func joined(_ words: [OCRWord], leading: Double) -> String {
        words
            .sorted {
                abs($0.yMid - $1.yMid) > leading * 0.4 ? $0.yMid > $1.yMid : $0.x0 < $1.x0
            }
            .map(\.text)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            // A column rule read as a character of its own. It is not text,
            // and left in it becomes a stray "|" in the middle of a Paket.
            .filter { $0 != "|" && $0 != "l" && $0 != "I" }
            .joined(separator: " ")
    }

    /// The Straße cell, with the postcode taken back off the end of it.
    ///
    /// Belt and braces: the Bezirk is lifted off the row before the columns
    /// are cut, but a postcode the recogniser ran into a *preceding* word
    /// would survive that, and "Leopoldauer Straße 68/2/4/18 1210" is an
    /// address no geocoder will place.
    private nonisolated static func street(in words: [OCRWord], leading: Double) -> String {
        var parts = joined(words, leading: leading).split(separator: " ").map(String.init)
        if let last = parts.last, postcode(last) != nil { parts.removeLast() }
        return parts.joined(separator: " ")
    }

    /// The Kunde cell, which sits between two columns of long numbers that OCR
    /// routinely runs into it. Anything that is not a name is dropped.
    private nonisolated static func names(in words: [OCRWord], leading: Double) -> String {
        let cleaned = words.compactMap { word -> OCRWord? in
            let trimmed = word.text
                .drop { !$0.isLetter }
                .trimmingCharacters(in: CharacterSet(charactersIn: "|/\\-—_:;,."))
            guard trimmed.count >= 2 else { return nil }
            // Half letters or better. This is what tells a surname from the
            // reference number printed beside it — "Kaltenbacher" survives,
            // "S52714" does not.
            let letters = trimmed.count { $0.isLetter }
            guard letters * 2 >= trimmed.count else { return nil }
            var out = word
            out.text = trimmed
            return out
        }
        return joined(cleaned, leading: leading)
    }

    /// The spreadsheet's own error values, which print onto the paper and mean
    /// nothing to a driver. Left in, "#NV" becomes a delivery note.
    private nonisolated static func cleanNote(_ text: String) -> String? {
        let junk: Set<String> = ["#NV", "#N/A", "#WERT!", "#REF!", "#NAME?", "INV", "ENV"]
        return text.split(separator: " ")
            .filter { !junk.contains($0.uppercased()) }
            .joined(separator: " ")
            .nilIfEmpty
    }

    // MARK: - Assembling the stack

    /// What makes two reads of a page the same page: everything it says. Not
    /// the ids, which are fresh on every read and would make every page
    /// unique.
    nonisolated static func signature(of stops: [ScannedStop]) -> [String] {
        stops.map {
            [$0.kunde, $0.strasse, $0.plz, $0.paket ?? "", $0.notiz ?? ""]
                .joined(separator: "\u{1}")
        }
    }

    // MARK: - What the columns look like

    /// Vienna's streets are unusually regular about how they end, which makes
    /// the Straße column the easiest one on the page to find by content alone.
    private nonisolated static let streetSuffix = try! NSRegularExpression(
        pattern: #"(gasse|stra(ß|ss)e|weg|platz|ring|allee|zeile|hof|markt|ufer|steig"#
            + #"|damm|promenade|siedlung|br(ü|ue)cke|park|lände|kai)$"#,
        options: [.caseInsensitive])

    /// The suffix has to be *on* something. Bare "Straße" is the column
    /// heading printed at the top of page one, not an address, and letting it
    /// through turned that header into a delivery.
    nonisolated static func isStreetName(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard word.count >= 6,
              let match = streetSuffix.firstMatch(
                in: word, range: NSRange(word.startIndex..., in: word))
        else { return false }
        return match.range.length < word.utf16.count
    }

    /// A Vienna postcode at the start of a word.
    ///
    /// Written to tolerate what the column rule beside that narrow cell does
    /// to it: read as part of the menu code that follows ("1210TGMS5"), or
    /// with the rule itself picked up in front as a bracket ("[1210"). Both
    /// happen on a real page, and both used to cost a delivery its Bezirk.
    /// What it will never do is take four digits out of the middle of a longer
    /// number.
    nonisolated static func postcode(_ text: String) -> String? {
        let word = text.drop { !$0.isNumber && !$0.isLetter }
        let digits = word.prefix { $0.isNumber }
        guard digits.count == 4, Districts.isValid(String(digits)) else { return nil }
        guard word.dropFirst(4).first?.isNumber != true else { return nil }
        return String(digits)
    }

    /// What is left of a word once its postcode is taken out of it — the menu
    /// code that ran into it, and nothing if that was the whole word.
    nonisolated static func withoutPostcode(_ text: String) -> String {
        let word = text.drop { !$0.isNumber && !$0.isLetter }
        return String(word.dropFirst(4))
    }

    /// "1x", "2x" — and the ways a recogniser renders a printed 1 when it is
    /// not sure: "Ix", "lx".
    nonisolated static func isQuantity(_ text: String) -> Bool {
        let word = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "|[(."))
        guard word.count >= 2, word.hasSuffix("x") else { return false }
        return word.dropLast().allSatisfy { "0123456789il".contains($0) }
    }

    /// Whether a word belongs to a Paket rather than to the Hinweis beside it:
    /// the quantity, the product, and the menu codes ("TGM5", "DBMS7", "DIA",
    /// "LVK").
    nonisolated static func isPaketWord(_ text: String) -> Bool {
        if isQuantity(text) { return true }
        let word = text.trimmingCharacters(in: CharacterSet(charactersIn: "|[]()., "))
        let lower = word.lowercased()
        if lower.hasPrefix("vitalmen") || lower == "menü" || lower == "menu" || lower == "ep" {
            return true
        }
        guard (2...7).contains(word.count) else { return false }
        return word.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// The Datum column: one per row, single line, unmistakable.
    nonisolated static func isDate(_ text: String) -> Bool {
        text.count >= 8 && text.count { $0.isNumber } >= 6 && text.count { $0 == "." } >= 2
    }

    /// The KDNr. column: eight digits, one per row.
    nonisolated static func isCustomerNumber(_ text: String) -> Bool {
        text.count == 8 && text.allSatisfy(\.isNumber)
    }

    /// The Parat column: six digits, one per row.
    nonisolated static func isParatNumber(_ text: String) -> Bool {
        text.count == 6 && text.allSatisfy(\.isNumber)
    }

    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
