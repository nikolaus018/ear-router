import SwiftUI

/// The packing checklist: every distinct package across the route's customer
/// stops, summed, busiest first — what actually has to go into the van before
/// setting off, rather than a per-customer list nobody can load from.
struct LadelisteView: View {
    let route: Route
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []

    private var items: [PaketItem] { PaketParser.items(for: route) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { item in
                        Button {
                            toggle(item)
                        } label: {
                            HStack(spacing: 14) {
                                Text("\(item.qty)")
                                    .font(.title3.bold().monospacedDigit())
                                    .foregroundStyle(isOn(item) ? .secondary : Color.brand)
                                    .frame(width: 40, alignment: .leading)

                                Text(item.label)
                                    .font(.body.weight(.medium))
                                    .strikethrough(isOn(item))
                                    .foregroundStyle(isOn(item) ? .secondary : .primary)

                                Spacer()

                                Image(
                                    systemName: isOn(item)
                                        ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(isOn(item) ? Color.success : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn(item) ? [.isSelected] : [])
                    }
                } header: {
                    Text(progressLabel)
                } footer: {
                    Text("Tippen zum Abhaken. Die Haken gelten nur für diese Tour.")
                }

                if items.isEmpty {
                    ContentUnavailableView(
                        "Keine Pakete", systemImage: "shippingbox",
                        description: Text("Trag bei den Stopps im Feld „Paket“ ein, was mitkommt."))
                }
            }
            .navigationTitle("Ladeliste")
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
    private var progressLabel: String {
        let done = items.count { checked.contains($0.key) }
        let pieces = items.reduce(0) { $0 + $1.qty }
        if done >= items.count && !items.isEmpty {
            return "Alles abgehakt ✓ · \(pieces) Stück gesamt"
        }
        return "\(done) von \(items.count) Positionen abgehakt · \(pieces) Stück gesamt"
    }

    private var storageKey: String { "ladeliste.\(route.id.uuidString)" }

    private func load() {
        checked = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    private func save() {
        UserDefaults.standard.set(Array(checked), forKey: storageKey)
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
