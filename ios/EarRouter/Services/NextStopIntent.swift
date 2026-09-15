import AppIntents
import SwiftData
import SwiftUI
import Foundation

/// "Hey Siri, nächster Stopp" — asked at the wheel, with the phone in a holder.
///
/// The answer is spoken and shown without the app being brought up: who is
/// next, where they are, which floor, and what to carry. Every one of those is
/// already on the Jetzt tab; the point of this is that reaching Jetzt costs a
/// hand, and the driver who wants this is the one who has not got one free.
///
/// Read-only on purpose. Ticking a delivery off by voice would be the obvious
/// next thing and is deliberately not here: a misheard "geliefert" writes a
/// meal as delivered to somebody who never got one, and that is the single
/// worst thing this app can be wrong about.
struct NextStopIntent: AppIntent {
    static let title: LocalizedStringResource = "Nächster Stopp"
    static let description = IntentDescription(
        "Sagt, welcher Kunde als Nächstes dran ist — mit Adresse, Stockwerk und Paket.")

    /// The app stays closed. This is asked while driving, and opening the app
    /// over the navigation running on the same screen is the opposite of what
    /// was wanted.
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let container = try? AppSchema.container() else {
            return .result(dialog: "Die Tourdaten lassen sich gerade nicht öffnen.")
        }
        let context = ModelContext(container)

        // The newest active tour, which is the same one every screen in the app
        // falls back to when nothing is in focus.
        var descriptor = FetchDescriptor<Route>(
            predicate: #Predicate { $0.statusRaw == "active" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1

        guard let route = try? context.fetch(descriptor).first else {
            return .result(dialog: "Es läuft gerade keine Tour.")
        }
        let snapshot = RouteSnapshot(route)
        guard let stop = snapshot.nextOpen else {
            return .result(
                dialog: snapshot.customerCount == 0
                    ? "Auf der Tour sind noch keine Stopps."
                    : "Alle Stopps sind erledigt.")
        }

        let floor = (try? StockwerkStore.note(for: stop, in: context))??.stockwerk
        let spoken = Self.sentence(
            stop, number: snapshot.number(stop), floor: floor,
            eta: snapshot.eta(for: stop))

        return .result(
            dialog: IntentDialog(stringLiteral: spoken),
            view: NextStopSnippet(
                stop: stop, number: snapshot.number(stop), floor: floor,
                eta: snapshot.eta(for: stop)))
    }

    /// What Siri actually says.
    ///
    /// Ordered the way it is needed at the wheel: who, then where, then — only
    /// once the van has stopped — the stairs and the box. Static and pure so
    /// the sentence can be tested; getting it wrong is a driver at the wrong
    /// door.
    static func sentence(
        _ stop: Stop, number: Int?, floor: String?, eta: Date?
    ) -> String {
        var parts: [String] = []
        let who = stop.kunde?.trimmed.nilIfEmpty ?? "Der nächste Stopp"
        parts.append(number.map { "Stopp \($0): \(who)" } ?? who)
        if !stop.listAddress.isEmpty { parts.append(stop.listAddress) }
        if let floor = floor?.trimmed, !floor.isEmpty { parts.append(Format.floor(floor)) }
        if let paket = stop.displayPaket?.trimmed, !paket.isEmpty { parts.append(paket) }
        if let eta { parts.append("Ankunft etwa \(Format.time(eta))") }
        return parts.joined(separator: ", ") + "."
    }
}

/// The card Siri shows beside what it says — the same facts, in the app's own
/// vocabulary, so a glance at the phone and a sentence in the ear agree.
struct NextStopSnippet: View {
    let stop: Stop
    let number: Int?
    let floor: String?
    let eta: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StopNumberBadge(number: number, kind: .current, size: 26)
                Text(stop.kunde ?? "Stopp")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stop.listAddress.isEmpty {
                Text(stop.listAddress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let paket = StopFacts.paket(stop.displayPaket) { paket.font(.subheadline) }
            if let floor = StopFacts.floor(floor) { floor.font(.subheadline) }
            if let when = StopFacts.eta(eta) {
                when.font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .symbolRenderingMode(.monochrome)
    }
}

/// Makes the navigation intent reachable without the driver setting anything
/// up — in Kurzbefehle's own action list, which is where the CarPlay automation
/// is built from, and by voice on a morning the phone never got plugged in.
///
/// `NextStopIntent` is deliberately *not* listed. It still exists and still
/// works as an action somebody adds by hand, but two EAR Router tiles sitting
/// side by side in Kurzbefehle — one that reads the next stop out, one that
/// drives to it — is a choice to make at the wheel, and the wrong one is the
/// one that does nothing about the van being parked.
struct EarRouterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NavigateNextStopIntent(),
            phrases: [
                "Navigation zum nächsten Stopp in \(.applicationName)",
                "Zum nächsten Stopp navigieren mit \(.applicationName)",
                "\(.applicationName) Navigation starten",
            ],
            shortTitle: "Zum nächsten Stopp",
            systemImageName: "car.fill")
    }
}
