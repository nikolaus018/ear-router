import SwiftData
import SwiftUI

/// One customer as the loading list shows them: a position in the van, a name,
/// an address, and how many parcels to grab.
///
/// Deliberately nothing about what is *in* the box — not the dishes. On a TK
/// tour every parcel has the customer's name printed on it, so the name is the
/// label, and a summed list of dish names is a line of half-cut text nobody
/// reads. But how many separate parcels a door is — the portal's own
/// `delivery_bundles` count, see `Stop.paketCount` — is exactly what the
/// driver needs to know they picked up all of them rather than three of four.
struct LadungStop: Identifiable, Hashable {
    let id: UUID
    /// Where this door's parcels go into the van: 1 is loaded first.
    let position: Int
    let name: String
    let address: String
    /// `nil` on a stop the portal never sent a bundle count for.
    let paketCount: Int?

    /// Namespaced so a tick here can never collide with a `PaketItem` key.
    /// Both modes share one tick store per tour, and a dish that happened to be
    /// spelled like a UUID is not the failure worth guarding against — a key
    /// that says what it is, is.
    var key: String { "stop:\(id.uuidString)" }
}

enum LadungPlan {
    /// The tour's customers in loading order: the last door first, so its
    /// parcels go in at the back of the van and come out last. First in, last
    /// out — the order the van is actually packed in, which is the reverse of
    /// the order it is emptied in.
    ///
    /// Built off `customerStops`, so it follows the driving order the tour
    /// screen shows rather than raw `orderIndex` — reversing a list that is not
    /// the list the driver reads would produce a van packed for a route nobody
    /// is driving.
    ///
    /// Without the abbestellt ones — see `Stop.isOwedAMeal`.
    static func loadingOrder(for route: Route) -> [LadungStop] {
        route.customerStops.filter(\.isOwedAMeal).reversed().enumerated().map { position, stop in
            let kunde = stop.kunde?.trimmed ?? ""
            return LadungStop(
                id: stop.id,
                position: position + 1,
                name: kunde.isEmpty ? "Stopp" : kunde,
                address: stop.listAddress,
                paketCount: stop.paketCount)
        }
    }
}

/// What one loading list is made of, in whichever of the two shapes this tour
/// takes. One value rather than two optional arrays: everything the screen does
/// afterwards — count the ticks, decide whether there is anything to show at
/// all — is the same question asked of both.
enum Ladung {
    case pakete([PaketItem])
    case kunden([LadungStop])

    var keys: [String] {
        switch self {
        case .pakete(let items): items.map(\.key)
        case .kunden(let stops): stops.map(\.key)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .pakete(let items): items.isEmpty
        case .kunden(let stops): stops.isEmpty
        }
    }
}

/// The packing checklist: what actually has to go into the van before setting
/// off, rather than a per-customer list nobody can load from.
///
/// On a VM tour that is every distinct package across the route's customer
/// stops, summed, busiest first. On a TK tour it is the customers, last door
/// first — the parcels carry their names, so what the driver needs from this
/// screen is the order to stack them in.
struct LadelisteView: View {
    let route: Route
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var checked: Set<String> = []
    @State private var mode: LadelisteMode = .vm

    /// The tick grows with the text, up to a point — the same rule and the same
    /// numbers as the delivery tick in `StopRow`, because it is the same gesture
    /// and should not be a different size on this screen.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    /// Written only from the picker, never from `load()`. Storing the guess the
    /// moment the screen opens would turn it into an override, and a tour
    /// renamed "TK1" afterwards would go on showing the list it was guessed
    /// into on the day nobody looked.
    private var modeBinding: Binding<LadelisteMode> {
        Binding(get: { mode }, set: { new in
            mode = new
            LadelisteState.store(new, for: route.id)
            // The mode decides whether the Paket is drawn anywhere, the lock
            // screen included — and it lives in `UserDefaults`, which the
            // `@Query` behind `LiveActivitySync` cannot see. Without this the
            // card keeps yesterday's answer until something else on the tour
            // changes.
            StopActivity.refresh(in: context)
        })
    }

    private func ladung(_ mode: LadelisteMode) -> Ladung {
        switch mode {
        case .vm: .pakete(PaketParser.items(for: route))
        case .tk: .kunden(LadungPlan.loadingOrder(for: route))
        }
    }

    var body: some View {
        // Parsed once per render. Read as a computed property it was re-parsed
        // for the `ForEach`, again for the progress line, and again for the
        // piece total — three regex passes over every stop on the route, every
        // time the driver ticked a box.
        let ladung = ladung(mode)

        return NavigationStack {
            VStack(spacing: 0) {
                // Above the list rather than in the toolbar or behind a menu:
                // which of the two lists this is changes what the numbers down
                // the left mean — a count of meals, or the order to stack them
                // in — so it has to be readable without opening anything.
                Picker("Tourart", selection: modeBinding) {
                    ForEach(LadelisteMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                Group {
                    if ladung.isEmpty {
                        // Outside the `List`, not a row inside it. As a row it
                        // rendered inset between separators, underneath a section
                        // header reporting "0 von 0 Positionen abgehakt" — a
                        // progress line about a list that does not exist.
                        empty
                    } else {
                        list(ladung)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle("Ladeliste")
            .navigationSubtitle(progressLabel(ladung))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // "Fertig" trailing, where every other sheet in this app — and
                // on this phone — puts it. It sat on the left, opposite every
                // one of them, which is the corner a driver's thumb goes to
                // for "Abbrechen".
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") {
                        checked.removeAll()
                        save()
                    }
                    .disabled(checked.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch mode {
        case .vm:
            ContentUnavailableView(
                "Keine Pakete", systemImage: "shippingbox",
                description: Text(
                    "Trag bei den Stopps im Feld „Paket“ ein, was mitkommt."))
        case .tk:
            ContentUnavailableView(
                "Keine Kunden", systemImage: "shippingbox",
                description: Text("Diese Tour hat noch keine Stopps."))
        }
    }

    @ViewBuilder
    private func list(_ ladung: Ladung) -> some View {
        List {
            switch ladung {
            case .pakete(let items):
                Section {
                    ForEach(items) { row($0) }
                } footer: {
                    Text("Tippen zum Abhaken. Die Haken gelten nur für diese Tour.")
                }
            case .kunden(let stops):
                Section {
                    ForEach(stops) { row($0) }
                } footer: {
                    Text(
                        "Von oben nach unten einladen: der letzte Kunde zuerst, "
                        + "damit er zuletzt wieder herauskommt. Was mitkommt, steht "
                        + "auf den Paketen — dort steht der Name drauf.")
                }
            }
        }
    }

    /// Wide enough for a two-digit count at whatever size the digits are drawn.
    @ScaledMetric(relativeTo: .title3) private var qtyWidth: CGFloat = 40

    private func row(_ item: PaketItem) -> some View {
        rowButton(key: item.key, number: item.qty) { on in
            Text(item.label)
                .font(.body.weight(.medium))
                .strikethrough(on)
                .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    private func row(_ stop: LadungStop) -> some View {
        rowButton(key: stop.key, number: stop.position) { on in
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name)
                    .font(.body.weight(.medium))
                    .strikethrough(on)
                    .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if let line = addressAndParcels(stop) {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The address and, when the portal sent one, the parcel count — on one
    /// line, the same way a stop row states its floor beside its address. A
    /// driver counting three boxes off the van against a door that says
    /// "3 Pakete" is the whole reason this is here.
    private func addressAndParcels(_ stop: LadungStop) -> String? {
        let parcels = stop.paketCount.map { $0 == 1 ? "1 Paket" : "\($0) Pakete" }
        // The on-screen form — see `Format.address`.
        switch (stop.address.isEmpty ? nil : Format.address(stop.address), parcels) {
        case (nil, nil): return nil
        case (let address?, nil): return address
        case (nil, let parcels?): return parcels
        case (let address?, let parcels?): return "\(address) · \(parcels)"
        }
    }

    /// The one row both lists are drawn with: a number down the left, the
    /// driver's own text in the middle, a tick on the right. The number means
    /// "how many" on a VM tour and "load this one nth" on a TK one — which is
    /// exactly why the picker sits where it cannot be missed.
    private func rowButton<Label: View>(
        key: String, number: Int, @ViewBuilder label: (Bool) -> Label
    ) -> some View {
        let on = checked.contains(key)
        return Button {
            toggle(key)
        } label: {
            HStack(spacing: 14) {
                Text("\(number)")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    // Scaled, not a fixed 40. The column holds `.title3` digits,
                    // which are half again as wide at an accessibility text
                    // size — so a van carrying twelve of something showed a
                    // clipped "1" where the count should be.
                    .frame(width: qtyWidth, alignment: .leading)

                label(on)

                Spacer(minLength: 8)

                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: min(27 * textScale, 38)))
                    .foregroundStyle(on ? Color.delivered : Color.secondary)
                    .frame(width: min(44 * textScale, 64), height: min(44 * textScale, 64))
            }
            .padding(.vertical, 4)
            // Without this the `Spacer` is a hole: only the two text runs and
            // the circle glyph itself were hit-testable, so ticking a line off
            // meant aiming at a 22pt target with a gap either side of it. The
            // whole row is the button now, which is how Reminders behaves and
            // what a driver loading a van one-handed actually needs.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func toggle(_ key: String) {
        if checked.contains(key) {
            checked.remove(key)
        } else {
            checked.insert(key)
        }
        save()
    }

    /// Counted from the items actually on screen, not from `checked.count` —
    /// the set can still hold a key from a package that has since been edited
    /// away, or from the other mode's list entirely, and "4 von 3 abgehakt" is
    /// a great way to lose a driver's trust in the whole list.
    /// Short enough for one line. It used to be a section header reading
    /// "0 von 2 Positionen abgehakt · 5 Stück gesamt", which wrapped onto two
    /// lines on a phone — and the words it spent that second line on ("
    /// Positionen", "gesamt") were the ones carrying no information. It sits
    /// under the screen's title now, the same place the tour's progress does.
    private func progressLabel(_ ladung: Ladung) -> String {
        let keys = ladung.keys
        guard !keys.isEmpty else { return "" }
        let done = keys.count { checked.contains($0) }
        switch ladung {
        case .pakete(let items):
            let pieces = items.reduce(0) { $0 + $1.qty }
            let total = pieces > 0 ? " · \(pieces) Stück" : ""
            if done >= keys.count { return "Alles abgehakt\(total)" }
            return "\(done) von \(keys.count) abgehakt\(total)"
        case .kunden:
            // No piece count here either — see `LadungStop`. A TK tour's
            // Ladeliste counts doors, because doors are what it loads by.
            if done >= keys.count { return "Alles geladen" }
            return "\(done) von \(keys.count) geladen"
        }
    }

    private func load() {
        checked = LadelisteState.checked(for: route.id)
        mode = .effective(for: route)
    }

    private func save() {
        LadelisteState.store(checked, for: route.id)
    }
}

struct PaketItem: Identifiable, Hashable {
    /// The case- and whitespace-insensitive identity used for grouping and for
    /// the tick state.
    let key: String
    /// The first spelling that appeared, so the list reads back in the
    /// driver's own words rather than a normalized one nobody wrote.
    let label: String
    var qty: Int

    var id: String { key }
}

enum PaketParser {
    private static let qtyX = try! NSRegularExpression(
        pattern: #"^(\d+)\s*[x×]\s*(.+)$"#, options: [.caseInsensitive])
    private static let qtySpace = try! NSRegularExpression(pattern: #"^(\d+)\s+(.+)$"#)

    /// Splits one stop's free-text `paket` field into counted items. Forgiving
    /// on purpose: it is a field a human types in a hurry.
    static func parse(_ paket: String?) -> [(qty: Int, label: String)] {
        guard let paket, !paket.isEmpty else { return [] }
        let parts = paket
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .flatMap { $0.components(separatedBy: " + ") }
            .map(\.trimmed)
            .filter { !$0.isEmpty }

        return parts.map { part in
            let range = NSRange(part.startIndex..., in: part)
            let m = qtyX.firstMatch(in: part, range: range)
                ?? qtySpace.firstMatch(in: part, range: range)
            guard let m,
                  let qtyStr = m.group(1, in: part), let qty = Int(qtyStr),
                  let label = m.group(2, in: part)?.trimmed
            else { return (1, part) }
            // A zero or absurd count, or a count with nothing left after it,
            // means the guess was wrong — keep the driver's original text.
            // Capped, because the counts are summed across a whole tour and a
            // pasted "9999999999999999999 x" would overflow `Int` and crash.
            return qty > 0 && qty <= 999 && !label.isEmpty ? (qty, label) : (1, part)
        }
    }

    /// The total number of pieces one stop is delivering — used to decide
    /// whether a Paket badge reads as "just one thing" or as a multi-item drop.
    static func totalQty(_ paket: String?) -> Int {
        parse(paket).reduce(0) { $0 + $1.qty }
    }

    /// Without the abbestellt ones — see `Stop.isOwedAMeal`.
    static func items(for route: Route) -> [PaketItem] {
        var byKey: [String: PaketItem] = [:]
        var order: [String] = []

        for stop in route.customerStops where stop.isOwedAMeal {
            for (qty, label) in parse(stop.paket) {
                let key = label.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                if var existing = byKey[key] {
                    existing.qty += qty
                    byKey[key] = existing
                } else {
                    byKey[key] = PaketItem(key: key, label: label, qty: qty)
                    order.append(key)
                }
            }
        }

        return order.compactMap { byKey[$0] }.sorted {
            $0.qty != $1.qty
                ? $0.qty > $1.qty
                : $0.label.compare($1.label, options: [], range: nil, locale: Locale(identifier: "de_AT")) == .orderedAscending
        }
    }
}
