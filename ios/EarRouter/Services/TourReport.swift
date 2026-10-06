import Foundation

/// What the driver has to be able to say about a tour once it is over.
///
/// Until now the end of a shift left the app with nothing to report from: a
/// count of ticks, and no way to tell a delivered meal from a door nobody
/// opened, no times, and no sentence anybody could send anywhere. So the report
/// was written on paper or dictated over the phone, out of memory, an hour
/// later.
///
/// Everything here is read off stops that are already in the store — this
/// invents nothing and stores nothing. It exists so the same day is described
/// the same way on the screen and in the message that leaves the phone.
struct TourReport {
    let routeName: String
    let day: Date
    /// When the first and last doors were answered for. `nil` on a tour driven
    /// before stops carried a time, which is every tour already on the phone.
    let firstStop: Date?
    let lastStop: Date?
    let customerCount: Int
    let deliveredCount: Int
    let neighbourCount: Int
    let cancelledCount: Int
    let lagerCount: Int
    /// The doors nobody opened, in driving order. The part of the report that
    /// is actually read.
    let notHome: [Entry]
    /// Customers still owed a meal because the driver never got to them — a
    /// tour closed early, or closed by mistake.
    let stillOpen: [Entry]
    let km: Double
    /// The odometer difference, when the driver has been keeping it. Not the
    /// same number as `km`: OSRM measures the planned route and the van
    /// measures what it actually drove, including the wrong turn in Floridsdorf.
    let odometerKm: Double?

    /// One customer, flattened out of the store so a report can be built,
    /// shared and tested without holding model objects.
    struct Entry: Equatable, Sendable {
        let name: String
        let address: String
        let telefon: String?
        let at: Date?
    }

    /// Meals that left the van, by either route.
    var handedOverCount: Int { deliveredCount + neighbourCount }

    /// Whether the tour's name already says which day it was — "Tour
    /// 24.09.2026", the default. Then the day is not written a second time,
    /// in a second format, right beside it.
    var nameShowsDay: Bool { routeName.contains(Format.numericDate(day)) }

    /// Meals owed: every customer but the abbestellt ones — the figure the
    /// tour's own header counts against.
    var owedCount: Int { customerCount - cancelledCount - lagerCount }

    /// Whether anything on this tour needs somebody's attention today.
    var needsAttention: Bool { !notHome.isEmpty || !stillOpen.isEmpty }

    init(_ route: Route, snapshot: RouteSnapshot? = nil, odometerKm: Double? = nil) {
        let snapshot = snapshot ?? RouteSnapshot(route)
        routeName = route.name
        day = route.completedAt ?? route.createdAt

        var delivered = 0, neighbour = 0, cancelled = 0, lager = 0
        var notHome: [Entry] = []
        var stillOpen: [Entry] = []
        var times: [Date] = []

        for stop in snapshot.ordered where stop.kind == .customer {
            // Not abbestellt: that tick is usually made in the yard before the
            // tour, and it started the day's time span there.
            if let at = stop.settledAt, stop.outcome?.skipsDoor != true { times.append(at) }
            switch stop.outcome {
            case .delivered: delivered += 1
            case .neighbour: neighbour += 1
            case .cancelled: cancelled += 1
            case .toLager: lager += 1
            case .notHome: notHome.append(Entry(stop))
            case nil: stillOpen.append(Entry(stop))
            }
        }

        customerCount = snapshot.customerCount
        deliveredCount = delivered
        neighbourCount = neighbour
        cancelledCount = cancelled
        lagerCount = lager
        self.notHome = notHome
        self.stillOpen = stillOpen
        km = snapshot.totalKm
        self.odometerKm = odometerKm
        // Sorted rather than taken from the ends of the list: ticks are not
        // always made in driving order, and the first and last *times* are what
        // the shift actually ran between.
        times.sort()
        firstStop = times.first
        lastStop = times.last
    }
}

extension TourReport.Entry {
    init(_ stop: Stop) {
        self.init(
            name: stop.kunde?.trimmed.nilIfEmpty ?? "Ohne Namen",
            address: stop.listAddress,
            telefon: stop.telefon?.trimmed.nilIfEmpty,
            at: stop.settledAt)
    }
}

// MARK: - The message that leaves the phone

extension TourReport {
    /// The report as plain text, ready for WhatsApp, a mail or the clipboard.
    ///
    /// Plain text on purpose. Whatever the office reads it in — a phone, a mail
    /// client, a printout taped to a clipboard — plain text arrives looking the
    /// way it left, and it is the one format every one of those can quote back.
    ///
    /// Ordered the way somebody reading it needs it: what happened, then who
    /// still needs something done about them, then the numbers. The names come
    /// before the kilometres because nobody has ever rung about the kilometres.
    var text: String {
        var lines: [String] = []
        lines.append(nameShowsDay ? routeName : "\(routeName) — \(Format.date(day))")

        if let span = timeSpan { lines.append(span) }
        lines.append("")

        // The same arithmetic as the tour's header: every meal that left the
        // van, against the meals owed. Counted off all customers, with the
        // neighbour's meals left out of it, the report said "1 von 8" of a day
        // the screen had just called "2 von 6 geliefert".
        lines.append("Geliefert: \(handedOverCount) von \(Format.stops(owedCount))")
        if neighbourCount > 0 { lines.append("davon bei Nachbarn abgegeben: \(neighbourCount)") }
        if cancelledCount > 0 { lines.append("Abbestellt: \(cancelledCount)") }
        if lagerCount > 0 { lines.append("Ins Lager mitgenommen: \(lagerCount)") }

        if !notHome.isEmpty {
            lines.append("")
            lines.append("Nicht angetroffen (\(notHome.count)):")
            lines.append(contentsOf: notHome.map { "· \($0.line)" })
        }

        if !stillOpen.isEmpty {
            lines.append("")
            lines.append("Nicht angefahren (\(stillOpen.count)):")
            lines.append(contentsOf: stillOpen.map { "· \($0.line)" })
        }

        lines.append("")
        if let planned = Format.km(km) { lines.append("Strecke laut Planung: \(planned)") }
        if let odometerKm, let driven = Format.km(odometerKm) {
            lines.append("Laut Tacho: \(driven)")
        }
        return lines.joined(separator: "\n")
    }

    /// "07:12 – 11:48 (4 h 36 min)", or nothing at all on a tour with no times
    /// recorded — which is every tour driven before stops carried one.
    var timeSpan: String? {
        guard let firstStop, let lastStop else { return nil }
        let span = "\(Format.time(firstStop)) – \(Format.time(lastStop))"
        let minutes = lastStop.timeIntervalSince(firstStop) / 60
        guard minutes >= 1, let duration = Format.minutes(minutes) else { return span }
        return "\(span) (\(duration))"
    }
}

extension TourReport.Entry {
    /// "Fam. Gruber, Gentzgasse 129/1, 1180 · 0664 1234567" — everything needed
    /// to ring somebody about this customer, on one line.
    var line: String {
        var out = name
        if !address.isEmpty { out += ", \(address)" }
        if let telefon { out += " · \(telefon)" }
        return out
    }
}
