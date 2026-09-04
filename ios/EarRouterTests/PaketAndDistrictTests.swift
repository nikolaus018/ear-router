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

    @Test func rejectsPostcodesThatAreNotVienna() {
        #expect(!Districts.isValid("8010"))   // Graz
        #expect(!Districts.isValid("1240"))   // does not exist
        #expect(!Districts.isValid(""))
        #expect(!Districts.isValid("1010 "))  // untrimmed
    }

    @Test func everyDistrictCentreIsInsideTheViennaBox() {
        for d in Districts.all {
            #expect(
                Coordinates.isPlausible(lat: d.lat, lon: d.lon),
                "\(d.plz) \(d.name) is outside the plausible box")
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
        #expect(!Coordinates.isPlausible(lat: 47.07, lon: 15.44))   // Graz
    }
}

struct TuercodeTests {

    @Test func mapsTheCipherSheet() {
        #expect(Tuercode.decode("ENVV") == "1944")
        #expect(Tuercode.decode("CEZDVFSAN") == "012345689")
    }

    @Test func isCaseInsensitive() {
        #expect(Tuercode.decode("envv") == Tuercode.decode("ENVV"))
    }

    @Test func passesUnmappedCharactersThrough() {
        // An X or a hyphen is already part of the code, not something encoded.
        #expect(Tuercode.decode("EN-X") == "19-X")
    }
}
