import SwiftData
import UIKit

/// The tour as the sheet of paper the Lager hands out: A4 across, the day
/// above the table, one row a door, "Seite 1 von 4" underneath.
///
/// Laid out after that printed list on purpose — blue header on the first page
/// only, every other row tinted, the text sitting on the bottom line of its
/// cell — because that is the list everybody at the ramp already reads. The
/// columns are the ones this app has something to put in: the paper's
/// Referenzbeleg, KDNr. and Parat are numbers the portal never sends here, and
/// the floor is one the paper never had.
///
/// Read off the store and stores nothing, like `TourReport`.
struct TourPDF {
    /// One door, as the table prints it.
    struct Row: Equatable {
        let number: Int
        let kunde: String
        let strasse: String
        let plz: String
        /// From the Globale Infos: the floor alone, not the note kept with it.
        let stockwerk: String
        let paket: String
        let hinweis: String
    }

    let routeName: String
    let day: Date
    let rows: [Row]

    /// The customers in driving order, without the abbestellt ones — see
    /// `Stop.isOwedAMeal`.
    @MainActor
    init(_ route: Route) {
        routeName = route.name
        day = route.completedAt ?? route.createdAt

        let customers = route.orderedStops.filter(\.isOwedAMeal)
        let notes = route.modelContext.flatMap { try? StockwerkStore.all(in: $0) } ?? []
        let floors = notes.floors(for: customers)
        rows = customers.enumerated().map { index, stop in
            Row(
                number: index + 1,
                kunde: stop.kunde?.trimmed ?? "",
                strasse: stop.strasse?.trimmed ?? "",
                plz: stop.plz?.trimmed ?? "",
                stockwerk: floors[stop.id].map(Format.floor) ?? "",
                paket: stop.displayPaket?.trimmed ?? "",
                hinweis: stop.notiz?.trimmed ?? "")
        }
    }
}

// MARK: - Drawing

extension TourPDF {
    private struct Column {
        let title: String
        let width: CGFloat
        var bold = false
        var alignment: NSTextAlignment = .left
    }

    /// A4 across, in points.
    private static let page = CGRect(x: 0, y: 0, width: 842, height: 595)
    private static let left: CGFloat = 40
    private static let top: CGFloat = 62
    private static let bottom: CGFloat = 540
    private static let padding: CGFloat = 3
    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 34

    private static let columns = [
        Column(title: "Tour", width: 62, bold: true),
        Column(title: "Stopp", width: 40, bold: true, alignment: .right),
        Column(title: "Datum", width: 66, bold: true),
        Column(title: "KD", width: 104),
        Column(title: "Straße", width: 126),
        Column(title: "Plz", width: 36, alignment: .right),
        Column(title: "Stock", width: 54),
        Column(title: "Paket", width: 120, bold: true),
        Column(title: "Hinweis", width: 154, bold: true),
    ]
    private static let width = columns.reduce(0) { $0 + $1.width }

    private static let headerBlue = UIColor(red: 68 / 255, green: 114 / 255, blue: 196 / 255, alpha: 1)
    private static let band = UIColor(red: 217 / 255, green: 225 / 255, blue: 242 / 255, alpha: 1)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_AT")
        f.dateFormat = "EEEE, dd.MM.yyyy"
        return f
    }()

    private static func text(
        _ string: String, bold: Bool = false, size: CGFloat = 10,
        color: UIColor = .black, alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return NSAttributedString(string: string, attributes: [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    private static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(
            with: CGSize(width: width - 2 * padding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    /// On the bottom line of the cell, the way the printed list sets it.
    private static func draw(_ text: NSAttributedString, in cell: CGRect) {
        let h = min(height(text, width: cell.width), cell.height - 2 * padding)
        text.draw(
            with: CGRect(
                x: cell.minX + padding, y: cell.maxY - padding - h,
                width: cell.width - 2 * padding, height: h),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    private func cells(_ row: Row) -> [NSAttributedString] {
        let values = [
            routeName, "\(row.number)", Format.numericDate(day),
            row.kunde, row.strasse, row.plz, row.stockwerk, row.paket, row.hinweis,
        ]
        return zip(Self.columns, values).map {
            Self.text($1, bold: $0.bold, alignment: $0.alignment)
        }
    }

    /// The rows of each page with their heights. A row is never split
    /// across two.
    private func pages() -> [[(row: Int, height: CGFloat)]] {
        var pages: [[(row: Int, height: CGFloat)]] = [[]]
        var y = Self.top + Self.headerHeight
        for (index, row) in rows.enumerated() {
            let height = zip(Self.columns, cells(row)).reduce(Self.rowHeight) {
                max($0, Self.height($1.1, width: $1.0.width) + 2 * Self.padding)
            }
            if y + height > Self.bottom, !pages[pages.count - 1].isEmpty {
                pages.append([])
                y = Self.top
            }
            pages[pages.count - 1].append((index, height))
            y += height
        }
        return pages
    }

    func data() -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: routeName]
        let pages = pages()
        let dayTitle = Self.text(Self.dayFormatter.string(from: day), size: 9, alignment: .center)

        return UIGraphicsPDFRenderer(bounds: Self.page, format: format).pdfData { context in
            let cg = context.cgContext

            for (pageIndex, lines) in pages.enumerated() {
                context.beginPage()
                dayTitle.draw(in: CGRect(x: 0, y: 36, width: Self.page.width, height: 14))
                Self.text("Seite \(pageIndex + 1) von \(pages.count)", size: 9, alignment: .center)
                    .draw(in: CGRect(x: 0, y: 552, width: Self.page.width, height: 14))

                // Fills first, then one grid over all of it, then the text.
                // Drawn row by row, each row's tint covered half of the line
                // above it, and the header — filled but never outlined — came
                // out a line's width narrower than the table under it.
                let hasHeader = pageIndex == 0
                var edges = [Self.top]
                if hasHeader { edges.append(Self.top + Self.headerHeight) }
                for (_, height) in lines { edges.append(edges[edges.count - 1] + height) }
                let first = hasHeader ? 1 : 0

                if hasHeader {
                    Self.headerBlue.setFill()
                    cg.fill(CGRect(x: Self.left, y: Self.top, width: Self.width, height: Self.headerHeight))
                }
                Self.band.setFill()
                for (offset, line) in lines.enumerated() where line.row.isMultiple(of: 2) {
                    cg.fill(CGRect(
                        x: Self.left, y: edges[first + offset],
                        width: Self.width, height: line.height))
                }

                UIColor.black.setStroke()
                cg.setLineWidth(0.75)
                for y in edges {
                    cg.move(to: CGPoint(x: Self.left, y: y))
                    cg.addLine(to: CGPoint(x: Self.left + Self.width, y: y))
                }
                var x = Self.left
                for column in [nil] + Self.columns.map(Optional.some) {
                    x += column?.width ?? 0
                    cg.move(to: CGPoint(x: x, y: edges[0]))
                    cg.addLine(to: CGPoint(x: x, y: edges[edges.count - 1]))
                }
                cg.setLineCap(.square)
                cg.strokePath()

                x = Self.left
                for (index, column) in Self.columns.enumerated() {
                    if hasHeader {
                        let title = Self.text(column.title, bold: true, color: .white, alignment: .center)
                        let h = Self.height(title, width: column.width)
                        title.draw(in: CGRect(
                            x: x + Self.padding, y: Self.top + (Self.headerHeight - h) / 2,
                            width: column.width - 2 * Self.padding, height: h))
                    }
                    for (offset, line) in lines.enumerated() {
                        Self.draw(
                            cells(rows[line.row])[index],
                            in: CGRect(
                                x: x, y: edges[first + offset],
                                width: column.width, height: line.height))
                    }
                    x += column.width
                }
            }
        }
    }

    /// "VM 5 FR Vormittag 09.10.2026.pdf".
    var filename: String {
        let name = routeName.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let dated = name.contains(Format.numericDate(day)) ? name : "\(name) \(Format.numericDate(day))"
        return "\(dated.trimmed.isEmpty ? "Tour" : dated.trimmed).pdf"
    }

    /// Written to a temporary file for the share sheet. The directory is
    /// emptied first, for the reason `BackupArchive.writeForSharing` gives.
    func writeForSharing() throws -> URL {
        let fm = FileManager.default
        let dir = URL.temporaryDirectory.appending(path: "TourPDF", directoryHint: .isDirectory)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: filename)
        try data().write(to: url, options: .atomic)
        return url
    }
}
