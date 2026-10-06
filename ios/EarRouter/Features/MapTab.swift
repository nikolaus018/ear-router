import SwiftUI
import SwiftData
import MapKit

/// The route on a map. MapKit rather than a tile stack of our own: it is the
/// map the driver already knows, it needs no tile hosting, and its satellite
/// style replaces what the Stadt-Wien aerial layer was there for.
struct MapTab: View {
    @Environment(RouteFocus.self) private var focus
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: \Route.createdAt, order: .reverse) private var routes: [Route]

    @State private var style: MapStyleChoice = .standard
    @State private var selectedStopID: UUID?
    /// Every public toilet on the map. Kept across launches, which the map
    /// style is not: somebody who wants them wants them every day.
    @AppStorage("map.showRestrooms") private var showRestrooms = false
    /// Which customer of a shared pin the card is showing. `nil` while the
    /// pin's list of everyone at that address is up instead.
    @State private var chosenMemberID: UUID?
    /// Every customer's stop number, worked out with the pins. Not read off
    /// the marker any more: a shared pin says "3+", not a number.
    @State private var numbers: [UUID: Int] = [:]
    @State private var error: AppError?
    /// The stop whose floor is being asked about, once its card has closed.
    @State private var stockwerkStop: Stop?
    /// Set while that card is still closing — see `cardDismissed`.
    @State private var pendingStockwerkStop: Stop?

    /// Every door ever answered for — the same query the stop list runs, so a
    /// floor typed on one screen is on the other one immediately.
    @Query private var stockwerkNotes: [StockwerkNote]
    /// The measured height of the tapped stop's card — see the sheet below.
    @State private var previewHeight: CGFloat = 200
    /// The same for a toilet's card, which grows by its note.
    @State private var restroomHeight: CGFloat = 250
    /// The same for the card of a stop that belongs to the other driver.
    @State private var otherHeight: CGFloat = 250

    /// The rest of this route's portal tour, in a colour of its own — for
    /// talking a split through with the other driver. Not kept across
    /// launches, unlike the toilets: it is fetched from the portal each time it
    /// is switched on, and is something to look at in one conversation.
    @State private var showOthers = false
    @State private var others: [OtherPin] = []
    /// The route `others` were fetched for. A switch to another tour drops them.
    @State private var othersRouteID: UUID?
    @State private var loadingOthers = false
    @State private var othersTask: Task<Void, Never>?
    /// Whether there is a portal login to fetch with — read when the tab comes
    /// forward rather than in `body`, which is a Keychain query per redraw.
    @State private var hasPortalLogin = false

    /// As tall as the preview card is ever allowed to get. Past this it keeps
    /// its own scroll rather than growing into a sheet that covers the pin it
    /// is describing.
    private static let maxPreviewHeight: CGFloat = 460

    /// The map's content, built once per change rather than per frame.
    ///
    /// `Map`'s content closure is re-evaluated on every camera change — which,
    /// during the fit animation on first open, is every frame. Deriving from the
    /// model in there meant rebuilding the whole polyline and re-sorting the
    /// stops once per marker per frame: O(n² log n) over a live SwiftData
    /// relationship, sixty times a second. That was the lag.
    @State private var line: [CLLocationCoordinate2D] = []
    @State private var pins: [MapPin] = []

    /// True while the driven line is being simplified off the main actor.
    @State private var buildingLine = false
    /// Bumped when a line finishes building, so the canvas knows to re-frame.
    /// The camera itself lives down there — see `RouteMapCanvas`.
    @State private var fitToken = 0
    /// Discards the result of a simplification that a newer one has overtaken.
    @State private var lineGeneration = 0
    /// The route shape `line` and `pins` were actually built from, and the one
    /// a simplification currently in flight is working towards.
    ///
    /// These are what let this tab answer "is what I am drawing still what the
    /// route says?" instead of "was I told about a change?". The difference is
    /// the whole bug: being told relies on `onChange`, `onChange` relies on the
    /// body having been evaluated, and a tab sitting behind three others is not
    /// guaranteed to be evaluated at all. `onAppear` was the fallback for
    /// exactly that — and it only ever rebuilt the *pins*, so the one thing it
    /// could not repair was the driven line. Worse, it declined to do even that
    /// whenever a simplification happened to be in flight as the tab came
    /// forward, which measurement says is most of the time. A line left stale
    /// that way stays stale until the app is relaunched, because nothing else
    /// is ever going to ask again.
    @State private var builtShape: ShapeKey?
    @State private var pendingShape: ShapeKey?
    /// Where the camera has been asked to go — set when the driver arrives here
    /// from a stop row's "Auf der Karte zeigen". The camera itself lives in
    /// `RouteMapCanvas`, so this is a request rather than a position.
    ///
    /// It *stands* until it is answered: while it is set, the automatic
    /// re-frame stays out of the way, because the driven line finishes
    /// simplifying a moment after this tab opens and would otherwise pull the
    /// camera straight back off the pin the driver asked to see. Cleared by the
    /// "Ganze Route zeigen" button and by the map moving to another tour.
    @State private var pointAt: MapFocusRequest?
    /// Which route the map is currently built for, so a switch to another one
    /// can drop a focus request belonging to the old one.
    @State private var shownRouteID: UUID?

    private var route: Route? {
        routes.first { $0.id == focus.currentRouteID } ?? routes.first
    }

    /// The toilet whose pin was tapped. Its id is no stop's, so `selectedStop`
    /// is `nil` for it and the stop card stays away.
    private var selectedRestroom: RestroomPin? {
        selectedStopID.flatMap { Restroom.pinsByID[$0] }
    }

    private var selectedStop: Stop? {
        guard let selectedStopID, let route else { return nil }
        return route.stops.first { $0.id == selectedStopID }
    }

    /// The other driver's stops, once switched on and for the route shown.
    private var visibleOthers: [OtherPin] {
        showOthers && othersRouteID == route?.id ? others : []
    }

    private var selectedOther: OtherPin? {
        selectedStopID.flatMap { id in visibleOthers.first { $0.id == id } }
    }

    /// What changes the *shape* of the map — which route, which stops, what
    /// the driven line is. A change here re-fits the camera, because the thing
    /// being shown is genuinely different.
    ///
    /// Kept deliberately cheap to build. `Map(position:)` writes back to its
    /// binding on every frame of a pan or a zoom, so this body — and therefore
    /// this key and `styleKey` below — is rebuilt sixty times a second while
    /// the driver is moving the map. Ordering by `uuidString` is what that
    /// cannot afford: it allocates a 36-character string per comparison, so a
    /// hundred-stop tour spent well over a thousand string allocations per
    /// frame just deciding whether anything had changed. `idOrderedBefore`
    /// compares the raw bytes and allocates nothing.
    private var shapeKey: ShapeKey {
        guard let route else { return ShapeKey(route: nil, stops: [], geometry: []) }
        return ShapeKey(
            route: route.id,
            stops: route.stops
                .map {
                    ShapeKey.StopEntry(
                        id: $0.id,
                        kindRaw: $0.kindRaw,
                        orderIndex: $0.orderIndex,
                        lat: $0.lat,
                        lon: $0.lon,
                        title: $0.kind == .customer ? ($0.kunde ?? "Stopp") : $0.fixedTitle,
                        excluded: $0.excluded)
                }
                .sorted { UUID.idOrderedBefore($0.id, $1.id) },
            geometry: route.geometryFlat)
    }

    /// What changes only the *colour* of a pin: a delivery ticked off, a fixed
    /// stop switched out, an address re-checked into a better precision. These
    /// rebuild the pins but deliberately leave the camera alone — a tick in the
    /// Touren or Jetzt tab must not yank the map the driver is looking at.
    ///
    /// An explicit per-stop key rather than a count, so swapping which stop is
    /// delivered still registers. Reading these properties here is what
    /// subscribes the view to them in the first place, which is why a tick now
    /// reaches the map at all.
    private var styleKey: StyleKey {
        guard let route else { return StyleKey(entries: []) }
        return StyleKey(
            entries: route.stops
                .map {
                    StyleKey.Entry(
                        id: $0.id,
                        delivered: $0.delivered,
                        outcomeRaw: $0.outcomeRaw,
                        excluded: $0.excluded,
                        precisionRaw: $0.precisionRaw)
                }
                .sorted { UUID.idOrderedBefore($0.id, $1.id) })
    }

    private struct ShapeKey: Equatable {
        let route: UUID?
        let stops: [StopEntry]
        let geometry: [Double]

        struct StopEntry: Equatable {
            let id: UUID
            let kindRaw: String
            let orderIndex: Int
            let lat: Double
            let lon: Double
            let title: String
            let excluded: Bool
        }
    }

    private struct StyleKey: Equatable {
        let entries: [Entry]

        struct Entry: Equatable {
            let id: UUID
            let delivered: Bool
            /// In the key as well as `delivered`, because the two no longer
            /// move together: a door recorded as "nicht angetroffen" leaves
            /// `delivered` false and must still repaint its pin.
            let outcomeRaw: String?
            let excluded: Bool
            let precisionRaw: String?
        }
    }

    var body: some View {
        Group {
            if let route {
                map(for: route)
            } else {
                ContentUnavailableView(
                    "Keine Tour ausgewählt", systemImage: "map",
                    description: Text("Leg unter „Touren“ eine Tour an."))
            }
        }
        .navigationTitle(route?.name ?? "Karte")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title gets its own glass pill rather than relying on the bar
            // background. iOS 26 keeps a map's navigation bar transparent
            // whatever `toolbarBackgroundVisibility` asks for — which is right
            // for the map, but left plain black text sitting directly on the
            // tiles, illegible the moment the driver switched to Satellit.
            ToolbarItem(placement: .principal) {
                if let route {
                    Text(route.name)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Kartenstil", selection: $style) {
                        ForEach(MapStyleChoice.allCases) { s in
                            Label(s.label, systemImage: s.symbol).tag(s)
                        }
                    }
                    Divider()
                    Toggle("WCs anzeigen", systemImage: "toilet", isOn: $showRestrooms)
                    if hasPortalLogin {
                        Toggle(
                            visibleOthers.isEmpty
                                ? "Stopps der anderen"
                                : "Stopps der anderen (\(visibleOthers.count))",
                            systemImage: "person.2", isOn: $showOthers)
                    }
                    if routes.count > 1 {
                        Divider()
                        // Active tours, then the few most recently finished.
                        // Flat, this was every tour ever driven, newest first
                        // by creation — a menu that grew by a row a day, with
                        // today's tour one entry in a scrolling month of them.
                        let choices = pickerRoutes
                        Picker("Tour", selection: routeBinding) {
                            if !choices.active.isEmpty {
                                Section("Aktiv") {
                                    ForEach(choices.active) { r in
                                        Text(r.name).tag(Optional(r.id))
                                    }
                                }
                            }
                            if !choices.recent.isEmpty {
                                Section("Erledigt") {
                                    ForEach(choices.recent) { r in
                                        Text(r.name).tag(Optional(r.id))
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    // The bare glyph, like every other screen's menu. The
                    // toolbar already draws the glass circle around it, so
                    // `ellipsis.circle` came out as a circle in a circle.
                    Label("Optionen", systemImage: "ellipsis")
                }
            }
        }
        .sheet(item: sheetStop, onDismiss: cardDismissed) { tapped in
            let members = sharedPinMembers(of: tapped)
            let stop = chosenMemberID.flatMap { id in members.first { $0.id == id } }
                ?? (members.isEmpty ? tapped : nil)
            // Sized to what the stop actually has, not to a fixed guess. A
            // fixed height gave a customer with no Paket and no Notiz the same
            // card as one carrying both, leaving a band of empty material under
            // the button.
            Group {
                if let stop {
                    StopPreviewSheet(
                        stop: stop,
                        number: customerNumber(of: stop),
                        stockwerk: floor(for: stop),
                        onBack: members.count > 1
                            ? { chosenMemberID = nil } : nil,
                        onNavigate: { navigate(to: stop) },
                        onToggleDelivered: { toggleDelivered(stop) },
                        onShowInList: {
                            if let route { focus.reveal(stop: stop, of: route) }
                            selectedStopID = nil
                        },
                        // Zero is not a measurement. `onGeometryChange` reports
                        // the card's height as it is torn down too, and writing
                        // that back left the *next* pin's card opening as a
                        // sliver until its own first measure arrived.
                        onMeasure: { if $0 > 0 { previewHeight = $0 } })
                } else {
                    SharedPinSheet(
                        stops: members,
                        number: customerNumber(of:),
                        onPick: { chosenMemberID = $0.id },
                        onMeasure: { if $0 > 0 { previewHeight = $0 } })
                }
            }
                // Clamped, because "as tall as its content" has no upper bound
                // of its own: a Notiz can run to a thousand characters, and a
                // detent taller than a sheet is allowed to be simply clipped
                // the rest of the card — the two buttons included. Past the cap
                // the card scrolls instead.
                .presentationDetents([.height(min(previewHeight, Self.maxPreviewHeight))])
                .presentationBackground(.regularMaterial)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { selectedRestroom }, set: { if $0 == nil { selectedStopID = nil } })
        ) { pin in
            let marks = RestroomMarks.shared
            RestroomPreviewSheet(
                restroom: pin.restroom,
                bad: marks.isBad(pin.restroom),
                note: marks.note(for: pin.restroom),
                onNavigate: {
                    let r = pin.restroom
                    if let url = NavigationHandoff.provider.point(lat: r.lat, lon: r.lon) {
                        openURL(url)
                    }
                },
                onToggleBad: { marks.setBad(!marks.isBad(pin.restroom), pin.restroom) },
                onNote: { marks.setNote($0, for: pin.restroom) },
                onMeasure: { if $0 > 0 { restroomHeight = $0 } })
            .presentationDetents([.height(min(restroomHeight, Self.maxPreviewHeight))])
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { selectedOther }, set: { if $0 == nil { selectedStopID = nil } })
        ) { pin in
            OtherStopPreviewSheet(
                stop: pin.stop,
                onNavigate: {
                    if let url = NavigationHandoff.provider.point(
                        lat: pin.latitude, lon: pin.longitude)
                    {
                        openURL(url)
                    }
                },
                onMeasure: { if $0 > 0 { otherHeight = $0 } })
            .presentationDetents([.height(min(otherHeight, Self.maxPreviewHeight))])
            .presentationBackground(.regularMaterial)
            .presentationDragIndicator(.visible)
        }
        .stockwerkPrompt(for: $stockwerkStop)
        .errorAlert($error)
        .onAppear { hasPortalLogin = GourmetCredentialsStore.load() != nil }
        .onChange(of: showOthers) { _, on in
            if on {
                startLoadingOthers()
            } else {
                othersTask?.cancel()
                loadingOthers = false
                if selectedOther != nil { selectedStopID = nil }
            }
        }
        // Another tour is another portal tour: what was fetched for the last
        // one is somebody else's split.
        .onChange(of: route?.id) {
            othersTask?.cancel()
            loadingOthers = false
            showOthers = false
            others = []
            othersRouteID = nil
        }
    }

    /// Fetches the rest of the route's portal tour and puts it on the map.
    ///
    /// The tour comes from the link made when the route was (see
    /// `PortalTourLink`), or, for a route that has none, from its name and day.
    /// A failure switches the layer back off and says why, rather than leaving
    /// a toggle on that shows nothing.
    private func startLoadingOthers() {
        guard let route, let credentials = GourmetCredentialsStore.load() else {
            showOthers = false
            return
        }
        let routeID = route.id
        let mine = OtherStops.Mine(stops: route.stops)
        othersTask?.cancel()
        loadingOthers = true
        othersTask = Task {
            defer { loadingOthers = false }
            do {
                var link = PortalTourLink.load(for: routeID)
                if link == nil {
                    link = try await OtherStops.infer(for: route, credentials: credentials)
                    link?.save(for: routeID)
                }
                guard let link else {
                    showOthers = false
                    error = AppError.message(
                        "Diese Tour stammt nicht aus dem Zusteller-Portal — "
                            + "die Stopps der anderen sind von dort.")
                    return
                }
                let loaded = try await OtherStops.load(link: link, mine: mine, credentials: credentials)
                guard !Task.isCancelled else { return }
                others = loaded.compactMap(OtherPin.init)
                othersRouteID = routeID
                if loaded.isEmpty {
                    showOthers = false
                    error = AppError.message(
                        "Auf dieser Tour gibt es keine weiteren offenen Stopps.")
                }
            } catch is CancellationError {
            } catch let e as AppError {
                showOthers = false
                error = e
            } catch {
                showOthers = false
                self.error = AppError.message("Die Stopps der anderen konnten nicht geladen werden.")
            }
        }
    }

    /// The stop's position among the customers — the number its pin carries, so
    /// the card the pin opens is recognisably about that pin.
    ///
    /// Read back off the pin that was tapped rather than recomputed: the
    /// numbering was worked out once when the pins were built, and asking the
    /// route again re-sorted every stop on it to arrive at the same answer.
    private func customerNumber(of stop: Stop) -> Int? {
        numbers[stop.id]
    }

    /// Every customer under the pin this stop heads, in stop order — or empty
    /// when it is an ordinary pin of its own, or when the card was opened for
    /// one particular stop rather than by tapping a shared pin.
    private func sharedPinMembers(of stop: Stop) -> [Stop] {
        guard let pin = pins.first(where: { $0.id == stop.id }), pin.memberIDs.count > 1,
              let route
        else { return [] }
        return pin.memberIDs.compactMap { id in route.stops.first { $0.id == id } }
    }

    private func navigate(to stop: Stop) {
        guard let url = NavigationHandoff.url(for: stop) else { return }
        openURL(url)
    }

    private func toggleDelivered(_ stop: Stop) {
        // Lager and Ziel too, the same as their rows and Jetzt.
        guard stop.countsAsStop else { return }
        // Off whatever it was settled as, not off `delivered` alone: a door
        // recorded as "nicht angetroffen" has `delivered` false, so this tick
        // used to turn it into a delivery rather than re-opening it.
        let nowDelivered = !stop.isSettled
        do {
            try RouteStore.setDelivered(stop, nowDelivered, in: context)
        } catch {
            // The same tick as in the stop list, and it reports itself the same
            // way there. Swallowed here, a failed write left the circle
            // apparently unresponsive.
            self.error = AppError.message("Konnte den Lieferstatus nicht speichern.")
            return
        }
        guard nowDelivered, StockwerkStore.shouldAsk(stop, in: context) else { return }
        askForStockwerk(stop)
    }

    /// This door's floor, read off the notes the query already holds rather
    /// than fetched again — and, being the query's own data, it redraws the
    /// card the moment the prompt writes an answer.
    private func floor(for stop: Stop) -> String? {
        guard let key = StockwerkKey.make(for: stop) else { return nil }
        let value = stockwerkNotes.first { $0.key == key }?.stockwerk?.trimmed
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// The floor question, asked from the map.
    ///
    /// The pin's own card is a sheet, and one sheet cannot open over another —
    /// so the card is closed and the question is left waiting for it. The
    /// handover is the card's own `onDismiss` rather than a timer: a fixed wait
    /// is a guess about an animation, and the guess is wrong in both
    /// directions — too short and the presentation is swallowed and the
    /// customer is never asked, too long and the question arrives on whatever
    /// screen the driver has moved to since.
    private func askForStockwerk(_ stop: Stop) {
        pendingStockwerkStop = stop
        selectedStopID = nil
    }

    /// Called when the pin's card has finished closing.
    ///
    /// Nothing is asked if the driver has left the map in the meantime: this
    /// sheet belongs to a tab that stays alive behind the others, and a
    /// question presented on it would sit there unseen and ambush them the next
    /// time they opened Karte, about a customer they finished several stops
    /// ago. The floor is not lost — the customer is simply asked about at the
    /// next delivery, which is what `shouldAsk` already says.
    private func cardDismissed() {
        chosenMemberID = nil
        guard let stop = pendingStockwerkStop else { return }
        pendingStockwerkStop = nil
        guard focus.tab == .map else { return }
        stockwerkStop = stop
    }

    private var sheetStop: Binding<Stop?> {
        Binding(get: { selectedStop }, set: { if $0 == nil { selectedStopID = nil } })
    }

    /// What the tour picker offers: every active tour and the five most
    /// recently created finished ones — plus whichever tour the map is showing,
    /// so the picker always has a tick to put somewhere.
    private var pickerRoutes: (active: [Route], recent: [Route]) {
        let active = routes.filter { $0.status == .active }
        var recent = Array(routes.filter { $0.status == .completed }.prefix(5))
        if let shown = route, shown.status == .completed,
           !recent.contains(where: { $0.id == shown.id }) {
            recent.append(shown)
        }
        return (active, recent)
    }

    /// Choosing a tour here focuses it app-wide, exactly as opening it in
    /// Touren does — an active one becomes the tour being worked, a finished
    /// one is only looked at. See `RouteFocus.focus`.
    private var routeBinding: Binding<UUID?> {
        Binding(
            get: { focus.currentRouteID ?? routes.first?.id },
            set: { id in
                if let picked = routes.first(where: { $0.id == id }) { focus.focus(picked) }
            })
    }

    @ViewBuilder
    private func map(for route: Route) -> some View {
        RouteMapCanvas(
            line: line,
            pins: pins,
            restrooms: showRestrooms ? Restroom.pins : [],
            others: visibleOthers,
            style: style,
            // A tap on a pin starts at that pin's list again, not at whichever
            // customer was last looked at under it.
            selection: Binding(
                get: { selectedStopID },
                set: { selectedStopID = $0; chosenMemberID = nil }),
            fitToken: fitToken,
            followToken: focus.mapFollowToken,
            pointAt: $pointAt)
            .onChange(of: shapeKey, initial: true) { reconcile(route) }
            .onChange(of: styleKey) { rebuildPins(for: route) }
            // Arriving from a stop row in the list. `initial: true` because the
            // request is usually already standing by the time this tab is built
            // for the first time — the tap that set it is also what switched
            // tabs to here.
            .onChange(of: focus.mapStopID, initial: true) { _, id in
                guard let id, let stop = route.stops.first(where: { $0.id == id })
                else { return }
                // Cleared immediately, so this fires once rather than on every
                // redraw — and so returning to the map later does not silently
                // re-aim it at a stop the driver has long since moved on from.
                focus.mapStopID = nil
                pointAt = MapFocusRequest(stop: stop, sequence: (pointAt?.sequence ?? 0) + 1)
                selectedStopID = id
                // Sent here for this one stop, so its card — not the list of
                // everyone who shares its pin.
                chosenMemberID = id
            }
            // `onChange` only fires if the body was evaluated, and a tab sitting
            // in the background is not guaranteed to be — so coming back to this
            // tab checks for itself rather than trusting that it was told.
            .onAppear { reconcile(route) }
            // The permission prompt the blue dot needs. Nothing else in the app
            // asks for it, and the map is the one place it means anything.
            .task { LocationAuthorization.shared.requestIfNeeded() }
            .overlay(alignment: .top) { statusBanner }
    }

    /// Says the two things the map would otherwise stay quiet about: that the
    /// line is still being drawn, and that the location button will never do
    /// anything because the permission was refused.
    @ViewBuilder
    private var statusBanner: some View {
        Group {
            if loadingOthers {
                MapNotice(text: "Stopps der anderen werden geladen …", busy: true)
            } else if buildingLine && line.isEmpty {
                MapNotice(text: "Route wird gezeichnet …", busy: true)
            } else if LocationAuthorization.shared.isDenied {
                Button {
                    LocationAuthorization.shared.openSettings()
                } label: {
                    MapNotice(
                        text: "Standort aus — in Einstellungen erlauben",
                        compact: "Standort aus",
                        busy: false)
                }
                .buttonStyle(.plain)
                // The full sentence, whichever one is drawn: the short form
                // exists to keep the pill off the map, not to tell a VoiceOver
                // user less about what tapping it does.
                .accessibilityLabel("Standort aus")
                .accessibilityHint("Doppeltippen, um den Standort in den Einstellungen zu erlauben")
            }
        }
        .padding(.top, 8)
        // Clear of MapKit's own controls, which it draws in the trailing corner
        // of this same overlay space and which this notice ran straight into:
        // the pill sized itself to its sentence, the sentence is a long one,
        // and the right-hand end of it sat underneath the user-location button.
        // Two controls in one place, neither fully tappable. Inset on both
        // sides rather than only the trailing one, so the pill stays centred
        // over the map instead of drifting left of it.
        .padding(.horizontal, 56)
    }

    // MARK: - Building the map content

    /// Derives the polyline and the pins from the route.
    ///
    /// Shape changes are allowed to re-fit the camera. Style-only changes use
    /// `rebuildPins(for:)` so ticking a stop does not re-simplify thousands of
    /// polyline points or move the map underneath the driver.
    /// Rebuilds the pins immediately and the driven line in the background.
    ///
    /// The simplification is the expensive part — OSRM's full-overview geometry
    /// is ~600 points per leg, so a thirty-stop tour is several thousand points
    /// through Ramer–Douglas–Peucker — and it used to run synchronously inside
    /// the first body evaluation of the map. MapKit's own cold start and this
    /// then landed on the main thread together, and opening the Karte tab froze
    /// the app for as long as the two took. The map and its pins appear at once
    /// now; the line follows a moment later, with a notice while it does.
    /// Brings the map up to date with the route, and does nothing if it already
    /// is.
    ///
    /// Called both from `onChange` and from `onAppear`, which is the point:
    /// either one alone can miss, and between them they cannot. A shape already
    /// drawn — or already being drawn — costs a pin rebuild, which is cheap by
    /// design; anything else is genuinely out of date and gets redrawn.
    private func reconcile(_ route: Route) {
        let shape = shapeKey
        guard shape != builtShape, shape != pendingShape else {
            // The line is current. Colours may still have moved — a delivery
            // ticked off in Touren or Jetzt is exactly the change that reaches
            // here without altering the shape of anything.
            rebuildPins(for: route)
            return
        }
        rebuildRoute(route, shape: shape)
    }

    private func rebuildRoute(_ route: Route, shape: ShapeKey) {
        pendingShape = shape
        // A focus request belongs to the tour it was made from: showing a
        // different one is a different question, and gets the whole-route
        // framing every other route change gets. Only when moving *between*
        // tours, though — on the very first build there is no previous route,
        // and a request made from the stop list arrives around the same moment
        // as this does, so clearing on `nil` would throw away the very request
        // that opened this tab, depending on which handler happened to run
        // first.
        if let shown = shownRouteID, shown != route.id { pointAt = nil }
        shownRouteID = route.id
        rebuildPins(for: route)

        let flat = route.geometryFlat
        lineGeneration += 1
        let generation = lineGeneration

        // Do not leave yesterday's line on screen while its replacement is
        // being prepared.  Besides being misleading after a deletion, MapKit
        // can briefly reuse the old overlay's stroke during that transition,
        // which is why the route sometimes looked grey.  Pins were already
        // rebuilt above, so the map remains useful while the accurate line is
        // calculated off the main actor.
        line = []

        guard flat.count >= 4 else {
            line = []
            buildingLine = false
            builtShape = shape
            pendingShape = nil
            fitToken += 1
            return
        }

        buildingLine = true
        Task.detached(priority: .userInitiated) {
            let simplified = Self.simplifiedLine(flat: flat, tolerance: 0.00002)
            await MainActor.run {
                // A newer rebuild has already started; this answer is stale.
                // Nothing is recorded as drawn, so if that newer one somehow
                // never lands, the next `reconcile` still sees the shape as
                // undrawn and tries again rather than believing a line it never
                // put on screen.
                guard generation == lineGeneration else { return }
                line = simplified
                buildingLine = false
                builtShape = shape
                pendingShape = nil
                fitToken += 1
            }
        }
    }

    /// Decodes the flat `[lat, lon, …]` buffer and simplifies it. `nonisolated`,
    /// and taking plain `Double`s rather than a `Route`, so the whole thing can
    /// run off the main actor with no SwiftData object anywhere near it.
    nonisolated static func simplifiedLine(
        flat: [Double], tolerance: Double
    ) -> [CLLocationCoordinate2D] {
        guard flat.count >= 4 else { return [] }
        var points: [CLLocationCoordinate2D] = []
        points.reserveCapacity(flat.count / 2)
        for i in stride(from: 0, to: flat.count - 1, by: 2) {
            points.append(
                CLLocationCoordinate2D(latitude: flat[i], longitude: flat[i + 1]))
        }
        return simplified(points, tolerance: tolerance)
    }

    /// Derives only the annotations. This is intentionally cheap enough to run
    /// for a delivery tick, address precision change, or tab re-entry.
    private func rebuildPins(for route: Route) {
        let ordered = route.orderedStops

        // Numbered once, up front. Asking each marker for its own index meant
        // re-sorting and re-scanning the whole route per marker.
        var number: [UUID: Int] = [:]
        var n = 0
        for stop in ordered where stop.kind == .customer {
            n += 1
            number[stop.id] = n
        }

        // The destination is dropped when it sits on the depot — which it does
        // on every default route, both being Petritschgasse 24. Two markers on
        // one coordinate gave a single visible pin wearing Ziel's checkered flag
        // under Start's label, which reads as a bug.
        let start = ordered.first { $0.kind == .start && !$0.excluded }
        let end = ordered.first { $0.kind == .end && !$0.excluded }
        let endIsOnStart = start != nil && end != nil && Self.sameSpot(start!, end!)

        // Customers at the same spot share one pin. Drawn separately, the
        // markers sat exactly on top of each other and only the last one could
        // be seen or tapped — two households in one building looked like one.
        var sharing: [UUID: [Stop]] = [:]
        var underAnother: Set<UUID> = []
        var heads: [Stop] = []
        for stop in ordered where stop.kind == .customer {
            if let head = heads.first(where: { Self.overlaps($0, stop) }) {
                sharing[head.id, default: [head]].append(stop)
                underAnother.insert(stop.id)
            } else {
                heads.append(stop)
            }
        }

        var built: [MapPin] = []
        built.reserveCapacity(ordered.count)
        for stop in ordered {
            guard !stop.excluded, !underAnother.contains(stop.id) else { continue }
            if endIsOnStart, stop.kind == .end { continue }

            if let members = sharing[stop.id] {
                // Coloured by whoever still needs something: an open door
                // first, then one nobody answered, and green only once every
                // meal under it is handed over.
                let lead = members.first { !$0.isSettled }
                    ?? members.first { $0.outcome?.needsFollowUp == true }
                    ?? stop
                built.append(
                    MapPin(
                        id: stop.id,
                        visualState: Self.visualState(for: lead),
                        coordinate: stop.coordinate,
                        title: members.map { $0.kunde ?? "Stopp" }.joined(separator: " · "),
                        monogram: number[stop.id].map { "\($0)+" },
                        symbol: Self.symbol(for: .customer),
                        tint: Self.tint(for: lead),
                        memberIDs: members.map(\.id)))
                continue
            }

            let title: String
            if stop.kind == .customer {
                title = stop.kunde ?? "Stopp"
            } else if stop.kind == .start, endIsOnStart {
                title = "Start · Ziel"
            } else {
                title = stop.fixedTitle
            }

            built.append(
                MapPin(
                    id: stop.id,
                    visualState: Self.visualState(for: stop),
                    coordinate: stop.coordinate,
                    title: title,
                    monogram: number[stop.id].map(String.init),
                    symbol: Self.symbol(for: stop.kind),
                    tint: Self.tint(for: stop)))
        }

        pins = built
        numbers = number
    }

    /// Ramer–Douglas–Peucker. Keeps the corners that define the shape of the
    /// route and drops the points that only sit along a straight run.
    ///
    /// Longitude is scaled by the cosine of Vienna's latitude so the tolerance
    /// means the same distance in both directions — unscaled, a degree of
    /// longitude here is only about two thirds of a degree of latitude, and the
    /// line would be simplified more aggressively east-west than north-south.
    ///
    /// Iterative rather than recursive: this runs over several thousand points,
    /// and a pathological input should not be able to blow the stack.
    nonisolated static func simplified(
        _ points: [CLLocationCoordinate2D], tolerance: Double
    ) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }

        let lonScale = cos(48.2 * .pi / 180)
        func x(_ c: CLLocationCoordinate2D) -> Double { c.longitude * lonScale }
        func y(_ c: CLLocationCoordinate2D) -> Double { c.latitude }

        /// Perpendicular distance from `p` to the segment `a`–`b`.
        func distance(
            _ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
            _ b: CLLocationCoordinate2D
        ) -> Double {
            let dx = x(b) - x(a), dy = y(b) - y(a)
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(x(p) - x(a), y(p) - y(a)) }
            // Clamped so a point beyond either end measures to the endpoint
            // rather than to the infinite line.
            var t = ((x(p) - x(a)) * dx + (y(p) - y(a)) * dy) / lengthSquared
            t = min(max(t, 0), 1)
            return hypot(x(p) - (x(a) + t * dx), y(p) - (y(a) + t * dy))
        }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var worst = 0.0
            var index = first
            for i in (first + 1)..<last {
                let d = distance(points[i], points[first], points[last])
                if d > worst { worst = d; index = i }
            }
            guard worst > tolerance else { continue }
            keep[index] = true
            stack.append((first, index))
            stack.append((index, last))
        }

        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// Close enough that the two markers would be drawn on top of each other
    /// at any zoom a driver uses: about ten metres. Wide enough for one
    /// address written two ways, tight enough that the house next door keeps
    /// a pin of its own.
    private static func overlaps(_ a: Stop, _ b: Stop) -> Bool {
        let ca = a.coordinate, cb = b.coordinate
        let dLat = (ca.latitude - cb.latitude) * 111_000
        let dLon = (ca.longitude - cb.longitude) * 111_000 * cos(ca.latitude * .pi / 180)
        return dLat * dLat + dLon * dLon < 10 * 10
    }

    /// Within about a metre — the precision at which two pins are one pin.
    private static func sameSpot(_ a: Stop, _ b: Stop) -> Bool {
        abs(a.lat - b.lat) < 0.00001 && abs(a.lon - b.lon) < 0.00001
    }

    /// Green once the meal is handed over, amber for a door nobody opened or a
    /// location that is only approximate, otherwise the accent. The colour
    /// carries the same meaning it does in the list, and the depot and via
    /// points stay grey: they are the shape of the tour, not stops with a state
    /// to change.
    ///
    /// A cancelled stop goes grey with the fixtures, which is what it has
    /// become — a point on the route with nothing owed at it.
    private static func tint(for stop: Stop) -> Color {
        guard stop.kind == .customer else { return .fixture }
        if let outcome = stop.outcome {
            if outcome.handedOver { return .delivered }
            return outcome.needsFollowUp ? .attention : .fixture
        }
        if stop.precision != nil { return .attention }
        // MapKit may resolve `accentColor` from a transient annotation host
        // while it diffs a large set of markers, which falls back to grey.
        // The app's accent is deliberately blue, so state that directly for
        // map content rather than inheriting that host's tint.
        return .blue
    }

    private static func visualState(for stop: Stop) -> Int {
        guard stop.kind == .customer else { return 0 }
        if let outcome = stop.outcome { return outcome.handedOver ? 2 : 3 }
        if stop.precision != nil { return 1 }
        return 0
    }

    private static func symbol(for kind: StopKind) -> String {
        switch kind {
        case .start: "house.fill"
        case .via: "shippingbox.fill"
        case .end: "flag.checkered"
        case .customer: "mappin"
        }
    }
}

/// The map itself, and nothing else.
///
/// Split out from `MapTab` for one specific reason: `Map(position:)` writes back
/// to its binding continuously while the driver pans, so whichever view owns the
/// camera has its body re-evaluated on every frame of every gesture. `MapTab`
/// owns the SwiftData query and derives its change keys from it — which is
/// exactly the work that must not run sixty times a second. With the camera down
/// here, panning re-evaluates only this view, whose inputs are already-derived
/// plain values.
private struct RouteMapCanvas: View {
    let line: [CLLocationCoordinate2D]
    let pins: [MapPin]
    /// Every public toilet, when the driver has asked to see them.
    let restrooms: [RestroomPin]
    /// The other driver's stops, when the driver has asked to see them.
    let others: [OtherPin]
    let style: MapStyleChoice
    @Binding var selection: UUID?
    /// Changes whenever the route's shape has been rebuilt and the view should
    /// frame the whole thing again.
    let fitToken: Int
    /// Changes every time the driver chooses Karte from the tab bar — the cue
    /// to put the camera back on them. See `RouteFocus.select`.
    let followToken: Int
    /// One stop to zoom to, or `nil` for the ordinary "show the whole tour"
    /// behaviour. Cleared from in here when the driver asks for the whole route
    /// again — that button is how they take the camera back.
    @Binding var pointAt: MapFocusRequest?

    @State private var camera: MapCameraPosition = .automatic
    /// The driver has not yet sent the camera anywhere of their own — so as
    /// soon as Core Location has something to say, it belongs on them.
    ///
    /// Needed because the permission prompt and the first open of this tab are
    /// the same moment on a fresh install: aiming at the driver right then aims
    /// at nothing, and without this the map would settle on the whole tour and
    /// stay there for the one session where the driver was told the app wanted
    /// their location.
    @State private var wantsDriver = true
    /// Zoomed in far enough to draw the map in 3D — see `mapStyle(closeIn:)`.
    @State private var closeIn = false

    var body: some View {
        Map(position: $camera, selection: $selection) {
            UserAnnotation()

            if line.count >= 2 {
                // Casing first, then the line itself on top of it.
                MapPolyline(coordinates: line)
                    .stroke(
                        Color.routeCasing,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line)
                    .stroke(
                        Color.blue,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            ForEach(pins, id: \.annotationID) { pin in
                if let monogram = pin.monogram {
                    Marker(pin.title, monogram: Text(verbatim: monogram), coordinate: pin.coordinate)
                        .tint(pin.tint)
                        .tag(pin.id)
                } else {
                    Marker(pin.title, systemImage: pin.symbol, coordinate: pin.coordinate)
                        .tint(pin.tint)
                        .tag(pin.id)
                }
            }

            // Tagged with the pin's own id, which is no stop's: a tap opens
            // the toilet's card rather than a stop's.
            //
            // Identified by the mark as well as the pin, for the reason
            // `MapPin.annotationID` gives: MapKit keeps a marker it already
            // has, tint and all, so a toilet just marked stayed its old
            // colour until the map was built again.
            let bad = RestroomMarks.shared.bad
            ForEach(restrooms.map { RestroomDot(pin: $0, bad: bad.contains($0.key)) }) { dot in
                Marker(
                    dot.pin.restroom.label, systemImage: "toilet.fill",
                    coordinate: CLLocationCoordinate2D(
                        latitude: dot.pin.restroom.lat, longitude: dot.pin.restroom.lon))
                    .tint(dot.bad ? Color.restroomBad : Color.restroom)
                    .tag(dot.pin.id)
            }

            // Tagged with the stop's own id, which is no route stop's: a tap
            // opens its card, not a stop card.
            ForEach(others) { pin in
                Marker(pin.stop.name, systemImage: "person.fill", coordinate: pin.coordinate)
                    .tint(Color.otherDriver)
                    .tag(pin.id)
            }
        }
        .mapStyle(style.mapStyle(closeIn: closeIn))
        // Only written when it flips, so a pan does not rebuild the style on
        // every frame.
        .onMapCameraChange(frequency: .continuous) { context in
            let distance = context.camera.distance
            // Two thresholds, so hovering around one does not flip the style
            // back and forth.
            if !closeIn, distance < 3_500 { closeIn = true }
            if closeIn, distance > 4_500 { closeIn = false }
        }
        // Explicitly blue rather than inherited, even though the app's accent
        // is now blue too. This is the colour a user-location dot is on every
        // map anyone has ever used — the same pairing Apple Maps ships, where
        // the route and the dot are both blue and the white ring is what tells
        // them apart — and stating it here means a future change of accent
        // cannot quietly recolour the driver's own position.
        .tint(.blue)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onChange(of: fitToken, initial: true) {
            // A stop the driver has just asked to see outranks the automatic
            // re-frame: the line finishing its simplification a moment later
            // must not pull the camera back out to the whole tour.
            //
            // It outranks exactly *one* of them, though, and then stands down.
            // Left standing — which is what it did — a request made once from a
            // stop row suppressed every automatic re-frame for the rest of the
            // tour's life on this tab: re-optimising the route redrew the line
            // under a camera that never moved to fit it, and the only way back
            // was the "Ganze Route zeigen" button, which is not something a
            // driver knows they need to press. Suppressing the one re-frame the
            // request was made to survive is the whole job.
            guard pointAt == nil else {
                pointAt = nil
                return
            }
            // The camera is on the driver — because they opened this tab, or
            // because they pressed the location button. Re-framing the tour
            // would take it straight back off them, and the line finishes
            // simplifying a moment after this tab opens, so that is exactly
            // what it did. Unlike the stop request above this does not stand
            // down after one: it lasts precisely as long as the camera is
            // actually following, and the first pan ends it.
            guard !camera.followsUserLocation else { return }
            // And the same again for the half-second before the camera gets
            // there. The first fix and the finished polyline arrive within a
            // moment of each other in either order, so on the open where the
            // line won the race it re-framed the tour *after* the camera had
            // been put on the driver — and the driver got the whole of Vienna,
            // intermittently, for no reason they could see.
            guard !(wantsDriver && LocationAuthorization.shared.hasFix) else { return }
            fit()
        }
        // Choosing Karte from the tab bar. The map is opened standing in front
        // of a Gemeindebau, to work out which of its four sides the entrance is
        // on; the shape of the tour is not the question, and having to find and
        // press the location button first is the difference between an answer
        // and a fumble in the rain.
        .onChange(of: followToken) {
            wantsDriver = true
            aimAtDriver()
        }
        // A fresh install answers the permission prompt *after* the map is
        // already up, so the first fix arrives with nobody left asking for it.
        // This is that ask, still standing — and it waits for the fix rather
        // than for the permission, because a camera aimed at the driver the
        // instant they tap "Allow" is aimed at nothing and stays that way.
        .onChange(of: LocationAuthorization.shared.hasFix, initial: true) {
            guard wantsDriver else { return }
            aimAtDriver()
        }
        // A pin the driver tapped is a place they chose to look at, and it
        // outranks the standing "show me where I am" exactly the way a stop
        // sent over from the list does. Left armed, the first fix arriving a
        // second after the tap swung the camera off to the driver — leaving
        // the card open on a customer whose pin was now off the screen.
        .onChange(of: selection) { _, picked in
            if picked != nil { wantsDriver = false }
        }
        // Switching the other driver's stops on is asking to see both halves
        // at once, so the camera frames them together.
        .onChange(of: others.isEmpty) { _, empty in
            guard !empty else { return }
            pointAt = nil
            wantsDriver = false
            fit()
        }
        .onChange(of: pointAt, initial: true) { _, request in
            guard let request else { return }
            wantsDriver = false
            // Close enough to read the street the door is on, wide enough to
            // see the stops either side of it.
            let span = 0.006
            withAnimation(.easeInOut) {
                camera = .region(
                    MKCoordinateRegion(
                        // Aimed *south* of the pin, which puts the pin in the
                        // upper part of the map. Arriving here always opens the
                        // stop's card over the bottom of the screen, and a pin
                        // centred in the full map rect lands underneath it —
                        // the driver is then looking at a card describing a
                        // pin they cannot see.
                        center: CLLocationCoordinate2D(
                            latitude: request.coordinate.latitude - span * 0.2,
                            longitude: request.coordinate.longitude),
                        span: MKCoordinateSpan(
                            latitudeDelta: span, longitudeDelta: span)))
            }
        }
        // Once the driver has panned off to look at one corner of the tour
        // there was no way back to the whole route short of leaving the tab and
        // coming back. Bottom-trailing, where Apple Maps keeps its own map
        // controls and where a thumb on a phone held in one hand can reach.
        .overlay(alignment: .bottomTrailing) {
            Button {
                pointAt = nil
                wantsDriver = false
                fit()
            } label: {
                // The `contentShape` is the whole 44pt disc, not just the
                // glyph: a miss over a map is a pan, so a control here has to
                // be the size it looks.
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.borderless)
            .glassEffect(.regular, in: .circle)
            .accessibilityLabel("Ganze Route zeigen")
            .padding(.trailing, 14)
            .padding(.bottom, 14)
            .safeAreaPadding(.bottom)
        }
    }

    /// Puts the camera on the driver, if there is a driver to put it on.
    ///
    /// Gated on there being a fix rather than left to `fallback:` to sort out.
    /// A `.userLocation` position reports itself as following whether or not
    /// Core Location will ever answer it, so on a phone where the permission
    /// was refused an ungated one would both sit on its fallback *and* switch
    /// off the whole-route re-frame above — leaving the driver looking at
    /// whatever `.automatic` makes of an empty map, permanently.
    private func aimAtDriver() {
        guard LocationAuthorization.shared.hasFix else { return }
        // Assigned flat, not inside `withAnimation`. A tracking position is a
        // *mode*, not a place, and there is nothing for SwiftUI to interpolate
        // towards: wrapped in an animation the assignment was accepted —
        // `followsUserLocation` came back true — and the map never moved.
        camera = .userLocation(fallback: .automatic)
    }

    /// Frames the whole tour. Prefers the driven line over the pins, so the
    /// view covers the road actually taken rather than just the doors on it.
    private func fit() {
        let points = (line.isEmpty ? pins.map(\.coordinate) : line) + others.map(\.coordinate)
        guard let region = MKCoordinateRegion(fitting: points) else { return }
        withAnimation(.easeInOut) { camera = .region(region) }
    }
}

/// "Put the camera on this stop." A plain value rather than a coordinate, so
/// the same stop asked for twice still counts as a change and moves the map
/// back — the driver panned away in between, and asking again is exactly how
/// they say so.
struct MapFocusRequest: Equatable {
    let latitude: Double
    let longitude: Double
    let sequence: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(stop: Stop, sequence: Int) {
        let c = stop.coordinate
        self.latitude = c.latitude
        self.longitude = c.longitude
        self.sequence = sequence
    }
}

/// A small glass pill at the top of the map — the only chrome allowed to
/// interrupt it, and only for something the driver can act on or is waiting for.
private struct MapNotice: View {
    let text: String
    /// The short form, used once the driver's text size makes the long one a
    /// blob. This pill sits over the map and sizes to its sentence, so at an
    /// accessibility size the permission notice grew to four lines and covered
    /// a quarter of the tour — a banner about a button the driver is not using
    /// hiding the route they are.
    var compact: String?
    let busy: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "location.slash.fill")
                    .foregroundStyle(Color.attention)
            }
            Text(typeSize.isAccessibilitySize ? (compact ?? text) : text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(3)
                // Wraps inside the space it is given rather than pushing the
                // pill wider than that space — which is the whole point of the
                // insets the caller puts around it.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
    }
}

/// One of the other driver's stops, placed on the map. Its id is made from the
/// portal's delivery id, so it is the same pin every time the layer is switched
/// on and a tap can be matched back to it.
private struct OtherPin: Identifiable, Equatable {
    let id: UUID
    let stop: OtherStop
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// `nil` for a stop no address lookup could place.
    init?(_ stop: OtherStop) {
        guard let latitude = stop.latitude, let longitude = stop.longitude else { return nil }
        self.stop = stop
        self.latitude = latitude
        self.longitude = longitude
        self.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012ld", stop.id))
            ?? UUID()
    }
}

/// The card an other-driver pin opens: who and where, the Notiz and the phone
/// number as the portal has them, and the way there.
private struct OtherStopPreviewSheet: View {
    let stop: OtherStop
    let onNavigate: () -> Void
    let onMeasure: (CGFloat) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.otherDriver))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .font(.title3.bold())
                        Text("\(stop.address), \(stop.plz)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Gehört zur Tour, aber nicht zu deiner Route")
                            .font(.footnote)
                            .foregroundStyle(Color.otherDriver)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                }
                if let notiz = stop.notiz {
                    StopFacts.note(notiz, lineLimit: 12)
                        .font(.callout)
                }
                if let telefon = stop.telefon {
                    Label(telefon, systemImage: "phone")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(action: onNavigate) {
                    WideButtonLabel("Navigation", systemImage: "arrow.trianglehead.turn.up.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeAreaPadding(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onMeasure($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .symbolRenderingMode(.monochrome)
    }
}

/// A toilet's pin together with how it is drawn — see where it is used.
private struct RestroomDot: Identifiable {
    struct ID: Hashable {
        let pin: UUID
        let bad: Bool
    }

    let pin: RestroomPin
    let bad: Bool
    var id: ID { ID(pin: pin.id, bad: bad) }
}

/// The card a toilet's pin opens: which one, whether it is open, the driver's
/// own note on it, and the way there — the stop card's layout.
private struct RestroomPreviewSheet: View {
    let restroom: Restroom
    /// The driver marked it as no good — see `RestroomMarks`.
    let bad: Bool
    let note: String?
    let onNavigate: () -> Void
    let onToggleBad: () -> Void
    let onNote: (String) -> Void
    let onMeasure: (CGFloat) -> Void

    @State private var editingNote = false
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "toilet.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(bad ? Color.restroomBad : Color.restroom))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(restroom.label)
                            .font(.title3.bold())
                        Text(restroom.name)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(facts)
                            .font(.footnote)
                            .foregroundStyle(
                                bad ? Color.restroomBad : isOpen ? Color.secondary : Color.attention)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 8)
                }
                if let note {
                    StopFacts.note(note, lineLimit: 12)
                        .font(.callout)
                }
                VStack(spacing: 10) {
                    Button(action: onNavigate) {
                        WideButtonLabel("Navigation", systemImage: "arrow.trianglehead.turn.up.right")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: onToggleBad) {
                        WideButtonLabel(
                            bad ? "Doch brauchbar" : "Als unbrauchbar markieren",
                            systemImage: bad ? "arrow.uturn.backward" : "hand.thumbsdown")
                    }
                    .buttonStyle(.bordered)
                    .tint(bad ? Color.restroom : Color.restroomBad)
                    Button {
                        draft = note ?? ""
                        editingNote = true
                    } label: {
                        WideButtonLabel(
                            note == nil ? "Notiz hinzufügen" : "Notiz ändern",
                            systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeAreaPadding(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onMeasure($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .symbolRenderingMode(.monochrome)
        // Saved empty, the note is removed — there is no separate delete.
        .alert("Notiz", isPresented: $editingNote) {
            TextField("z. B. Code, Zustand, Zugang", text: $draft)
            Button("Sichern") { onNote(draft) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Nur für dich, zu diesem WC. Leer sichern entfernt sie.")
        }
    }

    private var isOpen: Bool { restroom.isOpen(at: Date()) }

    /// "Geöffnet · 40 m zu Fuß".
    private var facts: String {
        let open = bad ? "Als unbrauchbar markiert"
            : isOpen ? "Geöffnet" : "Jetzt geschlossen"
        return restroom.walk >= 30 ? "\(open) · \(restroom.walk) m zu Fuß" : open
    }
}

/// One marker, as a plain value. MapKit's own balloon rather than a custom
/// circle: a circle marks an area, a balloon marks a *point* — its tip is the
/// coordinate, so the driver can tell which side of the street a stop is on.
private struct MapPin: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// The stop number, for a customer. `nil` on a fixed point, which carries a
    /// symbol instead.
    let monogram: String?
    let symbol: String
    let tint: Color
    let latitude: Double
    let longitude: Double
    /// Every customer this pin stands for, in stop order. One, except where
    /// several share a spot — see `MapTab.rebuildPins`.
    let memberIDs: [UUID]

    /// The `ForEach` identity: **everything this pin draws**, not just which
    /// stop it is.
    ///
    /// It used to be the stop's id and its colour, which left the number out —
    /// and the number is the one thing about a marker that changes without the
    /// stop itself changing at all. Delete a customer and every stop behind it
    /// renumbers; their ids and colours do not move, so `ForEach` saw no
    /// change, reused the markers it already had, and left them drawing the
    /// numbers they were built with. The map then showed a tour with two stop
    /// 2s and no stop 3 — numbers that disagreed with the list beside them,
    /// which on a map whose whole job is "which pin is my next door" is worse
    /// than showing nothing.
    ///
    /// So the identity now covers the title, the monogram or symbol, the tint
    /// (via `visualState`) and the coordinate — the four things `Marker` puts
    /// on screen. Anything that changes what is drawn changes this, and the
    /// marker is rebuilt.
    ///
    /// Stored, not computed. `RouteMapCanvas`'s body is re-evaluated on every
    /// frame of a pan — that is the whole reason it is a separate view — and a
    /// computed identity meant string interpolation *per pin per frame*: on a
    /// hundred-stop tour, twelve thousand allocations a second, thrown away
    /// immediately. Built once, when the pins are.
    let annotationID: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(
        id: UUID, visualState: Int, coordinate: CLLocationCoordinate2D,
        title: String, monogram: String?, symbol: String, tint: Color,
        memberIDs: [UUID]? = nil
    ) {
        self.id = id
        self.memberIDs = memberIDs ?? [id]
        self.title = title
        self.monogram = monogram
        self.symbol = symbol
        self.tint = tint
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        // Coordinates rounded to about a metre: the same door re-geocoded can
        // come back a few billionths of a degree away, and that is not a pin
        // that needs rebuilding.
        let lat = Int((coordinate.latitude * 100_000).rounded())
        let lon = Int((coordinate.longitude * 100_000).rounded())
        self.annotationID =
            "\(id.uuidString)-\(visualState)-\(monogram ?? symbol)-\(lat),\(lon)-\(title)"
            + "-\(self.memberIDs.count)"
    }
}

enum MapStyleChoice: String, CaseIterable, Identifiable {
    case standard, hybrid

    var id: String { rawValue }
    var label: String { self == .standard ? "Karte" : "Satellit" }
    var symbol: String { self == .standard ? "map" : "globe.europe.africa.fill" }

    /// No points of interest on either style. Shops, cafés and bus stops
    /// crowded the map around the pins, which are the only places on it the
    /// driver is looking for; streets and their names stay.
    ///
    /// 3D — buildings and terrain, tilted with two fingers like Apple Maps —
    /// once the map is zoomed in to a few streets. Not further out: with
    /// realistic elevation MapKit draws the route line several times too thick
    /// over a whole tour, and there are no buildings to see from there anyway.
    /// Not switched on the tilt itself, because a flat map cannot be tilted.
    func mapStyle(closeIn: Bool) -> MapStyle {
        let elevation: MapStyle.Elevation = closeIn ? .realistic : .flat
        switch self {
        case .standard: return .standard(elevation: elevation, pointsOfInterest: .excludingAll)
        case .hybrid: return .hybrid(elevation: elevation, pointsOfInterest: .excludingAll)
        }
    }
}


/// What a tapped pin shows: who is there, what to carry up, and the two things
/// worth doing about it from the map.
///
/// "Navigation starten" is the primary action, because a driver looking at a pin
/// is almost always about to drive to it. "In der Liste anzeigen" sits beside it
/// for the other reason a pin gets tapped — seeing where this stop falls among
/// the ones either side of it.
struct StopPreviewSheet: View {
    let stop: Stop
    var number: Int?
    /// The floor, when this door has been answered for.
    var stockwerk: String?
    /// Back to the list of everyone at this spot, when the card was opened from
    /// a shared pin.
    var onBack: (() -> Void)? = nil
    let onNavigate: () -> Void
    let onToggleDelivered: () -> Void
    let onShowInList: () -> Void
    /// The card's own content height, which is what the presenting sheet sizes
    /// its detent to. Reported from inside the scroll view, so it stays the
    /// height of the *card* rather than of the sheet the card ended up in.
    let onMeasure: (CGFloat) -> Void

    /// Same rule as the delivery tick in the stop list — this is that control,
    /// on a different screen.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 1
    /// And the same rule for the number badge, which `StopRow` already scales:
    /// a fixed 26pt circle clips the digit it exists to show once the text is
    /// turned up. This is the same badge, so it grows the same way.
    @ScaledMetric(relativeTo: .footnote) private var badgeSize: CGFloat = 26
    /// Whether the driver has the text turned up far enough that two buttons
    /// can no longer sit beside each other — see `actions`.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Presses of this card's own tick, and nothing else — it drives the
    /// haptic. The same counter `StopRow` and Jetzt keep, for the same reason,
    /// and this card was the one control still keyed on the stored value: off
    /// `stop.delivered` it thumped for a tick made on another screen, and —
    /// because re-opening a door nobody answered leaves that flag false either
    /// way — gave no feedback at all for the one press hardest to be sure of.
    @State private var ticks = 0

    private var isCustomer: Bool { stop.kind == .customer }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let onBack {
                    Button(action: onBack) {
                        Label("Alle an dieser Adresse", systemImage: "chevron.left")
                            .font(.subheadline.weight(.medium))
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, -10)
                }
                header
                details
                actions
            }
            // Room for the drag indicator above and the home indicator below:
            // the sheet is exactly as tall as this view, so the insets have to
            // come from here rather than from spare height.
            .padding(.horizontal)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeAreaPadding(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onMeasure($0) }
        }
        // No rubber-banding on the ordinary card, which fits exactly. The
        // scroll is only ever there for a stop carrying an unusually long note.
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let number {
                // The badge itself, not a disc of this card's own making. Drawn
                // here by hand it was a solid accent circle for an open stop —
                // which in the stop list means "the door you are standing at" —
                // and solid green for a delivered one, where the list shows
                // grey. The same customer, the same number, two designs,
                // depending on which screen you read it off; and the list of
                // everyone at a shared pin, three hundred lines further down
                // this same file, already drew it the other way.
                StopNumberBadge(
                    number: number, kind: .of(stop), size: badgeSize,
                    font: .footnote.weight(.semibold).monospacedDigit())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isCustomer ? (stop.kunde ?? "Stopp") : stop.fixedTitle)
                    .font(.title3.bold())
                    // Wraps rather than truncating, the same as the address
                    // directly under it. Without this a customer's name was cut
                    // to "Hyphen Te…" on the one card whose whole job is saying
                    // whose door this pin is.
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.address(stop.listAddress))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // The same control the list row carries, so ticking a stop off from
            // the map is the same gesture at the same size in the same colours.
            // Lager and Ziel carry it too, as they do in the list.
            if stop.countsAsStop {
                Button {
                    ticks += 1
                    onToggleDelivered()
                } label: {
                    Image(systemName: stop.outcome.map {
                        $0.handedOver ? "checkmark.circle.fill" : $0.symbol
                    } ?? "circle")
                        .font(.system(size: min(30 * textScale, 40)))
                        .foregroundStyle(stop.outcome.map {
                            $0.handedOver ? Color.delivered : Color.attention
                        } ?? Color.secondary)
                        .frame(width: min(44 * textScale, 64), height: min(44 * textScale, 64))
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    stop.isSettled
                        ? "Stopp wieder öffnen"
                        : (isCustomer ? "Als geliefert markieren" : "Als erledigt markieren"))
                .sensoryFeedback(.impact(weight: .medium), trigger: ticks)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if hasDetails {
            // The same vocabulary as the next-stop card: one `Label` per
            // fact in one icon column, colour on the glyph and the words left
            // as words. These lines used to set the whole sentence in amber or
            // in the floor's grey, which made a two-line note the loudest thing
            // on the card.
            VStack(alignment: .leading, spacing: 8) {
                // What happened at this door, when it was not the ordinary
                // thing — the line the stop's own row and the shared-pin list
                // both carry, and the one this card left out. A meal left with
                // a neighbour and a meal handed to the customer are both
                // `handedOver`, so they wear the same green tick up in the
                // header; without this the card could not tell them apart, and
                // "nicht angetroffen" read as a plain undelivered stop.
                if let outcome = StopFacts.outcome(stop.outcome) {
                    outcome
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let paket = StopFacts.paket(stop.displayPaket) {
                    paket
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let floor = StopFacts.floor(stockwerk) {
                    floor
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notiz = stop.notiz?.trimmed, !notiz.isEmpty {
                    StopFacts.note(notiz).font(.subheadline)
                }
                if let p = stop.precision {
                    StopFacts.precision(p).font(.footnote)
                }
            }
            .symbolRenderingMode(.monochrome)
            // Under the name rather than under the badge — the column the
            // next-stop card sets these same lines in. Flush left, the glyphs
            // sat beneath the number disc and the words started a badge's
            // width before the name they belong to.
            .padding(.leading, number == nil ? 0 : badgeSize + 12)
        }
    }

    /// Both buttons share the width evenly. Sized to their own titles they sat
    /// as a centred pair with a margin either side, which reads as a layout that
    /// ran out of content rather than as the card's two actions.
    ///
    /// Side by side only while they fit. Half a phone's width is not enough for
    /// "Navigation" once the driver turns the text up, and a bordered button
    /// asked to hold a word wider than itself does not shrink the word — it
    /// wraps it mid-syllable and inflates into a circle, which is how this card
    /// came to offer "Navi / gati / on". `AnyLayout` swaps the axis rather than
    /// branching on two separate view trees, so the buttons keep their identity
    /// and the driver's tap does not land on a freshly-built button.
    private var actions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            Button(action: onNavigate) {
                WideButtonLabel("Navigation", systemImage: "arrow.trianglehead.turn.up.right")
            }
            .buttonStyle(.borderedProminent)
            Button(action: onShowInList) {
                WideButtonLabel("In der Liste", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    /// Trimmed, the same as the lines themselves: a Notiz of nothing but a
    /// newline used to open an empty details block, an amber note glyph beside
    /// no words, and eight points of gap under the address.
    private var hasDetails: Bool {
        !(stop.displayPaket?.trimmed ?? "").isEmpty || !(stop.notiz?.trimmed ?? "").isEmpty
            || stop.precision != nil || !(stockwerk?.trimmed ?? "").isEmpty
            || StopFacts.outcome(stop.outcome) != nil
    }
}

/// What a shared pin opens: everyone at that spot, one row each, in stop
/// order. Tapping a row opens that customer's own card.
private struct SharedPinSheet: View {
    let stops: [Stop]
    let number: (Stop) -> Int?
    let onPick: (Stop) -> Void
    let onMeasure: (CGFloat) -> Void

    @ScaledMetric(relativeTo: .footnote) private var badgeSize: CGFloat = 26

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(stops.count) Stopps an dieser Adresse")
                    .font(.title3.bold())
                if let address = stops.first?.listAddress, !address.isEmpty {
                    Text(Format.address(address))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(stops, id: \.id) { stop in
                        Button { onPick(stop) } label: { row(stop) }
                            .buttonStyle(.plain)
                        if stop.id != stops.last?.id { Divider() }
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .safeAreaPadding(.bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onMeasure($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(_ stop: Stop) -> some View {
        HStack(spacing: 12) {
            StopNumberBadge(number: number(stop), kind: .of(stop), size: badgeSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.kunde ?? "Stopp")
                    .strikethrough(stop.delivered)
                    .foregroundStyle(stop.isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
                if let outcome = stop.outcome {
                    Text(outcome.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Öffnet diesen Stopp")
    }
}

extension MKCoordinateRegion {
    /// The smallest region containing every point, with a little padding so
    /// pins are not flush against the edge of the screen.
    init?(fitting coordinates: [CLLocationCoordinate2D]) {
        // One pass, skipping the unusable points in place. Filtering first
        // copied the whole driven line — several thousand points on a Vienna
        // tour — to throw the copy away a moment later.
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for c in coordinates where c.latitude.isFinite && c.longitude.isFinite {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        guard minLat <= maxLat else { return nil }

        self.init(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.35, 0.005),
                longitudeDelta: max((maxLon - minLon) * 1.35, 0.005)))
    }
}
