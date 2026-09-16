import Foundation

/// Everything worth knowing about a tour *before* the van leaves the yard.
///
/// Every failure this app can have is cheap in the depot and expensive in a
/// Gemeindebau courtyard in Floridsdorf with one bar of signal: an address the
/// geocoder never resolved, a route that was never optimised, a note nobody
/// read, a floor nobody has been asked about. Each of those is already visible
/// somewhere in the app, on four different screens, to a driver who would have
/// to think to go looking. This is the one screen that asks the questions
/// unprompted, at the one moment they can all still be answered.
///
/// Pure, and reads nothing but the route and what is already known about its
/// doors, so the whole checklist can be tested without a network or a store.
struct Preflight {
    let findings: [Finding]

    /// Whether anything here should stop a driver setting off. Nothing in this
    /// app actually blocks them — it is their van and their round — but the
    /// difference between "look at this" and "this is fine" is the difference
    /// between a checklist that gets read and one that gets swiped past.
    var isReady: Bool { !findings.contains { $0.severity == .problem } }

    var problems: [Finding] { findings.filter { $0.severity == .problem } }

    enum Severity: Comparable {
        /// Settled, and shown so the driver can see it was checked rather than
        /// skipped. A checklist of only bad news teaches nobody anything.
        case ok
        /// Worth knowing, not worth waiting for.
        case note
        /// Fix it here, or know that you are choosing not to.
        case problem
    }

    struct Finding: Identifiable, Equatable {
        let id: String
        let severity: Severity
        let symbol: String
        let title: String
        let detail: String?
        /// What the driver can do about it without leaving this screen, when
        /// there is anything.
        let action: Action?

        enum Action: Equatable {
            case optimize
            case recheckAddresses
            case resetDelivered
            case openLadeliste
        }
    }

    /// `floorsKnown` is the set of stop ids whose customer's floor this app has
    /// already been told, passed in rather than fetched so this stays pure —
    /// the caller has the notes from its own query anyway.
    init(route: Route, snapshot: RouteSnapshot, floorsKnown: Set<UUID>) {
        var findings: [Finding] = []

        if snapshot.customerCount == 0 {
            findings.append(
                Finding(
                    id: "empty", severity: .problem, symbol: "tray",
                    title: "Keine Stopps",
                    detail: "Lade die Tour vom Zusteller-Portal oder füg Stopps von Hand dazu.",
                    action: nil))
            self.findings = findings
            return
        }

        let customers = snapshot.ordered.filter { $0.kind == .customer }

        // 1. Is the plan current at all?
        if route.needsOptimize || route.geometryFlat.isEmpty {
            findings.append(
                Finding(
                    id: "optimize", severity: .problem,
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Route nicht aktuell",
                    detail: "Die Reihenfolge und die Kilometer stimmen noch nicht.",
                    action: .optimize))
        } else {
            findings.append(
                Finding(
                    id: "optimize", severity: .ok, symbol: "checkmark.circle",
                    title: "Route ist optimiert",
                    detail: Format.leg(km: snapshot.totalKm, minutes: snapshot.totalMinutes)
                        .map { "\($0) Fahrzeit" },
                    action: nil))
        }

        // 2. Pins the van cannot actually be driven to.
        let approximate = customers.filter { $0.precision != nil && !$0.pinned }
        if approximate.isEmpty {
            findings.append(
                Finding(
                    id: "pins", severity: .ok, symbol: "mappin.circle",
                    title: "Alle Adressen gefunden", detail: nil, action: nil))
        } else {
            findings.append(
                Finding(
                    id: "pins", severity: .problem, symbol: "exclamationmark.triangle.fill",
                    title: "\(approximate.count) ungenaue \(approximate.count == 1 ? "Adresse" : "Adressen")",
                    detail: approximate.prefix(3).compactMap(\.kunde).joined(separator: ", "),
                    action: .recheckAddresses))
        }

        // 3. A tour still carrying yesterday's ticks.
        //
        // The one that looks like nothing and costs the most: a driver who sets
        // off on a list where half the doors are already struck through skips
        // them, and finds out at four o'clock.
        let alreadySettled = customers.count(where: \.isSettled)
        if alreadySettled > 0 {
            findings.append(
                Finding(
                    id: "settled", severity: alreadySettled == customers.count ? .problem : .note,
                    symbol: "checkmark.circle.badge.xmark",
                    title: "\(alreadySettled) \(alreadySettled == 1 ? "Stopp ist" : "Stopps sind") schon abgehakt",
                    detail: "Wenn das von gestern ist, setz den Lieferstatus zurück.",
                    action: .resetDelivered))
        }

        // 4. What goes in the van — counted the way this tour is loaded.
        //
        // A TK tour is loaded by door, so its pieces are not counted anywhere:
        // the parcels carry the customers' names. Reporting "38 Positionen" and
        // then opening a Ladeliste that lists sixteen customers was two answers
        // to one question.
        switch LadelisteMode.effective(for: route) {
        case .vm:
            let pieces = customers.reduce(0) { $0 + PaketParser.totalQty($1.paket) }
            if pieces > 0 {
                findings.append(
                    Finding(
                        id: "ladung", severity: .note, symbol: "shippingbox.fill",
                        title: "\(pieces) \(pieces == 1 ? "Position" : "Positionen") einladen",
                        detail: "Die Ladeliste hat sie aufgeschlüsselt.",
                        action: .openLadeliste))
            }
        case .tk:
            let doors = customers.count
            if doors > 0 {
                findings.append(
                    Finding(
                        id: "ladung", severity: .note, symbol: "shippingbox.fill",
                        title: "\(doors) \(doors == 1 ? "Kunde" : "Kunden") einladen",
                        detail: "Die Ladeliste zählt sie rückwärts auf — letzter Kunde zuerst.",
                        action: .openLadeliste))
            }
        }

        // 5. Doors that want reading before the bell, not after it.
        let notes = customers.count { !($0.notiz?.trimmed.isEmpty ?? true) }
        if notes > 0 {
            findings.append(
                Finding(
                    id: "notizen", severity: .note, symbol: "note.text",
                    title: "\(notes) \(notes == 1 ? "Notiz" : "Notizen") auf der Tour",
                    detail: "Stehen auf den Zeilen — vor dem Läuten lesen.",
                    action: nil))
        }

        // 6. Stairwells nobody has been up yet. A note rather than a problem:
        // it is the normal state of a new customer, and the app asks on its own
        // at the door. It is here because a stand-in driver on somebody else's
        // round wants to know it is twelve and not one.
        let unknownFloors = customers.count { !floorsKnown.contains($0.id) }
        if unknownFloors > 0 {
            findings.append(
                Finding(
                    id: "stockwerke", severity: .note, symbol: "stairs",
                    title: "\(unknownFloors) \(unknownFloors == 1 ? "Stockwerk" : "Stockwerke") unbekannt",
                    detail: "Die App fragt an der Tür danach.",
                    action: nil))
        }

        // Worst first, and ties in the order they were worked out above.
        //
        // `sorted(by:)` makes no promise about equal elements, and this list is
        // rebuilt on every draw of the screen: a checklist whose four "note"
        // rows shuffle between two renders of the same tour is one a driver
        // stops reading. The index is what makes the order an order.
        self.findings = findings.enumerated()
            .sorted {
                $0.element.severity != $1.element.severity
                    ? $0.element.severity > $1.element.severity
                    : $0.offset < $1.offset
            }
            .map(\.element)
    }
}
