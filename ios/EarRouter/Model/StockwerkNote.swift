import Foundation
import SwiftData

/// What this app knows about one customer, kept for good and across every tour:
/// which floor they live on, and whatever else the driver wrote down.
///
/// Still called `StockwerkNote` because that is the entity name the store on
/// the driver's phone was written with, and renaming an entity is a custom
/// migration rather than a rename. The floor was the first thing anybody kept
/// here and gave the table its name; `CustomerInfo` is what the rest of the app
/// calls the shape of it now.
///
/// The floor is the one thing about a delivery that never changes and that no
/// list the office sends ever carries. A driver learns it once, standing in the
/// stairwell, and then has to remember it — for every customer on every tour,
/// forever. That is what this is: the app asks once, and from then on the
/// answer is on the row before the van has stopped.
///
/// Deliberately *not* a property of `Stop`. A stop belongs to one tour and is
/// deleted with it; the same customer comes back on tomorrow's list as a new
/// row, and would be asked about again. This is keyed by the customer and their
/// address together, so it outlives every route that ever visits them.
@Model
final class StockwerkNote {
    var id: UUID = UUID()

    /// `StockwerkKey.make` — the customer and their address in the form that
    /// survives being re-exported by a different system. Not
    /// `@Attribute(.unique)`: uniqueness is enforced by going through
    /// `StockwerkStore`, which reads the row before it writes one, and that is
    /// also the path a merged import takes. A unique attribute would do it as a
    /// silent upsert instead, which is the same answer for a write that is
    /// correct and a much quieter one for a write that is not.
    var key: String = ""

    /// Kept for the entries list — a key is a comparison form
    /// ("fam gruber|gentzgasse 129 1|1180"), not something to show a driver.
    var kunde: String = ""
    var strasse: String = ""
    var plz: String = ""

    /// What the driver typed: "3", "EG", "2/Tür 14". Free text on purpose —
    /// Viennese stairwells are numbered in more ways than a picker could hold,
    /// and a wrong choice from a list is worse than the right words.
    var stockwerk: String?

    /// Everything else worth knowing about this customer, in the driver's own
    /// words: "klingelt nicht, klopfen", "Türcode 0123", "Hund", "Nachbarin
    /// Tür 12 nimmt an", "Lift seit Mai kaputt".
    ///
    /// Free text, and deliberately only free text. Each of those was briefly a
    /// field of its own here — a Türcode column, a "lange läuten" switch — and
    /// that was the wrong shape: it is a list with no end, every entry on it is
    /// a sentence somebody would write anyway, and a form of eight labelled
    /// boxes is slower to fill in at a door than one line to type into.
    ///
    /// The same argument as the floor, which this file already makes: a thing
    /// that does not change, that no list the office sends carries, and that a
    /// driver otherwise has to hold in their head for every customer on every
    /// tour forever. `Stop.notiz` is not the place for it — a stop belongs to
    /// one tour and is deleted with it, so a note typed there is gone by Monday.
    var notiz: String?

    /// Set when the driver ticked "Nicht mehr fragen". The one thing worse than
    /// not knowing the floor is being asked after every single delivery to a
    /// customer where the question makes no sense — a house, a Kleingarten, a
    /// shop on the street.
    var dontAsk: Bool = false

    var updatedAt: Date = Date()

    init(
        key: String, kunde: String, strasse: String, plz: String,
        stockwerk: String? = nil, notiz: String? = nil, dontAsk: Bool = false
    ) {
        self.id = UUID()
        self.key = key
        self.kunde = kunde
        self.strasse = strasse
        self.plz = plz
        self.stockwerk = stockwerk
        self.notiz = notiz
        self.dontAsk = dontAsk
        self.updatedAt = Date()
    }
}

extension StockwerkNote {
    /// What the entries list puts on the row: the customer, falling back to
    /// their address when a stop carried no name at all.
    var title: String {
        kunde.isEmpty ? (strasse.isEmpty ? "—" : strasse) : kunde
    }

    var subtitle: String {
        let address = kunde.isEmpty ? "" : strasse
        return [address, plz].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Nothing known and no standing instruction — a row that is only taking up
    /// space, and which `StockwerkStore` deletes rather than storing blank.
    ///
    /// Both fields, not just the floor. Clearing the floor on a customer whose
    /// note is the only thing anybody ever learned about them used to be the
    /// write that threw the note away.
    var isBlank: Bool {
        (stockwerk?.trimmed.isEmpty ?? true)
            && (notiz?.trimmed.isEmpty ?? true)
            && !dontAsk
    }
}

/// How a customer is identified across tours.
enum StockwerkKey {
    /// The customer *and* their address — not the address alone.
    ///
    /// Two households in one Gemeindebau are the case this app already goes out
    /// of its way to support: one front door, one ring of the bell, two meals
    /// carried up. They do not live on the same floor. Keyed by address alone,
    /// the first floor learned would be shown for both of them, and the second
    /// answer would overwrite the first — so the customer is part of the key.
    ///
    /// Everything runs through `AddressText.matchKey`, which is what makes the
    /// key survive the trip: it folds ß/ä/ö/ü, collapses punctuation and case,
    /// and unifies the spellings of "straße". "Fam. Gruber" and "Fam Gruber"
    /// are one customer; "Gentzgasse 129/1" and "Gentzgasse 129 / 1" are one
    /// address. The postcode is in it because Vienna has a Hauptstraße in
    /// several districts.
    ///
    /// A stop with no name still gets a key — the address on its own — so a
    /// list that carries only addresses is not silently unaskable.
    static func make(kunde: String?, strasse: String?, plz: String?) -> String? {
        let street = AddressText.matchKey(strasse ?? "")
        guard !street.isEmpty else { return nil }
        let customer = AddressText.matchKey(kunde ?? "")
        return "\(customer)|\(street)|\(plz?.trimmed ?? "")"
    }

    static func make(for stop: Stop) -> String? {
        make(kunde: stop.kunde, strasse: stop.strasse, plz: stop.plz)
    }
}
