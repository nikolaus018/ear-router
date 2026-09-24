import Foundation
import Testing
@testable import EarRouter

/// Which door the register's answer is read as, for the sub-address shapes
/// found by running real Vienna addresses through the live geocoder. Every
/// feature here is what data.wien.gv.at actually answered.
struct SubAddressMatchingTests {

    private func f(
        _ adresse: String, number: String, plz: String? = "1170", bezirk: String? = nil,
        ranking: Double = 0.0001, at coord: [Double] = [16.28, 48.23]
    ) -> Geocoder.OGDFeature {
        let street = String(adresse.prefix { !$0.isNumber }).trimmed
        return Geocoder.OGDFeature(
            geometry: Geocoder.OGDGeometry(coordinates: coord),
            properties: Geocoder.OGDProperties(
                streetName: street, postalCode: plz, kategorie: "Adresse",
                adresse: adresse, ranking: ranking, streetNumber: number, bezirk: bezirk))
    }

    private func pick(
        _ features: [Geocoder.OGDFeature], _ typed: String, plz: String = "1170"
    ) -> String? {
        let normalized = AddressText.normalize(typed)
        let simplified = AddressText.simplifyHousenumber(normalized)
        return Geocoder.pickFeature(
            features, plz: plz,
            streetKey: AddressText.matchKey(AddressText.streetNameOnly(simplified)),
            requireSub: AddressText.housenumberWithSub(normalized)?.key,
            segments: AddressText.subAddressSegments(normalized),
            number: simplified.split(separator: " ").last
                .flatMap { Geocoder.entranceNumber(String($0)) }
        )?.properties.adresse
    }

    private var promenadegasse57: [Geocoder.OGDFeature] {
        [f("Promenadegasse 57 Haus B", number: "57 Haus B", ranking: 7e-08, at: [16.2880, 48.2330]),
         f("Promenadegasse 57 Haus C", number: "57 Haus C", ranking: 7e-08, at: [16.2873, 48.2328]),
         f("Promenadegasse 57 Haus A/1", number: "57 Haus A/1", at: [16.2869, 48.2325]),
         f("Promenadegasse 57 Haus D/1", number: "57 Haus D/1", at: [16.2886, 48.2332]),
         f("Promenadegasse 57 Haus A/2", number: "57 Haus A/2", ranking: 0.0002, at: [16.2870, 48.2326]),
         f("Promenadegasse 57 Haus D/2", number: "57 Haus D/2", ranking: 0.0002, at: [16.2887, 48.2333])]
    }

    @Test func aLetteredBlockIsFoundHoweverTheDriverWritesIt() {
        for typed in ["Promenadegasse 57/A1/1", "Promenadegasse 57/A/1/1",
                      "Promenadegasse 57/Haus A/1/1"] {
            #expect(pick(promenadegasse57, typed) == "Promenadegasse 57 Haus A/1", "\(typed)")
        }
        #expect(pick(promenadegasse57, "Promenadegasse 57/D2/3") == "Promenadegasse 57 Haus D/2")
        #expect(pick(promenadegasse57, "Promenadegasse 57/B/1") == "Promenadegasse 57 Haus B")
    }

    @Test func aNumberedHouseMatchesWithOrWithoutTheWordHaus() {
        let features = [f("Promenadegasse 55 Haus 1", number: "55 Haus 1"),
                        f("Promenadegasse 55 Haus 2", number: "55 Haus 2", at: [16.29, 48.24])]
        #expect(pick(features, "Promenadegasse 55/2/4") == "Promenadegasse 55 Haus 2")
        #expect(pick(features, "Promenadegasse 55/Haus 2/4") == "Promenadegasse 55 Haus 2")
    }

    @Test func aDriverWhoWritesHausGetsTheHouseNotTheStiege() {
        let features = [
            f("Breitenfurter Straße 510/2", number: "510/2", plz: "1230", ranking: 0.0001),
            f("Breitenfurter Straße 510 Haus 2", number: "510 Haus 2", plz: "1230",
              ranking: 0.0002, at: [16.27, 48.14])]
        #expect(pick(features, "Breitenfurter Straße 510/Haus 2/2/7", plz: "1230")
                == "Breitenfurter Straße 510 Haus 2")
        #expect(pick(features, "Breitenfurter Straße 510/2/2/7", plz: "1230")
                == "Breitenfurter Straße 510/2")
    }

    @Test func anAnswerWithNoPostcodeCountsWhenItsBezirkIsRight() {
        let haus2 = f("Breitenfurter Straße 390 Haus 2", number: "390 Haus 2",
                      plz: nil, bezirk: "23", ranking: 5e-08)
        #expect(pick([haus2], "Breitenfurter Straße 390/2/1", plz: "1230")
                == "Breitenfurter Straße 390 Haus 2")
        #expect(pick([haus2], "Breitenfurter Straße 390/2/1", plz: "1130") == nil)
    }

    @Test func aKleingartenPlotIsFoundFromGruppeAndParzelle() {
        let features = (1...11).map {
            f("Mühlweg 4 Gruppe 2 Parz. \($0)", number: "4 Gruppe 2 Parz. \($0)",
              plz: "1210", at: [16.40 + Double($0) * 0.001, 48.27])
        }
        #expect(pick(features, "Mühlweg 4/Gruppe 2/Parz. 5", plz: "1210")
                == "Mühlweg 4 Gruppe 2 Parz. 5")
        #expect(pick(features, "Mühlweg 4/2/5", plz: "1210") == "Mühlweg 4 Gruppe 2 Parz. 5")
    }

    @Test func oneDoorListedTwiceIsStillOneDoor() {
        let features = [
            f("An der Niederhaid 8/GRP. 2/PARZ. 19", number: "8/GRP. 2/PARZ. 19",
              plz: "1140", ranking: 7e-08, at: [16.25000, 48.2100]),
            f("An der Niederhaid 8 Gruppe 2 Parz. 19", number: "8 Gruppe 2 Parz. 19",
              plz: "1140", ranking: 0.0002, at: [16.25003, 48.2100]),
            f("An der Niederhaid 8 Gruppe 2 Parz. 18", number: "8 Gruppe 2 Parz. 18",
              plz: "1140", ranking: 0.0002, at: [16.2510, 48.2100])]
        #expect(pick(features, "An der Niederhaid 8/2/19", plz: "1140")
                == "An der Niederhaid 8/GRP. 2/PARZ. 19")
    }

    @Test func anAmbiguousDoorIsNotGuessed() {
        let features = [
            f("Wolkersbergenstraße 1 Pav. 1", number: "1 Pav. 1", plz: "1130",
              ranking: 5e-08, at: [16.2761, 48.1714]),
            f("Wolkersbergenstraße 1 Obj. 1", number: "1 Obj. 1", plz: "1130",
              ranking: 5e-08, at: [16.2765, 48.1702])]
        #expect(pick(features, "Wolkersbergenstraße 1/1", plz: "1130") == nil)
        #expect(pick(features, "Wolkersbergenstraße 1/Pav. 1", plz: "1130")
                == "Wolkersbergenstraße 1 Pav. 1")
    }

    @Test func theNextHouseNumberIsNotTheDoorAskedFor() {
        let features = [
            f("Doningasse 8 Obj. 1", number: "8 Obj. 1", plz: "1220", ranking: 5e-08),
            f("Doningasse 8B Obj. 1", number: "8B Obj. 1", plz: "1220",
              ranking: 6e-08, at: [16.45, 48.23])]
        #expect(pick(features, "Doningasse 8/1", plz: "1220") == "Doningasse 8 Obj. 1")
    }

    // MARK: - isUncertainDoor

    @Test func aNeighbouringLetteredNumberIsOnlyApproximate() {
        let b = f("Doningasse 8B", number: "8B", plz: "1220", ranking: 1e-08)
        #expect(Geocoder.isUncertainDoor(
            b, among: [b], streetKey: AddressText.matchKey("Doningasse"),
            number: "8", subAsked: false))
    }

    @Test func theBareNumberOfASplitSiteIsOnlyApproximate() {
        let bare = f("Wolkersbergenstraße 1", number: "1", plz: "1130", ranking: 1e-08,
                     at: [16.2776, 48.1715])
        let obj = f("Wolkersbergenstraße 1 Obj. 1", number: "1 Obj. 1", plz: "1130",
                    at: [16.2765, 48.1702])
        let key = AddressText.matchKey("Wolkersbergenstraße")
        #expect(Geocoder.isUncertainDoor(
            bare, among: [bare, obj], streetKey: key, number: "1", subAsked: true))
        // Nothing asked beyond the number: the bare number is the answer.
        #expect(!Geocoder.isUncertainDoor(
            bare, among: [bare, obj], streetKey: key, number: "1", subAsked: false))
    }

    @Test func theStiegenOfOneHouseDoNotMakeItsNumberUncertain() {
        // "Gentzgasse 129/5/12": Stock 5, Tür 12, in a house whose Stiegen
        // stand a few metres from its own point.
        let bare = f("Gentzgasse 129", number: "129", plz: "1180", ranking: 0.0,
                     at: [16.3340, 48.2290])
        let stiege = f("Gentzgasse 129/1", number: "129/1", plz: "1180",
                       at: [16.3342, 48.2291])
        #expect(!Geocoder.isUncertainDoor(
            bare, among: [bare, stiege], streetKey: AddressText.matchKey("Gentzgasse"),
            number: "129", subAsked: true))
    }

    @Test func aHouseTheRegisterDoesNotSplitStaysExact() {
        // "Pappenheimgasse 66-68/2/4/24": the "/2" is a Stiege no register
        // knows, and 67/1 next door is a different number.
        let house = f("Pappenheimgasse 66-68", number: "66-68", plz: "1200", ranking: 2e-08)
        let next = f("Pappenheimgasse 67/1", number: "67/1", plz: "1200", ranking: 1.0067)
        #expect(!Geocoder.isUncertainDoor(
            house, among: [house, next], streetKey: AddressText.matchKey("Pappenheimgasse"),
            number: "66", subAsked: true))
    }

    // MARK: - AddressText

    @Test func tokensDropEveryLabel() {
        #expect(AddressText.subAddressTokens("Gruppe F Parz. 7") == ["f", "7"])
        #expect(AddressText.subAddressTokens("/GRP. 2/PARZ. 19") == ["2", "19"])
        #expect(AddressText.subAddressTokens("Obj. 62A") == ["62a"])
        #expect(AddressText.subAddressTokens("Haus A/1") == ["a", "1"])
    }

    @Test func segmentsAreEverythingAfterTheNumber() {
        #expect(AddressText.subAddressSegments("Promenadegasse 57/A1/1") == ["A1", "1"])
        #expect(AddressText.subAddressSegments("Pappenheimgasse 66-68/2/4/24") == ["2", "4", "24"])
        #expect(AddressText.subAddressSegments("Großfeldstraße 9 Parz. 68") == ["Parz. 68"])
        #expect(AddressText.subAddressSegments("Hauptstraße 12") == [])
    }
}
