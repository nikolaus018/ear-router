import Foundation
import SwiftData

/// Which kind of tour this is — which decides what a packing list can usefully
/// say, and whether the Paket field is worth showing at all.
///
/// On a Vormittag round every stop carries the same handful of menu codes
/// ("1x Vitalmenü EP TGM5"), so what loads the van is those codes, summed: nine
/// TGM7, five DLM7, two DBM5. On a Tiefkühl round every stop carries its own
/// basket of dishes, near enough unique per customer and with the customer's
/// name printed on the parcel — summing those produces thirty one-off lines
/// nobody counts, off text the portal has usually already cut off mid-word.
/// There, what loads the van is the customers themselves, in reverse — and the
/// same fact that makes the loading list a list of names makes the Paket field
/// noise on every other screen too. See `Stop.displayPaket`.
enum LadelisteMode: String, CaseIterable, Identifiable {
    /// Pakete, summed across the tour.
    case vm
    /// Kunden, last door first.
    case tk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vm: "VM"
        case .tk: "TK"
        }
    }

    /// The mode a tour opens in, read off its name.
    ///
    /// A guess, and deliberately only a guess: it decides nothing the driver
    /// cannot see and flip in one tap. The names arrive from the
    /// Zusteller-Portal already — "Tk1", "TK1", "VM 4 DO Vormittag" — so the
    /// prefix is how the round is called on paper, which makes it the one thing
    /// about a tour that is reliably about what goes in the van.
    static func suggested(for route: Route) -> LadelisteMode {
        route.name.trimmed.lowercased().hasPrefix("tk") ? .tk : .vm
    }
}

/// Which lines of a route's packing list are ticked off, and which of the two
/// lists it is showing.
///
/// In `UserDefaults` rather than on the model: a tick here means "already in the
/// van this morning", which is about one loading, not about the tour as a
/// record. It lives outside SwiftData, though, which means nothing cascades it
/// away — so deleting a route has to say so explicitly, or every tour ever
/// deleted leaves its checklist behind in the app's preferences for good.
enum LadelisteState {
    private static func key(_ routeID: UUID) -> String {
        "ladeliste.\(routeID.uuidString)"
    }

    private static func modeKey(_ routeID: UUID) -> String {
        "ladeliste.mode.\(routeID.uuidString)"
    }

    static func checked(for routeID: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(routeID)) ?? [])
    }

    static func store(_ checked: Set<String>, for routeID: UUID) {
        UserDefaults.standard.set(Array(checked), forKey: key(routeID))
    }

    /// The mode the driver picked for this tour, or `nil` if they never picked
    /// one. Absent rather than defaulted on purpose: a tour nobody has switched
    /// by hand should keep following its name, including after a rename.
    static func mode(for routeID: UUID) -> LadelisteMode? {
        UserDefaults.standard.string(forKey: modeKey(routeID))
            .flatMap(LadelisteMode.init(rawValue:))
    }

    static func store(_ mode: LadelisteMode, for routeID: UUID) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey(routeID))
    }

    static func forget(_ routeID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(routeID))
        UserDefaults.standard.removeObject(forKey: modeKey(routeID))
    }
}

extension LadelisteMode {
    /// The mode in force for a tour: the driver's pick if they made one, the
    /// guess from the name otherwise. The one place that question is answered,
    /// because it is now asked from every screen that draws a stop.
    static func effective(for route: Route) -> LadelisteMode {
        LadelisteState.mode(for: route.id) ?? .suggested(for: route)
    }
}

extension Stop {
    /// The Paket as the app should *show* it — `nil` on a TK tour.
    ///
    /// On a TK round the parcels carry the customer's name, so the Paket field
    /// decides nothing at any door: it is a line of half-cut dish names on
    /// every row, in Jetzt, on the map, on the lock screen and in what Siri
    /// reads out. Hiding it is a display rule and only a display rule — the
    /// field is untouched on the stop, still edited in `StopEditorSheet`, still
    /// exported, still imported, still summed for the VM loading list.
    ///
    /// A stop with no route cannot be asked which kind of tour it is on, and
    /// answers as VM: showing the field is the harmless half of being wrong.
    var displayPaket: String? {
        if let route, LadelisteMode.effective(for: route) == .tk { return nil }
        return paket
    }
}
