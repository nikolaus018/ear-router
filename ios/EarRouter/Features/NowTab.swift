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
/// The tour shown is the one being worked — the last active tour the driver
/// opened — and otherwise the newest active one: the same answer the lock
/// screen, Siri and the car get. See `Route.current`.
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
    /// The stop whose delivery did not simply work — see `OutcomeSheet`.
    @State private var outcomeStop: Stop?
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
        /// What was recorded, so the banner can say it. „Fam. Gruber“
        /// zugestellt over a door nobody opened would be the app's own
        /// summary of the day quietly disagreeing with the driver's.
        var outcome: DeliveryOutcome = .delivered
        /// Lager or Ziel, which are "erledigt" rather than "geliefert".
        var checkpoint = false

        var label: String { checkpoint ? "erledigt" : outcome.shortLabel }
    }

    private var route: Route? {
        Route.current(among: active, working: focus.workingRouteID)
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
        .sheet(item: $outcomeStop) { stop in
            OutcomeSheet(stop: stop, info: info(for: stop)) { outcome in
                settle(stop, as: outcome)
            }
        }
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
        let info = stockwerkNotes.info(for: snapshot.ordered)
        let current = snapshot.nextOpen

        // One stop and nothing else. What comes after it, and the whole list,
        // is one tab to the left — repeating any of it here is exactly the
        // clutter this tab exists to get away from.
        return List {
            if let current {
                currentSection(current, route: route, snapshot: snapshot, info: info)
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
            toolbar(
                route, current: current,
                hasFloor: current.flatMap { info[$0.id]?.stockwerk } != nil)
        }
        .animation(.snappy, value: current?.id)
        .safeAreaInset(edge: .bottom, spacing: 0) { undoBanner(route) }
        .animation(.snappy, value: undo)
        .onChange(of: route.id) { undo = nil }
    }

    private func currentSection(
        _ stop: Stop, route: Route, snapshot: RouteSnapshot, info: [UUID: StockwerkNote]
    ) -> some View {
        Section {
            NowStopCard(
                stop: stop,
                number: snapshot.number(stop),
                info: stop.kind == .customer ? info[stop.id] : nil,
                sameDoorCount: snapshot.doorCount(stop),
                finishesAt: snapshot.etaFinish(),
                onNavigate: { navigate(to: stop) },
                onDelivered: { deliver(stop, of: route) },
                onNotDelivered: { outcomeStop = stop })
                .id(stop.id)
                .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20))
        } header: {
            ProgressHeader(
                delivered: snapshot.deliveredCount, settled: snapshot.settledCount,
                total: snapshot.customerCount)
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
        Section {
            TourDoneView(
                count: snapshot.customerCount,
                delivered: snapshot.deliveredCount,
                followUps: snapshot.followUps,
                homeKm: snapshot.remainingKm,
                onFinish: { finish(route) })
                .listRowBackground(Color.clear)
        } header: {
            ProgressHeader(
                delivered: snapshot.deliveredCount, settled: snapshot.settledCount,
                total: snapshot.customerCount)
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
            if current.kind == .customer || current.kind == .start || current.kind == .end {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Bearbeiten", systemImage: "pencil") { editingStop = current }
                        if current.kind == .customer {
                            Button(
                                hasFloor ? "Stockwerk ändern" : "Stockwerk eintragen",
                                systemImage: "stairs"
                            ) {
                                stockwerkStop = current
                            }
                        }
                    } label: {
                        Label("Mehr", systemImage: "ellipsis")
                    }
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
                Image(systemName: undo.outcome.symbol)
                    .foregroundStyle(undo.outcome.handedOver ? Color.delivered : Color.attention)
                    .accessibilityHidden(true)
                Text("„\(undo.name)“ — \(undo.label)")
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
        settle(stop, as: .delivered)
    }

    /// Records any outcome, from the big green button or from `OutcomeSheet`,
    /// and offers the same few seconds to take it back.
    ///
    /// The floor question follows only a meal that actually arrived. After a
    /// locked door the driver is walking back to the van, not standing in the
    /// stairwell, and the entire case for asking then is that they are looking
    /// at the answer.
    private func settle(_ stop: Stop, as outcome: DeliveryOutcome) {
        guard let route = stop.route else { return }
        do {
            try RouteStore.record(outcome, for: stop, in: context)
        } catch {
            self.error = AppError.message("Konnte den Lieferstatus nicht speichern.")
            return
        }
        finishedTour = route.isComplete
        ticks += 1
        if outcome.handedOver, StockwerkStore.shouldAsk(stop, in: context) {
            stockwerkStop = stop
        }
        offerUndo(
            DeliveredTick(
                id: stop.id, name: stop.kunde ?? "Stopp", outcome: outcome,
                checkpoint: stop.kind != .customer))
    }

    /// What is known about this one customer. A linear scan rather than the
    /// table the list builds: this is one stop, once, when a sheet opens.
    private func info(for stop: Stop) -> StockwerkNote? {
        guard let key = StockwerkKey.make(for: stop) else { return nil }
        return stockwerkNotes.first { $0.key == key }
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
        AccessibilityNotification.Announcement(
            "„\(tick.name)“ \(tick.label)"
        ).post()
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
    /// What is kept about this customer across every tour: the floor, and the
    /// driver's own standing note.
    let info: StockwerkNote?
    let sameDoorCount: Int
    /// When the shift is expected to end, shown once rather than per stop —
    /// this is the screen a driver looks at when somebody asks how long they
    /// will be.
    let finishesAt: Date?
    let onNavigate: () -> Void
    let onDelivered: () -> Void
    /// Opens the "Nicht zugestellt" sheet.
    let onNotDelivered: () -> Void

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
            finish
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
                if isCheckpoint {
                    Image(systemName: stop.kind == .via ? "shippingbox.fill" : "flag.checkered")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: badge, height: badge)
                        .background(Circle().fill(Color.accentColor))
                        .accessibilityHidden(true)
                } else {
                    StopNumberBadge(
                        number: number, kind: .current, size: badge,
                        font: .subheadline.weight(.semibold).monospacedDigit())
                }
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
        let paket = StopFacts.paket(stop.displayPaket)
        let floor = StopFacts.floor(info?.stockwerk)
        let note = stop.notiz?.trimmed ?? ""
        let standing = info?.notiz?.trimmed ?? ""
        if paket != nil || floor != nil || !note.isEmpty || stop.precision != nil
            || !standing.isEmpty
        {
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
                // Above the tour's own note on purpose. This is the part
                // learned at this door by somebody who stood at it, and it is
                // read in the ten seconds before the bell rather than after.
                StopFacts.customerNote(info, lineLimit: 40)
                    .font(.callout)
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
                WideButtonLabel(isCheckpoint ? "Erledigt" : "Geliefert", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .tint(.delivered)

            // The other answer, and the whole reason this app stopped storing
            // one bit per door. Same width and same height as "Geliefert",
            // because on the day it is needed it is needed with one hand and a
            // warm box in the other — but tinted amber and second, because it
            // is the answer at one door in thirty.
            //
            // Not at Lager or Ziel, where there is nobody to be not at home.
            if !isCheckpoint {
                Button(action: onNotDelivered) {
                    WideButtonLabel("Nicht zugestellt", systemImage: "bell.slash")
                }
                .buttonStyle(.bordered)
                .tint(.attention)
            }

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

    /// "Voraussichtlich fertig gegen 11:48" — under the buttons, in the small
    /// print, because it is the answer to a question somebody else asks.
    ///
    /// Hedged, and only ever "gegen": it is arithmetic over a measured average,
    /// and the driver reading it will repeat it to a customer.
    @ViewBuilder
    private var finish: some View {
        if let finishesAt {
            Label("Voraussichtlich fertig gegen \(Format.time(finishesAt))", systemImage: "flag.checkered")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabelStyle(tint: .secondary))
                .padding(.leading, indent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isCheckpoint: Bool { stop.kind != .customer }

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
    /// Doors answered for, which is what the bar fills to. A customer who was
    /// not home is behind the driver even though no meal left the van, and a
    /// bar that refused to move for them would sit at 29/30 all afternoon.
    let settled: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
            ProgressView(value: Double(settled), total: Double(max(total, 1)))
                .tint(.delivered)
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    /// "12 von 30 geliefert", and the gap named when there is one. Two numbers
    /// that differ need the difference said out loud — a header reading "12 von
    /// 30" over fourteen doors already behind the driver is the kind of
    /// arithmetic nobody should be doing at the wheel.
    private var caption: String {
        let missed = settled - delivered
        guard missed > 0 else { return "\(delivered) von \(total) geliefert" }
        return "\(delivered) von \(total) geliefert · \(missed) nicht"
    }
}

/// Every meal handed over: the drive home, and the button that files the tour.
private struct TourDoneView: View {
    let count: Int
    /// Meals that actually left the van.
    let delivered: Int
    /// The customers nobody was home for — the reason this screen is not
    /// always a green seal.
    let followUps: [Stop]
    let homeKm: Double
    let onFinish: () -> Void

    private var allDelivered: Bool { followUps.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: allDelivered ? "checkmark.seal.fill" : "bell.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(allDelivered ? Color.delivered : Color.attention)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(allDelivered && delivered == count ? "Alle geliefert" : "Tour gefahren")
                    .font(.title2.bold())
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Named, not counted. "1 nicht angetroffen" is a number somebody
            // then has to go and look up; the name is the whole content of the
            // phone call that follows, and this is the screen the driver is on
            // when they decide whether to make it.
            if !allDelivered {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(followUps, id: \.id) { stop in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(stop.kunde ?? "Stopp")
                                    .fixedSize(horizontal: false, vertical: true)
                                if !stop.listAddress.isEmpty {
                                    Text(stop.listAddress)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } icon: {
                            Image(systemName: "bell.slash.fill")
                        }
                        .font(.subheadline)
                        .labelStyle(TintedIconLabelStyle(tint: .attention))
                        .symbolRenderingMode(.monochrome)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.attention.opacity(0.12), in: .rect(cornerRadius: 12))
            }

            // No "Navigation zum Ziel": Ziel is a stop of its own now, and this
            // screen only comes up once it has been ticked off.
            Button(action: onFinish) {
                WideButtonLabel("Tour abschließen", systemImage: "checkmark.seal.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// Counted off the meals that actually left the van. "30 Stopps
    /// zugestellt" over a tour with two abbestellt customers on it was a
    /// sentence two meals too generous.
    private var detail: String {
        let handed = delivered == count
            ? (count == 1 ? "1 Stopp zugestellt" : "\(count) Stopps zugestellt")
            : "\(delivered) von \(count) zugestellt"
        guard homeKm >= 0.05, let km = Format.km(homeKm) else { return handed }
        return "\(handed) · Rückfahrt \(km)"
    }
}
