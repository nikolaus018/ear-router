import SwiftUI

/// Which kind of tour the van is being loaded for — which decides what a
/// packing list can usefully say.
///
/// On a Vormittag round every stop carries the same handful of menu codes
/// ("1x Vitalmenü EP TGM5"), so what loads the van is those codes, summed: nine
/// TGM7, five DLM7, two DBM5. On a Tiefkühl round every stop carries its own
/// basket of dishes, near enough unique per customer and with the customer's
/// name printed on the parcel — summing those produces thirty one-off lines
/// nobody counts, off text the portal has usually already cut off mid-word.
/// There, what loads the van is the customers themselves, in reverse.
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

/// One customer as the loading list shows them.
struct LadungStop: Identifiable, Hashable {
    let id: UUID
    /// Where this door's parcels go into the van: 1 is loaded first.
    let position: Int
    let name: String
    let address: String
    let pieces: Int

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
    static func loadingOrder(for route: Route) -> [LadungStop] {
        route.customerStops.reversed().enumerated().map { position, stop in
            let kunde = stop.kunde?.trimmed ?? ""
            return LadungStop(
                id: stop.id,
                position: position + 1,
                name: kunde.isEmpty ? "Stopp" : kunde,
                address: stop.listAddress,
                pieces: PaketParser.totalQty(stop.paket))
        }
    }
}

/// What one loading list is made of, in whichever of the two shapes this tour
/// takes. One value rather than two optional arrays: everything the screen does
/// afterwards — count the ticks, total the pieces, decide whether there is
/// anything to show at all — is the same question asked of both.
enum Ladung {
    case pakete([PaketItem])
    case kunden([LadungStop])

    var keys: [String] {
        switch self {
        case .pakete(let items): items.map(\.key)
        case .kunden(let stops): stops.map(\.key)
        }
    }

    var pieces: Int {
        switch self {
        case .pakete(let items): items.reduce(0) { $0 + $1.qty }
        case .kunden(let stops): stops.reduce(0) { $0 + $1.pieces }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Zurücksetzen", systemImage: "arrow.counterclockwise") {
                        checked.removeAll()
                        save()
                    }
                    .disabled(checked.isEmpty)
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
                        + "damit er zuletzt wieder herauskommt. Die Namen stehen "
                        + "auf den Paketen.")
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
                if !stop.address.isEmpty {
                    Text(stop.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if stop.pieces > 0 {
                    Text("\(stop.pieces) Stück")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
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
        let verb = switch ladung {
        case .pakete: "abgehakt"
        case .kunden: "geladen"
        }
        let pieces = ladung.pieces
        let total = pieces > 0 ? " · \(pieces) Stück" : ""
        if done >= keys.count { return "Alles \(verb)\(total)" }
        return "\(done) von \(keys.count) \(verb)\(total)"
    }

    private func load() {
        checked = LadelisteState.checked(for: route.id)
        mode = LadelisteState.mode(for: route.id) ?? .suggested(for: route)
    }

    private func save() {
        LadelisteState.store(checked, for: route.id)
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
            return qty > 0 && !label.isEmpty ? (qty, label) : (1, part)
        }
    }

    /// The total number of pieces one stop is delivering — used to decide
    /// whether a Paket badge reads as "just one thing" or as a multi-item drop.
    static func totalQty(_ paket: String?) -> Int {
        parse(paket).reduce(0) { $0 + $1.qty }
    }

    static func items(for route: Route) -> [PaketItem] {
        var byKey: [String: PaketItem] = [:]
        var order: [String] = []

        for stop in route.customerStops {
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
