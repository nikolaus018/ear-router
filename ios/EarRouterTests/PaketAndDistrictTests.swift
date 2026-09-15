import Testing
import SwiftData
@testable import EarRouter

/// The Ladeliste is what the driver loads the van from. A miscount here means
/// driving away without someone's lunch.
struct PaketParserTests {

    @Test func countsTheXForm() {
        let items = PaketParser.parse("2x Menü")
        #expect(items.count == 1)
        #expect(items[0].qty == 2)
        #expect(items[0].label == "Menü")
    }

    @Test func acceptsTheMultiplicationSignAndSpacing() {
        #expect(PaketParser.parse("3 × Suppe")[0].qty == 3)
        #expect(PaketParser.parse("3 Suppe")[0].qty == 3)
    }

    @Test func splitsOnCommaSemicolonAndPlus() {
        #expect(PaketParser.parse("2x Menü, 1x Suppe").count == 2)
        #expect(PaketParser.parse("2x Menü; 1x Suppe").count == 2)
        #expect(PaketParser.parse("2x Menü + 1x Suppe").count == 2)
    }

    @Test func totalSumsEveryItem() {
        #expect(PaketParser.totalQty("2x Menü, 1x Suppe") == 3)
        #expect(PaketParser.totalQty("Menü") == 1)
        #expect(PaketParser.totalQty(nil) == 0)
        #expect(PaketParser.totalQty("") == 0)
    }

    @Test func keepsTheDriversTextWhenTheGuessIsWrong() {
        // A count with nothing after it, or a zero, means the parse was wrong —
        // better to show what was typed than to invent a quantity.
        #expect(PaketParser.parse("0x Menü")[0].label == "0x Menü")
        #expect(PaketParser.parse("2024")[0].qty == 1)
    }

    @Test func aHousenumberLikeStringIsNotAQuantity() {
        let items = PaketParser.parse("Menü 2")
        #expect(items[0].qty == 1)
        #expect(items[0].label == "Menü 2")
    }
}

struct DistrictTests {

    @Test func acceptsAllTwentyThreeRealPostcodes() {
        #expect(Districts.all.count == 23)
        for d in Districts.all {
            #expect(Districts.isValid(d.plz))
        }
    }

    /// `Districts.isValid` still means "is one of the 23" — it is what decides
    /// whether the city's own register is worth asking. What it no longer
    /// decides is whether a stop may be saved: see `PostcodeTests`.
    @Test func rejectsPostcodesThatAreNotVienna() {
        #expect(!Districts.isValid("8010"))   // Graz
        #expect(!Districts.isValid("1240"))   // does not exist
        #expect(!Districts.isValid(""))
        #expect(!Districts.isValid("1010 "))  // untrimmed
    }

    @Test func everyDistrictCentreIsInsideTheViennaBox() {
        for d in Districts.all {
            #expect(
                Coordinates.isInVienna(lat: d.lat, lon: d.lon),
                "\(d.plz) \(d.name) is outside the Vienna box")
        }
    }

    @Test func theFixedRoutePointsArePlausible() {
        #expect(Coordinates.isPlausible(lat: Coordinates.start.lat, lon: Coordinates.start.lon))
        #expect(Coordinates.isPlausible(lat: Coordinates.via.lat, lon: Coordinates.via.lon))
    }

    @Test func implausibleCoordinatesAreRejected() {
        #expect(!Coordinates.isPlausible(lat: 0, lon: 0))
        #expect(!Coordinates.isPlausible(lat: 16.37, lon: 48.20))   // swapped
        #expect(!Coordinates.isPlausible(lat: .nan, lon: 16.37))
        #expect(!Coordinates.isPlausible(lat: .infinity, lon: 16.37))
        #expect(!Coordinates.isPlausible(lat: 38.72, lon: -9.14))   // Lisbon
    }

    /// The country-wide box is what a stop outside Vienna is checked against,
    /// and it has to actually contain the country: a Bregenz or Klagenfurt
    /// address rejected here is one the driver cannot enter at all.
    @Test func theRestOfAustriaIsPlausible() {
        #expect(Coordinates.isPlausible(lat: 47.5031, lon: 9.7471))   // Bregenz
        #expect(Coordinates.isPlausible(lat: 46.6247, lon: 14.3050))  // Klagenfurt
        #expect(Coordinates.isPlausible(lat: 48.9767, lon: 14.9800))  // Gmünd, on the border
        #expect(Coordinates.isPlausible(lat: 47.0707, lon: 15.4395))  // Graz
    }
}

struct PostcodeTests {

    @Test func acceptsEveryAustrianPostcodeShape() {
        #expect(Postcodes.isValid("1210"))   // Floridsdorf
        #expect(Postcodes.isValid("2201"))   // Gerasdorf bei Wien
        #expect(Postcodes.isValid("8010"))   // Graz — no longer refused
        #expect(Postcodes.isValid("9999"))
    }

    @Test func rejectsWhatCannotBeAPostcode() {
        #expect(!Postcodes.isValid(""))
        #expect(!Postcodes.isValid("0123"))    // no Austrian code starts with 0
        #expect(!Postcodes.isValid("121"))
        #expect(!Postcodes.isValid("12100"))
        #expect(!Postcodes.isValid("1010 "))   // untrimmed
        #expect(!Postcodes.isValid("12a0"))
    }

    @Test func viennaIsStillToldApart() {
        #expect(Postcodes.isVienna("1210"))
        #expect(!Postcodes.isVienna("2201"))
        // A code in Vienna's own 1xxx block that is not one of the 23.
        #expect(!Postcodes.isVienna("1240"))
        #expect(Postcodes.isValid("1240"))
    }

    /// The suffix is what stops a Gerasdorf address being asked for "in Wien"
    /// and answered with a confident pin in the 2nd district.
    @Test func onlyViennaQueriesSayWien() {
        #expect(Postcodes.placeSuffix(for: "1210") == "1210 Wien, Österreich")
        #expect(Postcodes.placeSuffix(for: "2201") == "2201, Österreich")
    }

    @Test func theSanityBoxFollowsThePostcode() {
        // Graz coordinates under a Vienna postcode: still a mistake.
        #expect(!Coordinates.isPlausible(lat: 47.0707, lon: 15.4395, forPlz: "1210"))
        // The same coordinates under Graz's own postcode: fine.
        #expect(Coordinates.isPlausible(lat: 47.0707, lon: 15.4395, forPlz: "8010"))
        #expect(Coordinates.isPlausible(lat: 48.2540, lon: 16.4000, forPlz: "1210"))

        // The box is two ranges, and a point can leave it by either. Checked
        // one at a time: Graz is out on longitude alone, so a latitude range
        // quietly widened to the whole country would still look right here.
        #expect(!Coordinates.isInVienna(lat: 49.0, lon: 16.4))   // north, into Czechia
        #expect(!Coordinates.isInVienna(lat: 46.6, lon: 16.4))   // south, past Graz
        #expect(!Coordinates.isInVienna(lat: 48.2, lon: 15.0))   // west, past St. Pölten
        #expect(!Coordinates.isInVienna(lat: 48.2, lon: 17.2))   // east, into Slovakia
        #expect(Coordinates.isInVienna(lat: 48.2, lon: 16.4))
    }
}

/// A hand-placed pin has to be one the app will still be using afterwards.
///
/// `Stop.coordinate` measures a stored point against the box its *postcode*
/// implies and falls back to the centre of Vienna for anything outside it — and
/// the map, the route planning and the navigation handoff all read through
/// there. The pin-drop path checked the country-wide box instead, so it
/// accepted points that reader then threw away: the stop was stored with the
/// pin, marked "von Hand gesetzt", and drawn, planned and navigated to at
/// Stephansplatz.
struct PinPlausibilityTests {

    @Test func refusesAPinFarFromAViennaAddress() {
        // Graz, on a stop filed under 1210 — inside the country-wide box the
        // old check used, and outside the one that reads it back.
        #expect(throws: AppError.self) {
            try RouteStore.checkPin((lat: 47.0707, lon: 15.4395), plz: "1210")
        }
    }

    /// What the old check was for, and still is.
    @Test func refusesTheUnusableDefaultsAndASwappedPair() throws {
        #expect(throws: AppError.self) {
            try RouteStore.checkPin((lat: 0, lon: 0), plz: "1210")
        }
        #expect(throws: AppError.self) {
            try RouteStore.checkPin((lat: 16.37, lon: 48.20), plz: "1210")
        }
        #expect(throws: AppError.self) {
            try RouteStore.checkPin((lat: 38.72, lon: -9.14), plz: "2201")  // Lisbon
        }
    }

    /// The point of the whole postcode-aware box: a tour that runs past the
    /// Stadtgrenze is still a tour, and its pins are not mistakes.
    @Test func acceptsAPinAtTheAddressItBelongsTo() throws {
        try RouteStore.checkPin((lat: 48.2540, lon: 16.4000), plz: "1210")
        try RouteStore.checkPin((lat: 47.0707, lon: 15.4395), plz: "8010")  // Graz, filed in Graz
        try RouteStore.checkPin((lat: 48.2932, lon: 16.4715), plz: "2201")  // Gerasdorf
    }

    /// Whatever is accepted here is what `Stop.coordinate` hands back — which
    /// is the invariant the two checks disagreeing had broken.
    @Test func anAcceptedPinIsThePointTheStopReadsBack() throws {
        let pin = (lat: 48.2540, lon: 16.4000)
        try RouteStore.checkPin(pin, plz: "1210")
        let stop = Stop(
            kind: .customer, kunde: "Test", strasse: "Teststraße 1", plz: "1210",
            lat: pin.lat, lon: pin.lon, pinned: true)
        #expect(stop.coordinate.latitude == pin.lat)
        #expect(stop.coordinate.longitude == pin.lon)
    }

    /// A stop with no postcode at all keeps the old, country-wide behaviour —
    /// there is no tighter box to measure it against.
    @Test func withNoPostcodeTheCountryWideBoxStillApplies() throws {
        try RouteStore.checkPin((lat: 47.0707, lon: 15.4395), plz: "")
        #expect(throws: AppError.self) {
            try RouteStore.checkPin((lat: 38.72, lon: -9.14), plz: "")
        }
    }
}

struct TuercodeTests {

    @Test func mapsTheCipherSheet() {
        #expect(Tuercode.decode("ENVV") == "1944")
        #expect(Tuercode.decode("CEZDVFS?AN") == "0123456789")
    }

    @Test func isCaseInsensitive() {
        #expect(Tuercode.decode("envv") == Tuercode.decode("ENVV"))
    }

    @Test func passesUnmappedCharactersThrough() {
        // An X or a hyphen is already part of the code, not something encoded.
        #expect(Tuercode.decode("EN-X") == "19-X")
    }

    /// Seven is the one digit the cipher sheet writes as punctuation, and the
    /// table simply did not have it — so a code with a seven in it came back
    /// with the question mark still in place, and the driver was left at the
    /// keypad holding eight digits and a "?".
    @Test func decodesTheQuestionMarkAsSeven() {
        #expect(Tuercode.decode("E?N") == "179")
    }
}

/// The packing checklist: what actually has to go into the van before setting
/// off, rather than a per-customer list nobody can load from.
@MainActor
struct LadelisteTests {

    private func route(_ pakete: [String]) throws -> Route {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        for (i, paket) in pakete.enumerated() {
            let stop = Stop(
                kind: .customer, kunde: "Kunde \(i)", strasse: "Gasse \(i)", plz: "1180",
                paket: paket, lat: 48.23, lon: 16.32, orderIndex: 10 + i)
            stop.route = route
            context.insert(stop)
        }
        try context.save()
        return route
    }

    /// Busiest first — the list is read while loading the van, and the line
    /// with twelve of something is the one that decides whether it fits.
    @Test func theBusiestLineComesFirst() throws {
        let items = PaketParser.items(for: try route(["1x Suppe", "5x Menü", "2x Diät"]))
        #expect(items.map(\.qty) == [5, 2, 1])
        #expect(items.first?.label == "Menü")
    }

    /// Summed across the tour, not listed per customer.
    @Test func thesameThingAtThreeDoorsIsOneLine() throws {
        let items = PaketParser.items(for: try route(["2x Menü", "1x Menü", "3x Menü"]))
        #expect(items.count == 1)
        #expect(items.first?.qty == 6)
    }

    /// The identity used for grouping — and for remembering which lines are
    /// ticked — ignores case and spacing, because the same meal is typed a
    /// dozen ways across a tour.
    @Test func oneMealSpelledSeveralWaysIsStillOneLine() throws {
        let items = PaketParser.items(for: try route(["2x Menü", "1x  MENÜ", "1x menü "]))
        #expect(items.count == 1)
        #expect(items.first?.qty == 4)
        // The first spelling is what the driver reads back.
        #expect(items.first?.label == "Menü")
    }

    /// Two genuinely different things stay two lines.
    @Test func differentMealsStayApart() throws {
        let items = PaketParser.items(for: try route(["2x Menü", "2x Diätmenü"]))
        #expect(items.count == 2)
        #expect(Set(items.map(\.label)) == ["Menü", "Diätmenü"])
    }

    @Test func aTourWithNothingToCarryHasNoList() throws {
        #expect(PaketParser.items(for: try route([])).isEmpty)
        #expect(PaketParser.items(for: try route(["", "  "])).isEmpty)
    }
}

/// Which of the two loading lists a tour opens with, and what the TK one says.
///
/// The two rounds are loaded in opposite ways. A VM tour carries the same few
/// menu codes to every door, so the van is loaded by counting codes. A TK tour
/// carries a different basket of dishes to each door with the customer's name
/// on it, so the van is loaded by customer — last door at the front of the
/// stack, because it comes out last.
@MainActor
struct LadelisteModeTests {

    private func route(_ name: String, kunden: [(String, String?)] = []) throws -> Route {
        let container = try ModelContainer(
            for: Route.self, Stop.self, StockwerkNote.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = try RouteStore.createRoute(name: name, in: context)
        for (i, kunde) in kunden.enumerated() {
            let stop = Stop(
                kind: .customer, kunde: kunde.0, strasse: "Gasse \(i)", plz: "1180",
                paket: kunde.1, lat: 48.23, lon: 16.32, orderIndex: 10 + i)
            stop.route = route
            context.insert(stop)
        }
        try context.save()
        return route
    }

    @Test func aTourNamedAfterTheFreezerOpensInTKMode() throws {
        #expect(LadelisteMode.suggested(for: try route("TK1")) == .tk)
        // The portal spells it both ways, and a driver typing it by hand spells
        // it a third.
        #expect(LadelisteMode.suggested(for: try route("Tk1")) == .tk)
        #expect(LadelisteMode.suggested(for: try route(" tk 2 ")) == .tk)
    }

    @Test func everythingElseOpensInVMMode() throws {
        #expect(LadelisteMode.suggested(for: try route("VM4")) == .vm)
        #expect(LadelisteMode.suggested(for: try route("VM 4 DO Vormittag")) == .vm)
        #expect(LadelisteMode.suggested(for: try route("TP AST 14 - 1401")) == .vm)
        #expect(LadelisteMode.suggested(for: try route("Tour 12.09.")) == .vm)
    }

    /// The whole point of the TK list: first in, last out.
    @Test func theLastDoorIsLoadedFirst() throws {
        let r = try route("TK1", kunden: [("Erste", nil), ("Zweite", nil), ("Letzte", nil)])
        let order = LadungPlan.loadingOrder(for: r)
        #expect(order.map(\.name) == ["Letzte", "Zweite", "Erste"])
        #expect(order.map(\.position) == [1, 2, 3])
    }

    /// Reversed off the driving order the tour screen shows, not off the order
    /// the stops happened to be created in.
    @Test func theOrderFollowsTheRouteAndNotTheEntryOrder() throws {
        let r = try route("TK1", kunden: [("Erste", nil), ("Zweite", nil), ("Dritte", nil)])
        let stops = r.customerStops
        // The optimizer has re-ordered the tour: the last-entered door is now
        // driven first.
        stops[0].orderIndex = 30
        stops[2].orderIndex = 10
        #expect(LadungPlan.loadingOrder(for: r).map(\.name) == ["Erste", "Zweite", "Dritte"])
    }

    @Test func eachDoorCarriesItsPieceCount() throws {
        let r = try route(
            "TK1", kunden: [("Barak", "1x Suppe, 2x Menü"), ("Bolz", nil), ("Fischer", "Menü")])
        let order = LadungPlan.loadingOrder(for: r)
        #expect(order.map(\.pieces) == [1, 0, 3])
        #expect(order.first?.address == "Gasse 2, 1180")
    }

    /// A stop nobody has named still has to be loadable — it is a parcel in the
    /// van either way.
    @Test func aDoorWithoutANameStillGetsARow() throws {
        let r = try route("TK1", kunden: [("", nil), ("   ", nil)])
        #expect(LadungPlan.loadingOrder(for: r).map(\.name) == ["Stopp", "Stopp"])
    }

    /// Both lists tick into the same store per tour, so their keys must not be
    /// able to mean each other.
    @Test func aCustomerTickCannotBeMistakenForAPaketTick() throws {
        let r = try route("TK1", kunden: [("Barak", "1x Menü")])
        let customerKey = LadungPlan.loadingOrder(for: r).first?.key
        #expect(customerKey?.hasPrefix("stop:") == true)
        #expect(!PaketParser.items(for: r).map(\.key).contains(customerKey ?? ""))
    }

    @Test func aTourWithNoStopsHasNoLoadingOrder() throws {
        #expect(LadungPlan.loadingOrder(for: try route("TK1")).isEmpty)
    }
}
