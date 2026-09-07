import SwiftUI

/// The packing checklist: every distinct package across the route's customer
/// stops, summed, busiest first — what actually has to go into the van before
/// setting off, rather than a per-customer list nobody can load from.
struct LadelisteView: View {
    let route: Route
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []

    /// The tick grows with the text, up to a point — the same rule and the same
    /// numbers as the delivery tick in `StopRow`, because it is the same gesture
    /// and should not be a different size on this screen.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1

    private var items: [PaketItem] { PaketParser.items(for: route) }

    var body: some View {
        // Parsed once per render. Read as a computed property it was re-parsed
        // for the `ForEach`, again for the progress line, and again for the
        // piece total — three regex passes over every stop on the route, every
        // time the driver ticked a box.
        let items = items

        return NavigationStack {
            Group {
                if items.isEmpty {
                    // Outside the `List`, not a row inside it. As a row it
                    // rendered inset between separators, underneath a section
                    // header reporting "0 von 0 Positionen abgehakt" — a
                    // progress line about a list that does not exist.
                    ContentUnavailableView(
                        "Keine Pakete", systemImage: "shippingbox",
                        description: Text(
                            "Trag bei den Stopps im Feld „Paket“ ein, was mitkommt."))
                } else {
                    list(items)
                }
            }
            .navigationTitle("Ladeliste")
            .navigationSubtitle(progressLabel(items))
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

    private func list(_ items: [PaketItem]) -> some View {
        List {
            Section {
                ForEach(items) { item in
                    row(item)
                }
            } footer: {
                Text("Tippen zum Abhaken. Die Haken gelten nur für diese Tour.")
            }
        }
    }

    private func row(_ item: PaketItem) -> some View {
        let on = isOn(item)
        return Button {
            toggle(item)
        } label: {
            HStack(spacing: 14) {
                Text("\(item.qty)")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.brand))
                    .frame(width: 40, alignment: .leading)

                Text(item.label)
                    .font(.body.weight(.medium))
                    .strikethrough(on)
                    .foregroundStyle(on ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

                Spacer(minLength: 8)

                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: min(27 * textScale, 38)))
                    .foregroundStyle(on ? Color.success : Color.secondary)
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

    private func isOn(_ item: PaketItem) -> Bool { checked.contains(item.key) }

    private func toggle(_ item: PaketItem) {
        if checked.contains(item.key) {
            checked.remove(item.key)
        } else {
            checked.insert(item.key)
        }
        save()
    }

    /// Counted from the items actually on screen, not from `checked.count` —
    /// the set can still hold a key from a package that has since been edited
    /// away, and "4 von 3 abgehakt" is a great way to lose a driver's trust in
    /// the whole list.
    /// Short enough for one line. It used to be a section header reading
    /// "0 von 2 Positionen abgehakt · 5 Stück gesamt", which wrapped onto two
    /// lines on a phone — and the words it spent that second line on ("
    /// Positionen", "gesamt") were the ones carrying no information. It sits
    /// under the screen's title now, the same place the tour's progress does.
    private func progressLabel(_ items: [PaketItem]) -> String {
        guard !items.isEmpty else { return "" }
        let done = items.count { checked.contains($0.key) }
        let pieces = items.reduce(0) { $0 + $1.qty }
        if done >= items.count { return "Alles abgehakt · \(pieces) Stück" }
        return "\(done) von \(items.count) abgehakt · \(pieces) Stück"
    }

    private func load() {
        checked = LadelisteState.checked(for: route.id)
    }

    private func save() {
        LadelisteState.store(checked, for: route.id)
    }
}

/// Which lines of a route's packing list are ticked off.
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

    static func checked(for routeID: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(routeID)) ?? [])
    }

    static func store(_ checked: Set<String>, for routeID: UUID) {
        UserDefaults.standard.set(Array(checked), forKey: key(routeID))
    }

    static func forget(_ routeID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(routeID))
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
