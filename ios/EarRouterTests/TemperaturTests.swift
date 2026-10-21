import Testing
@testable import EarRouter

struct TemperaturTests {

    @Test func tkTemperaturesAreWithinBoundsAndStrictlyGetColder() {
        for _ in 0..<100 {
            let decimal = TemperaturGenerator.generate(modus: .tk, mitDezimal: true)
            #expect(decimal.start >= -12.5 && decimal.start <= -10.0)
            #expect(decimal.mitte >= -15.5 && decimal.mitte <= -13.0)
            #expect(decimal.ende >= -18.0 && decimal.ende <= -16.0)
            #expect(decimal.start > decimal.mitte)
            #expect(decimal.mitte > decimal.ende)

            let integer = TemperaturGenerator.generate(modus: .tk, mitDezimal: false)
            #expect(integer.start >= -12.0 && integer.start <= -10.0)
            #expect(integer.mitte >= -15.0 && integer.mitte <= -13.0)
            #expect(integer.ende >= -18.0 && integer.ende <= -16.0)
            #expect(integer.start > integer.mitte)
            #expect(integer.mitte > integer.ende)
        }
    }

    @Test func vmTemperaturesAreWithinBoundsAndStrictlyGetColder() {
        for _ in 0..<100 {
            let decimal = TemperaturGenerator.generate(modus: .vm, mitDezimal: true)
            #expect(decimal.start >= -9.3 && decimal.start <= -8.0)
            #expect(decimal.mitte >= -10.7 && decimal.mitte <= -9.6)
            #expect(decimal.ende >= -12.0 && decimal.ende <= -11.0)
            #expect(decimal.start > decimal.mitte)
            #expect(decimal.mitte > decimal.ende)

            let integer = TemperaturGenerator.generate(modus: .vm, mitDezimal: false)
            #expect(integer.start >= -9.0 && integer.start <= -8.0)
            #expect(integer.mitte == -10.0)
            #expect(integer.ende >= -12.0 && integer.ende <= -11.0)
            #expect(integer.start > integer.mitte)
            #expect(integer.mitte > integer.ende)
        }
    }

    @Test func formattingIncludesDegreeCelsius() {
        let temp = TourTemperaturen(start: -11.2, mitte: -14.5, ende: -17.8, mitDezimal: true)
        #expect(temp.startText.contains("°C"))
        #expect(temp.mitteText.contains("°C"))
        #expect(temp.endeText.contains("°C"))
    }
}
