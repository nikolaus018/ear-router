import Testing
@testable import EarRouter

/// The Kilometerstand tool subtracts two typed numbers and writes the result
/// into a vehicle log book. A misparsed separator there is not a cosmetic bug —
/// it is a wrong number on paper, so the parser has to be explicit about what
/// it accepts and refuse everything else rather than guess.
struct KilometerTests {

    // MARK: - parse

    @Test func readsAPlainOdometerReading() {
        #expect(Kilometerstand.parse("132000") == 132_000)
        #expect(Kilometerstand.parse(" 132000 ") == 132_000)
        #expect(Kilometerstand.parse("0") == 0)
    }

    @Test func treatsTheCommaAsTheDecimalSeparator() {
        // What the decimal pad actually types on an Austrian phone.
        #expect(Kilometerstand.parse("132,5") == 132.5)
    }

    @Test func acceptsAPastedDot() {
        #expect(Kilometerstand.parse("132.5") == 132.5)
    }

    @Test func dropsTheGroupingSeparatorOfAPastedNumber() {
        // Whichever separator comes last is the decimal one; the other groups.
        #expect(Kilometerstand.parse("132.000,5") == 132_000.5)
        #expect(Kilometerstand.parse("132,000.5") == 132_000.5)
    }

    @Test func refusesWhatIsNotANumber() {
        #expect(Kilometerstand.parse("") == nil)
        #expect(Kilometerstand.parse("   ") == nil)
        #expect(Kilometerstand.parse("abc") == nil)
        #expect(Kilometerstand.parse("12km") == nil)
        // A minus is not on the decimal pad, and an odometer never counts down.
        #expect(Kilometerstand.parse("-5") == nil)
    }

    // MARK: - format

    @Test func writesWholeKilometresWithoutADecimal() {
        #expect(Kilometerstand.format(132) == "132")
    }

    @Test func keepsOneDecimalAndTheAustrianComma() {
        #expect(Kilometerstand.format(132.5) == "132,5")
    }

    /// The round trip the tool relies on every day: the saved reading is
    /// formatted back into the "Alt" field and reparsed on the next save.
    @Test func formattedReadingParsesBackUnchanged() {
        for value in [0.0, 7.0, 132.5, 132_000.0] {
            #expect(Kilometerstand.parse(Kilometerstand.format(value)) == value)
        }
    }
}
