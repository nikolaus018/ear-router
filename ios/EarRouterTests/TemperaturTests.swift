import Testing
@testable import EarRouter

struct TemperaturTests {

    @Test func tkTemperaturesAreWholeDegreesWithinBoundsAndGetColder() {
        for _ in 0..<200 {
            let t = TemperaturGenerator.generate(modus: .tk)
            for v in [t.start, t.mitte, t.ende] { #expect((-18)...(-10) ~= v) }
            #expect(t.start > t.mitte)
            #expect(t.mitte > t.ende)
        }
    }

    @Test func vmTemperaturesAreWholeDegreesWithinBoundsAndGetColder() {
        for _ in 0..<200 {
            let t = TemperaturGenerator.generate(modus: .vm)
            for v in [t.start, t.mitte, t.ende] { #expect((-18)...(-4) ~= v) }
            #expect(t.start > t.mitte)
            #expect(t.mitte > t.ende)
        }
    }

    @Test func bothEndsOfTheRangeCanCome() {
        var tk: Set<Int> = [], vm: Set<Int> = []
        for _ in 0..<2000 {
            let a = TemperaturGenerator.generate(modus: .tk)
            let b = TemperaturGenerator.generate(modus: .vm)
            tk.formUnion([a.start, a.ende]); vm.formUnion([b.start, b.ende])
        }
        #expect(tk.contains(-10) && tk.contains(-18))
        #expect(vm.contains(-4) && vm.contains(-18))
    }

    @Test func formattingIncludesDegreeCelsius() {
        let temp = TourTemperaturen(start: -11, mitte: -14, ende: -17)
        #expect(temp.startText == "-11 °C")
        #expect(temp.endeText.contains("°C"))
    }
}
