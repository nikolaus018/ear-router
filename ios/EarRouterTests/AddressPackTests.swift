import Foundation
import Testing
@testable import EarRouter

/// The copy of Vienna's register the app ships with, answering in the
/// service's place. Read the way the geocoder reads the service — through
/// `pickFeature` and `result` — so these check the door a driver would be
/// sent to, not just that rows come back.
struct AddressPackTests {

    /// Real rows from the download, trimmed to the streets used here.
    private let text = """
        #\tWienAdressen\t1\t2026-10-31
        A\tDr.-Karl-Lueger-Platz\t1\t1010\t48.207000\t16.379000
        A\tGentzgasse\t127\t1180\t48.230300\t16.330900
        A\tGentzgasse\t129/1\t1180\t48.230569\t16.330485
        A\tGentzgasse\t129/2\t1180\t48.230705\t16.330182
        E\tGentzgasse\t129\t1180\t48.230549\t16.330604
        E\tGentzgasse\t127\t1180\t48.230280\t16.330950
        A\tDoningasse\t8B\t1220\t48.240000\t16.450000
        A\tDoningasse\t10\t1220\t48.240200\t16.450200
        A\tHeinrich-Collin-Straße\t8-14\t1140\t48.199000\t16.305000
        A\tHeinrich-Collin-Straße\t13\t1140\t48.195000\t16.302000

        """

    private var pack: AddressPack.Contents { AddressPack.parse(text)! }

    /// The door the geocoder would take from the pack's answers, asked in the
    /// order `wienOGDSearch` asks: the Stiege first, then the bare number.
    private func geocode(_ typed: String, plz: String) -> GeocodeResult? {
        let normalized = AddressText.normalize(typed)
        let simplified = AddressText.simplifyHousenumber(normalized)
        let sub = AddressText.housenumberWithSub(normalized)
        let segments = AddressText.subAddressSegments(normalized)
        let numbers = Geocoder.askedNumbers(
            simplified.split(separator: " ").last.flatMap { Geocoder.entranceNumber(String($0)) },
            segments: segments)
        if let sub, let hit = ask(
            sub.query, plz: plz, check: .require(sub.key), segments: segments, numbers: numbers) {
            return hit
        }
        return ask(
            simplified, plz: plz, check: sub.map { .downgrade($0.key) } ?? .absent,
            segments: segments, numbers: numbers)
    }

    private func ask(
        _ query: String, plz: String, check: Geocoder.SubCheck,
        segments: [String], numbers: Set<String>
    ) -> GeocodeResult? {
        let features = AddressPack.registerAnswer(for: query, in: pack)
        guard let best = Geocoder.pickFeature(
            features, plz: plz,
            streetKey: AddressText.matchKey(AddressText.streetNameOnly(query)),
            requireSub: check.required, segments: segments, numbers: numbers)
        else { return nil }
        return Geocoder.result(from: best, query: query, plz: plz, subCheck: check)
    }

    @Test func refusesTextWithoutItsHeader() {
        #expect(AddressPack.parse("A\tGentzgasse\t127\t1180\t48.2\t16.3\n") == nil)
        #expect(AddressPack.parse(text)?.builtOn == "2026-10-31")
    }

    @Test func aStiegeIsItsOwnDoor() throws {
        let hit = try #require(geocode("Gentzgasse 129/2/5/23", plz: "1180"))
        #expect(hit.precision == .exact)
        #expect(hit.lat == 48.230705 && hit.lon == 16.330182)
        #expect(hit.displayName == "Gentzgasse 129/2, 1180 Wien")
    }

    /// The download has number 129 only as its two Stiegen. Asked for the
    /// house, the answer is its entrance — the point the service would give.
    @Test func aHouseKnownOnlyByItsStiegenIsAnsweredWithItsEntrance() throws {
        let hit = try #require(geocode("Gentzgasse 129", plz: "1180"))
        #expect(hit.precision == .exact)
        #expect(hit.lat == 48.230549 && hit.lon == 16.330604)
    }

    @Test func aPlainHouseIsExact() throws {
        let hit = try #require(geocode("Gentzgasse 127", plz: "1180"))
        #expect(hit.precision == .exact)
        #expect(hit.lat == 48.230300)
    }

    @Test func aStreetIsFoundHoweverItIsTyped() throws {
        let hit = try #require(geocode("Dr. Karl Lueger Platz 1", plz: "1010"))
        #expect(hit.precision == .exact)
        #expect(hit.displayName == "Dr.-Karl-Lueger-Platz 1, 1010 Wien")
    }

    @Test func oneLetterOffAStreetIsStillThatStreet() throws {
        let hit = try #require(geocode("Gentzgase 127", plz: "1180"))
        #expect(hit.precision == .exact)
    }

    /// A number the street does not have is a neighbour's door: never exact.
    @Test func aNumberTheStreetDoesNotHaveIsOnlyTheStreet() throws {
        let hit = try #require(geocode("Gentzgasse 999", plz: "1180"))
        #expect(hit.precision == .street)
    }

    /// Number 14 is part of the "8-14" block, not the house across the road
    /// that is numerically nearest — the live service's answer too.
    @Test func aNumberInsideARangeIsThatBuilding() throws {
        let hit = try #require(geocode("Heinrich-Collin-Straße 14/1/DG/35", plz: "1140"))
        #expect(hit.precision == .street)
        #expect(hit.displayName == "Heinrich-Collin-Straße 8-14, 1140 Wien")
    }

    /// "8B" for "8" is the house next door, as the service's answer is.
    @Test func aLetteredNeighbourIsNotTheHouse() {
        let features = AddressPack.registerAnswer(for: "Doningasse 8", in: pack)
        #expect(features.first?.properties.streetNumber == "8B")
        let rank = features.first?.properties.ranking ?? 0
        #expect(rank > 0.1 && rank < 1)
    }

    @Test func aStreetFiledUnderAnotherDistrictIsHinted() {
        let features = AddressPack.registerAnswer(for: "Gentzgasse 129", in: pack)
        #expect(Geocoder.unanimousPostcode(
            features, streetKey: AddressText.matchKey("Gentzgasse"), otherThan: "1090") == "1180")
    }

    @Test func anUnknownStreetAnswersNothing() {
        #expect(AddressPack.registerAnswer(for: "Nirgendwogasse 3", in: pack).isEmpty)
    }

    @Test func entrancesAreAnsweredLikeTheLayer() throws {
        let found = AddressPack.entrances(street: "Gentzgasse", number: "129", plz: "1180", in: pack)
        let point = try #require(Geocoder.pickEntrance(found, number: "129", plz: "1180"))
        #expect(point.lat == 48.230549 && point.lon == 16.330604)
        #expect(AddressPack.entrances(
            street: "Gentzgasse", number: "129", plz: "1090", in: pack).isEmpty)
    }

    // MARK: - The file the app ships with

    @Test func theBundledPackCoversVienna() throws {
        let contents = try #require(AddressPack.shared.contents)
        #expect(contents.streets.count > 5000)
        let rows = contents.streets.values.reduce(0) { $0 + $1.addresses.count }
        #expect(rows > 250_000)
        #expect(AddressPack.bundledDate != nil)
    }

    @Test func theBundledPackPlacesARealStiege() throws {
        let answer = try #require(AddressPack.shared.registerAnswer(for: "Gentzgasse 129/1"))
        let first = try #require(answer.first)
        #expect(first.properties.adresse == "Gentzgasse 129/1")
        #expect(first.properties.postalCode == "1180")
        #expect(first.properties.ranking == 0)
    }

    /// The whole geocoder with the city cut off: the entrance comes from the
    /// pack's two layers, one after the other, as it would from the services.
    @Test func theGeocoderFindsAnEntranceWithTheCityOffline() async throws {
        let geocoder = Geocoder()
        await geocoder.forceCityOffline(true)
        let point = try #require(
            await geocoder.entrance(strasse: "Gentzgasse 129/1/2/23", plz: "1180"))
        #expect(abs(point.lat - 48.2305) < 0.001 && abs(point.lon - 16.3306) < 0.001)
    }
}
