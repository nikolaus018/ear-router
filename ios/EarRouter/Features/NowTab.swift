import SwiftUI
import SwiftData

/// Jetzt — the one stop the driver is on, given the whole screen.
///
/// This used to be a card floating over the bottom of the tour's stop list, and
/// it was always a compromise there. It covered a third of the list it sat on.
/// It repeated the row directly above it, so the row had to strip itself to
/// make room. And it had no ceiling of its own, so at a large text size it had
/// to go brief and hand half its facts back to that row. A tab of its own ends
/// all three: the errand gets room for the whole note and two buttons a thumb
/// cannot miss, and the tour list goes back to being only a list.
///
/// It is not the "Heute" tab this app once had and dropped. That rendered the
/// same stop list Touren does — two doors to one room. This is a different
/// room: one stop and what to do there — and deliberately nothing else. What
/// comes after it, and the whole list, is one tab to the left.
///
/// The tour shown is the one in focus — the one Touren and Karte are showing —
/// while it is active, and otherwise the newest active tour.
struct NowTab: View {
    @Environment(RouteFocus.self) private var focus
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @Query(
        filter: #Predicate<Route> { $0.statusRaw == "active" },
        sort: \Route.createdAt, order: .reverse)
    private var active: [Route]

    /// Every door ever answered for — the same query the stop list runs, so a
    /// floor typed on one screen is on the other immediately.
    @Query private var stockwerkNotes: [StockwerkNote]

    @State private var editingStop: Stop?
    @State private var stockwerkStop: Stop?
    /// The delivery that can still be taken back — see `undoBanner`.
    @State private var undo: DeliveredTick?
    @State private var undoTask: Task<Void, Never>?
    @State private var error: AppError?
    /// Presses of "Geliefert", and nothing else — it drives the haptic. The same
    /// counter `StopRow` keeps, for the same reason: keyed on the stop, it
    /// would also fire for ticks made on other screens.
    @State private var ticks = 0
    /// Whether the last press finished the tour, which is worth feeling
    /// differently from the thirty presses before it.
    @State private var finishedTour = false

    /// One delivery that can still be taken back.
    struct DeliveredTick: Equatable {
        let id: UUID
        let name: String
    }

    private var route: Route? {
        active.first { $0.id == focus.currentRouteID } ?? active.first
    }

    var body: some View {
        Group {
            if let route {
                screen(route)
            } else {
                noTour
            }
        }
        .stockwerkPrompt(for: $stockwerkStop)
        // The floor question has closed, so the undo banner is visible at
        // last — and only now does its countdown begin. See `offerUndo`.
        .onChange(of: stockwerkStop?.id) { _, shown in
            if shown == nil, undo != nil { startUndoCountdown() }
        }
        .sheet(item: $editingStop) { stop in
            editor(for: stop)
        }
        .errorAlert($error)
        .sensoryFeedback(trigger: ticks) { _, _ in
            finishedTour ? .success : .impact(weight: .medium)
        }
    }

    // MARK: - The screen

    private var noTour: some View {
        ContentUnavailableView {
            Label("Keine aktive Tour", systemImage: "door.left.hand.closed")
        } description: {
            Text("Sobald eine Tour läuft, steht hier der Stopp, bei dem du gerade bist.")
        } actions: {
            Button("Zu den Touren") { focus.select(.tours) }
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Jetzt")
    }

    private func screen(_ route: Route) -> some View {
        // Derived once, for the same reason `TourView` does: every one of these
        // walks the whole route.
        let snapshot = RouteSnapshot(route)
        let floors = stockwerkNotes.floors(for: snapshot.ordered)
        let current = snapshot.nextOpen

        // One stop and nothing else. What comes after it, and the whole list,
        // is one tab to the left — repeating any of it here is exactly the
        // clutter this tab exists to get away from.
        return List {
            if let current {
                currentSection(current, route: route, snapshot: snapshot, floors: floors)
            } else if snapshot.customerCount == 0 {
                emptySection(route)
            } else {
                doneSection(route, snapshot: snapshot)
            }
        }
        // The same title and the same line under it as the tour's own screen,
        // so the two never describe one tour in two ways.
        .navigationTitle(route.name)
        .navigationSubtitle(snapshot.summary(of: route))
        .toolbar {
            toolbar(route, current: current, hasFloor: current.flatMap { floors[$0.id] } != nil)
        }
        .animation(.snappy, value: current?.id)
        .safeAreaInset(edge: .bottom, spacing: 0) { undoBanner(route) }
        .animation(.snappy, value: undo)
        .onChange(of: route.id) { undo = nil }
    }

    private func currentSection(
        _ stop: Stop, route: Route, snapshot: RouteSnapshot, floors: [UUID: String]
    ) -> some View {
        Section {
            NowStopCard(
                stop: stop,
                number: snapshot.number(stop),
                stockwerk: floors[stop.id],
                sameDoorCount: snapshot.doorCount(stop),
                onNavigate: { navigate(to: stop) },
                onDelivered: { deliver(stop, of: route) })
                .id(stop.id)
                .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
        } header: {
            ProgressHeader(delivered: snapshot.deliveredCount, total: snapshot.customerCount)
        }
    }

    private func emptySection(_ route: Route) -> some View {
        Section {
            ContentUnavailableView {
                Label("Noch keine Stopps", systemImage: "tray")
            } description: {
                Text("Stopps hinzufügen und importieren geht in der Tour selbst.")
            } actions: {
                Button("Zur Tour") { focus.open(route) }
                    .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
        }
    }

    private func doneSection(_ route: Route, snapshot: RouteSnapshot) -> some View {
        let end = snapshot.ordered.first { $0.kind == .end && !$0.excluded }
        return Section {
            TourDoneView(
                count: snapshot.customerCount,
                homeKm: snapshot.remainingKm,
                canNavigateHome: end != nil,
                onNavigateHome: { if let end { navigate(to: end) } },
                onFinish: { finish(route) })
                .listRowBackground(Color.clear)
        } header: {
            ProgressHeader(delivered: snapshot.deliveredCount, total: snapshot.customerCount)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ route: Route, current: Stop?, hasFloor: Bool) -> some ToolbarContent {
        if let current {
            // A button of its own rather than a menu item: "which side of the
            // building is this door on" is asked at half the stops on a tour.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Auf der Karte zeigen", systemImage: "map") {
                    focus.showOnMap(stop: current, of: route)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Bearbeiten", systemImage: "pencil") { editingStop = current }
                    Button(
                        hasFloor ? "Stockwerk ändern" : "Stockwerk eintragen",
                        systemImage: "stairs"
                    ) {
                        stockwerkStop = current
                    }
                } label: {
                    Label("Mehr", systemImage: "ellipsis")
                }
            }
        }
    }

    /// "Fr. Huber zugestellt · Rückgängig", for a few seconds after each tick.
    ///
    /// The tick is the one action on this screen that takes something away:
    /// the stop leaves the screen the moment it is pressed. A thumb that caught
    /// "Geliefert" while reaching for "Navigation" would otherwise have to go
    /// and find the stop in the tour's list to put it back.
    @ViewBuilder
    private func undoBanner(_ route: Route) -> some View {
        if let undo {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.delivered)
                    .accessibilityHidden(true)
                Text("„\(undo.name)“ zugestellt")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Rückgängig") { takeBack(undo, in: route) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func editor(for stop: Stop) -> some View {
        if let route = stop.route {
            StopEditorSheet(route: route, stop: stop) {
                // Dismissed first, then deleted — see `TourView`.
                editingStop = nil
                Task { await delete(stop) }
            }
        }
    }

    // MARK: - Actions

    private func navigate(to stop: Stop) {
        guard let url = NavigationHandoff.url(for: stop) else { return }
        openURL(url)
    }

    /// Ticks the stop off, offers to take it back, and — on the way past — asks
    /// the floor, exactly as a tick in the stop list does.
    private func deliver(_ stop: Stop, of route: Route) {
        do {
            try RouteStore.setDelivered(stop, true, in: context)
        } catch {
            self.error = AppError.message("Konnte den Lieferstatus nicht speichern.")
            return
        }
        finishedTour = route.isComplete
        ticks += 1
        if StockwerkStore.shouldAsk(stop, in: context) { stockwerkStop = stop }
        offerUndo(DeliveredTick(id: stop.id, name: stop.kunde ?? "Stopp"))
    }

    /// Puts the banner up. Its six seconds start only once nothing covers it:
    /// the floor question comes up over the screen on the same tick, and a
    /// countdown running underneath that sheet had spent the whole offer
    /// before the driver ever saw it.
    private func offerUndo(_ tick: DeliveredTick) {
        undoTask?.cancel()
        undo = tick
        // Said out loud as well: VoiceOver does not notice a banner arriving
        // at the bottom of the screen on its own, and the stop it was on has
        // just been replaced by the next one.
        AccessibilityNotification.Announcement("„\(tick.name)“ zugestellt").post()
        if stockwerkStop == nil { startUndoCountdown() }
    }

    private func startUndoCountdown() {
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            undo = nil
        }
    }

    private func takeBack(_ tick: DeliveredTick, in route: Route) {
        undoTask?.cancel()
        undo = nil
        do {
            try RouteStore.undoDelivery(tick.id, on: route, in: context)
        } catch {
            self.error = AppError.message("Konnte den Lieferstatus nicht speichern.")
        }
    }

    private func finish(_ route: Route) {
        do {
            try RouteStore.toggleStatus(route, in: context)
        } catch {
            self.error = AppError.message("Die Tour konnte nicht abgeschlossen werden.")
        }
    }

    private func delete(_ stop: Stop) async {
        do {
            try await RouteStore.deleteStop(stop, in: context)
        } catch {
            self.error = AppError.message("Stopp konnte nicht entfernt werden.")
        }
    }
}

// MARK: - The stop

/// Who, where, what to carry — and the two things done at every door.
///
/// One step up from the stop list and no more: the name at a heading's size,
/// everything else at reading size. Clear at arm's length from a phone in a
/// holder, without looking as if the phone's accessibility sizes had been
/// switched on — which is what setting everything a size larger did. Those
/// sizes are the driver's to choose in Settings, and every text here follows
/// them anyway. Complete, because nothing else on the screen competes for the
/// room: the whole note, not its first two lines.
private struct NowStopCard: View {
    let stop: Stop
    let number: Int?
    let stockwerk: String?
    let sameDoorCount: Int
    let onNavigate: () -> Void
    let onDelivered: () -> Void

    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 28
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How far the lines under the name are set in — to the name's own column,
    /// except at an accessibility text size. There the badge has grown too,
    /// and an indent its width cost the address and the note a fifth of the
    /// card: "1 Stunde / vorher anrufen" broke over two lines and pushed
    /// "Geliefert" below the fold. The full width goes back to the words, the
    /// same trade the stop row makes at those sizes.
    private var indent: CGFloat { typeSize.isAccessibilitySize ? 0 : badge + 12 }
    /// Briefly true after the address was copied, so the copy button can say
    /// so in place. The card is rebuilt for every stop, so this never carries
    /// over to the next one.
    @State private var copied = false
    @State private var copyTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            who
            errand
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .symbolRenderingMode(.monochrome)
    }

    /// The badge beside the name, and everything after it in the column the
    /// name starts — the layout of the stop's own row and of the map's pin
    /// card. On a line of its own above the name the badge was an orphaned dot
    /// with a whole line of the card to itself.
    private var who: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                StopNumberBadge(
                    number: number, kind: .current, size: badge,
                    font: .subheadline.weight(.semibold).monospacedDigit())
                Text(stop.kunde ?? "Stopp")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(alignment: .leading, spacing: 4) {
                if !stop.listAddress.isEmpty {
                    HStack(alignment: .center, spacing: 8) {
                        Text(stop.listAddress)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Only with a street to copy: a stop carrying a
                        // postcode alone would have copied an empty string.
                        if !(stop.strasse?.trimmed ?? "").isEmpty { copyButton }
                    }
                }
                if sameDoorCount > 1 {
                    StopFacts.run("person.2.fill", "\(sameDoorCount) an dieser Tür")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.leading, indent)
        }
    }

    /// Beside the address it copies, rather than in a menu: it is the address
    /// on the line next to it that goes on the clipboard, and the button says
    /// so by where it sits. The street and house number only — Stiege and Tür
    /// included, the postcode left off — which is the part that gets pasted.
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = stop.strasse?.trimmed ?? ""
            copyTask?.cancel()
            withAnimation(.snappy) { copied = true }
            copyTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.body.weight(.semibold))
                .foregroundStyle(copied ? Color.delivered : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
                // The full 44 points to hit, without making the address line
                // 44 points tall: laid out at its natural height it pushed the
                // Paket a whole blank line further down the card.
                .padding(.vertical, -10)
        }
        // Its own tap, not the row's — the same reason the stop row's two
        // controls are borderless.
        .buttonStyle(.borderless)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .accessibilityLabel(copied ? "Adresse kopiert" : "Adresse kopieren")
    }

    /// What comes out of the van, which stairs, and anything to know before
    /// ringing — the same lines, in the same vocabulary, as the stop's row.
    @ViewBuilder
    private var errand: some View {
        let paket = StopFacts.paket(stop.paket)
        let floor = StopFacts.floor(stockwerk)
        let note = stop.notiz?.trimmed ?? ""
        if paket != nil || floor != nil || !note.isEmpty || stop.precision != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let paket {
                    paket
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let floor {
                    floor
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !note.isEmpty {
                    StopFacts.note(note, lineLimit: 40)
                        .font(.callout)
                }
                if let precision = stop.precision {
                    StopFacts.precision(precision)
                        .font(.footnote)
                }
            }
            .padding(.leading, indent)
        }
    }

    /// Navigate, then tick off. Filled for the one pressed first, green for the
    /// one pressed last — told apart by hue rather than by weight, the same
    /// pairing the map's pin card uses.
    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onNavigate) {
                WideButtonLabel("Navigation", systemImage: "arrow.trianglehead.turn.up.right")
            }
            .buttonStyle(.borderedProminent)

            Button(action: onDelivered) {
                WideButtonLabel("Geliefert", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .tint(.delivered)

            // The customer's own number from the Zusteller-Portal — same
            // height as Navigation and Geliefert above it. It used to be
            // smaller, on the theory that a call is the exception at a door
            // rather than the errand, but that read as a broken layout rather
            // than a deliberate one: three buttons a thumb reaches for in a
            // row, one of them a different size for no reason it could see.
            if let telefonURL {
                Button {
                    openURL(telefonURL)
                } label: {
                    WideButtonLabel("Anrufen", systemImage: "phone.fill")
                }
                .buttonStyle(.bordered)
            }

            // A number written into the note instead — a daughter to call
            // when nobody answers, "1 Stunde vorher anrufen" — becomes a
            // button of its own, one per number. Filtered against the
            // customer's own number above so the same digits never get two
            // buttons. iOS asks once more before it dials.
            ForEach(notizPhones) { phone in
                Button {
                    if let url = phone.url { openURL(url) }
                } label: {
                    WideButtonLabel("\(phone.display) anrufen", systemImage: "phone.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private var telefonURL: URL? {
        stop.telefon?.trimmed.nilIfEmpty.flatMap(PhoneNumbers.dialURL(for:))
    }

    private var notizPhones: [PhoneNumbers.Found] {
        PhoneNumbers.inNote(stop.notiz, besides: stop.telefon)
    }
}

/// "12 von 30 geliefert", over a bar — the count the tour list's header gives,
/// with the green of a tick to show how far along that is.
private struct ProgressHeader: View {
    let delivered: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(delivered) von \(total) geliefert")
            ProgressView(value: Double(delivered), total: Double(max(total, 1)))
                .tint(.delivered)
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Every meal handed over: the drive home, and the button that files the tour.
private struct TourDoneView: View {
    let count: Int
    let homeKm: Double
    let canNavigateHome: Bool
    let onNavigateHome: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.delivered)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Alle geliefert")
                    .font(.title2.bold())
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                if canNavigateHome {
                    Button(action: onNavigateHome) {
                        WideButtonLabel("Navigation zum Ziel", systemImage: "flag.checkered")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: onFinish) {
                        WideButtonLabel("Tour abschließen", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: onFinish) {
                        WideButtonLabel("Tour abschließen", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var detail: String {
        let delivered = count == 1 ? "1 Stopp zugestellt" : "\(count) Stopps zugestellt"
        guard homeKm >= 0.05, let km = Format.km(homeKm) else { return delivered }
        return "\(delivered) · Rückfahrt \(km)"
    }
}
