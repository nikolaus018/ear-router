import Testing
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
