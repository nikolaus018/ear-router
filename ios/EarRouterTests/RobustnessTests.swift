import Testing
import CoreLocation
@testable import EarRouter

/// A re-check exists to *improve* an approximate stop. The one thing it must
/// never do is make one worse — the register can answer a street-level address
/// with a bare district after a reindex, and writing that back moves a usable
/// pin into the middle of the Bezirk.
struct RecheckPrecisionTests {

    @Test func anExactAnswerBeatsEverything() {
        #expect(RouteStore.isAtLeastAsGood(nil, as: nil))
        #expect(RouteStore.isAtLeastAsGood(nil, as: .street))
        #expect(RouteStore.isAtLeastAsGood(nil, as: .district))
    }

    @Test func aCoarserAnswerIsRefused() {
        #expect(!RouteStore.isAtLeastAsGood(.street, as: nil))
        #expect(!RouteStore.isAtLeastAsGood(.district, as: nil))
        #expect(!RouteStore.isAtLeastAsGood(.district, as: .street))
    }

    @Test func theSamePrecisionIsAllowedThrough() {
        // Same precision, possibly a better position — the caller still gets to
        // decide whether the point moved far enough to be worth writing.
        #expect(RouteStore.isAtLeastAsGood(.street, as: .street))
        #expect(RouteStore.isAtLeastAsGood(.district, as: .district))
        #expect(RouteStore.isAtLeastAsGood(.street, as: .district))
    }

    @Test func exactAndNilRankTheSame() {
        // `.exact` never reaches a `Stop` — it is stored as `nil` — but the
        // geocoder speaks in it, so the two must not be ordered apart.
        #expect(RouteStore.isAtLeastAsGood(.exact, as: nil))
        #expect(RouteStore.isAtLeastAsGood(nil, as: .exact))
    }
}

/// `0, 0` is a finite coordinate in the Gulf of Guinea, and it is what every
/// unset row carries. Nothing that draws or navigates may take it at face value.
struct UnusableCoordinateTests {

    private func stop(lat: Double, lon: Double, precision: Precision? = nil) -> Stop {
        Stop(kind: .customer, kunde: "Test", strasse: "Teststraße 1", plz: "1210",
             lat: lat, lon: lon, precision: precision)
    }

    @Test func zeroFallsBackToVienna() {
        let c = stop(lat: 0, lon: 0).coordinate
        #expect(c.latitude == Coordinates.viennaCenter.lat)
        #expect(c.longitude == Coordinates.viennaCenter.lon)
    }

    @Test func aPointOutsideTheBoxFallsBackToo() {
        // Graz — a real place, and a real Nominatim answer for a Viennese
        // street name that also exists there. Still a bad row, because this
        // stop's own postcode says 1210.
        let c = stop(lat: 47.0707, lon: 15.4395).coordinate
        #expect(c.latitude == Coordinates.viennaCenter.lat)
    }

    /// The same point under a Graz postcode is simply a stop in Graz. The
    /// tight box belongs to the postcode, not to the app.
    @Test func aPointOutsideViennaUnderItsOwnPostcodeIsKept() {
        let s = Stop(kind: .customer, kunde: "Test", strasse: "Teststraße 1", plz: "8010",
                     lat: 47.0707, lon: 15.4395)
        #expect(s.coordinate.latitude == 47.0707)
        #expect(s.coordinate.longitude == 15.4395)
    }

    @Test func aRealViennaPointIsKept() {
        let c = stop(lat: 48.2354, lon: 16.3298).coordinate
        #expect(c.latitude == 48.2354)
        #expect(c.longitude == 16.3298)
    }

    @Test func navigationSendsAnUnusablePointAsTextInstead() {
        // An exact-looking stop whose coordinates are not usable must be handed
        // over as an address, not driven to as a point.
        let url = NavigationHandoff.Provider.apple.point(lat: 0, lon: 0)
        let broken = stop(lat: 0, lon: 0)
        #expect(NavigationHandoff.url(for: broken) != url)
        #expect(NavigationHandoff.url(for: broken)?.absoluteString.contains("Teststra") == true)
    }

    /// The in-app map draws the register's point; the navigation app is handed
    /// the address, even for a stop the register placed exactly.
    @Test func navigationSendsEvenAnExactStopAsItsAddress() {
        let url = NavigationHandoff.url(for: stop(lat: 48.2354, lon: 16.3298))?.absoluteString
        #expect(url?.contains("Teststra") == true)
        #expect(url?.contains("48.235400") == false)
    }

    /// Route planning was the last consumer taking the stored pair at face
    /// value. It is also the one that fails worst: OSRM answers a request
    /// carrying a point in the Gulf of Guinea with `NoSegment` for the *whole*
    /// trip, so one unusable row left the entire tour unroutable behind an
    /// amber banner whose retry could never clear it.
    @Test func planningNeverSendsAnUnusablePointToTheRouter() {
        let snapshot = stop(lat: 0, lon: 0).planningSnapshot
        #expect(snapshot.lat == Coordinates.viennaCenter.lat)
        #expect(snapshot.lon == Coordinates.viennaCenter.lon)
        #expect(Coordinates.isPlausible(lat: snapshot.lat, lon: snapshot.lon))
    }

    @Test func planningKeepsARealPointExactly() {
        let snapshot = stop(lat: 48.2354, lon: 16.3298).planningSnapshot
        #expect(snapshot.lat == 48.2354)
        #expect(snapshot.lon == 16.3298)
    }

    /// The door grouping quantizes a coordinate into an integer bucket, which
    /// is only safe on a bounded value — and an out-of-range point is not a
    /// door anyone shares in any case.
    @Test func anUnusablePointIsNotADoorToShare() {
        let a = stop(lat: 0, lon: 0)
        let b = stop(lat: 0, lon: 0)
        // Distinct addresses, so nothing but the point could group them.
        b.strasse = "Anderegasse 9"
        #expect(SameDoor.counts(for: [a, b])[a.id] == 1)
        #expect(SameDoor.counts(for: [a, b])[b.id] == 1)
    }
}

/// One-line guards that only matter the day someone calls them differently.
struct StringGuardTests {

    @Test func trimmingAnEmptySuffixTerminates() {
        // Without its guard this loops forever: every string ends with "", and
        // removing nothing leaves it ending with "" again.
        #expect("https://example.com".trimmingSuffix("") == "https://example.com")
        #expect("".trimmingSuffix("") == "")
    }

    @Test func trimmingStillStripsRealSuffixes() {
        #expect("https://example.com///".trimmingSuffix("/") == "https://example.com")
        #expect("https://example.com".trimmingSuffix("/") == "https://example.com")
    }
}

/// Which feature the city's address register answer is read as.
///
/// The register is tolerant about how a street is spelled *to* it and
/// canonical about how it spells one *back*, so the check that the answer is
/// the street we asked for has to compare the two the same forgiving way the
/// rest of the app does. Getting this wrong does not fail loudly — it quietly
/// discards a precise answer and leaves the driver an approximate pin.
struct OGDFeaturePickingTests {

    private func feature(
        street: String, plz: String, ranking: Double, adresse: String? = nil
    ) -> Geocoder.OGDFeature {
        Geocoder.OGDFeature(
            geometry: Geocoder.OGDGeometry(coordinates: [16.37, 48.21]),
            properties: Geocoder.OGDProperties(
                streetName: street, postalCode: plz, kategorie: "Adresse",
                adresse: adresse, ranking: ranking))
    }

    @Test func acceptsTheRegistersOwnHyphenationOfAStreetTypedWithSpaces() {
        // Exactly what data.wien.gv.at answers for "Dr. Karl Lueger-Platz 1":
        // the right building, ranked 0.0, spelled with hyphens throughout.
        let picked = Geocoder.pickFeature(
            [feature(street: "Dr.-Karl-Lueger-Platz", plz: "1010", ranking: 0.0)],
            plz: "1010",
            streetKey: AddressText.matchKey("Dr. Karl Lueger-Platz"),
            requireSub: nil)
        #expect(picked != nil)
    }

    @Test func stillRefusesADifferentStreetTheRegisterOffersInstead() {
        // The register answers "Anton-Baumann-Gasse" with "Anton-Baumann-Park".
        // Forgiving about punctuation must not mean forgiving about the name.
        let picked = Geocoder.pickFeature(
            [feature(street: "Anton-Baumann-Park", plz: "1180", ranking: 1.0)],
            plz: "1180",
            streetKey: AddressText.matchKey("Anton-Baumann-Gasse"),
            requireSub: nil)
        #expect(picked == nil)
    }

    @Test func refusesAnotherDistrictEvenOnTheRightStreet() {
        let picked = Geocoder.pickFeature(
            [feature(street: "Hauptstraße", plz: "1030", ranking: 0.0)],
            plz: "1210",
            streetKey: AddressText.matchKey("Hauptstraße"),
            requireSub: nil)
        #expect(picked == nil)
    }

    @Test func filtersBeforeItRanks() {
        // The best-ranked candidate is in the wrong district; the right one is
        // further down the same response. Ranking first would report "not
        // found" with the answer sitting in the list.
        let picked = Geocoder.pickFeature(
            [
                feature(street: "Gentzgasse", plz: "1090", ranking: 0.0),
                feature(street: "Gentzgasse", plz: "1180", ranking: 0.4),
            ],
            plz: "1180",
            streetKey: AddressText.matchKey("Gentzgasse"),
            requireSub: nil)
        #expect(picked?.properties.postalCode == "1180")
    }

    @Test func takesTheBestRankedOfWhatSurvivesTheFilters() {
        let picked = Geocoder.pickFeature(
            [
                feature(street: "Gentzgasse", plz: "1180", ranking: 120.0),
                feature(street: "Gentzgasse", plz: "1180", ranking: 0.2),
            ],
            plz: "1180",
            streetKey: AddressText.matchKey("Gentzgasse"),
            requireSub: nil)
        #expect(picked?.properties.ranking == 0.2)
    }

    @Test func aRequiredSubAddressMustActuallyComeBack() {
        // Asked for Parzelle 68, offered the colony's own entrance. Accepting
        // it would put the van 130 m and a walk from the plot.
        let wanted = AddressText.subAddressKey("Parz.68")
        let neighbour = Geocoder.pickFeature(
            [feature(
                street: "Großfeldstraße", plz: "1210", ranking: 0.0,
                adresse: "Großfeldstraße 9")],
            plz: "1210",
            streetKey: AddressText.matchKey("Großfeldstraße"),
            requireSub: wanted)
        #expect(neighbour == nil)

        let right = Geocoder.pickFeature(
            [feature(
                street: "Großfeldstraße", plz: "1210", ranking: 0.0,
                adresse: "Großfeldstraße 9 Parz. 68")],
            plz: "1210",
            streetKey: AddressText.matchKey("Großfeldstraße"),
            requireSub: wanted)
        #expect(right != nil)
    }
}

/// A comparison key has to survive a keyboard.
///
/// Vienna's address register accepts an address typed without umlauts and
/// answers with the canonical spelling — every pair below was measured against
/// the live service, and every one came back at `Ranking` 0.0 or 1.0, i.e. the
/// right building. Comparing the two spellings without folding rejects the
/// register's own exact answer and drops the lookup through to an approximate
/// Nominatim pin.
struct GermanSpellingFoldTests {

    private func sameStreet(_ typed: String, _ register: String) -> Bool {
        AddressText.matchKey(typed) == AddressText.matchKey(register)
    }

    @Test func sharpSFoldsOntoDoubleS() {
        #expect(sameStreet("Grosse Neugasse", "Große Neugasse"))
        #expect(sameStreet("Gusshausstrasse", "Gußhausstraße"))
    }

    @Test func umlautsFoldOntoTheirExpandedForm() {
        #expect(sameStreet("Doeblinger Hauptstrasse", "Döblinger Hauptstraße"))
        #expect(sameStreet("Waehringer Guertel", "Währinger Gürtel"))
        #expect(sameStreet("Weissgerberlaende", "Weißgerberlände"))
    }

    @Test func aStemAndItsSuffixAreBothFolded() {
        // `normalize` already folds the "strasse"/"straße" *suffix*, which is
        // why this one used to be a miss: the ending matched and the stem did
        // not.
        #expect(sameStreet("Gusshausstrasse 1", "Gußhausstraße 1"))
    }

    @Test func differentStreetsStayDifferent() {
        #expect(!sameStreet("Anton-Baumann-Gasse", "Anton-Baumann-Park"))
        #expect(!sameStreet("Gentzgasse", "Gentzstraße"))
        // Folding expands rather than contracts, so a name that really has a
        // space keeps it and does not collapse onto the compound.
        #expect(!sameStreet("Haupt Straße", "Hauptstraße"))
    }

    @Test func housenumbersSurviveTheFold() {
        #expect(!sameStreet("Gentzgasse 129/1", "Gentzgasse 12/91"))
        #expect(sameStreet("Grosse Neugasse 5", "Große Neugasse 5"))
    }

    @Test func aSubAddressFoldsTheSameWay() {
        #expect(AddressText.subAddressKey("Tür 3") == AddressText.subAddressKey("Tuer 3"))
        #expect(AddressText.subAddressKey("Parz.68") == AddressText.subAddressKey("Parz. 68"))
    }

    @Test func aReExportedListStillMatchesTheStopItAlreadyHas() {
        // The re-paste path: a system that strips umlauts must not turn an
        // existing customer into a delete plus an insert, which is what loses
        // the tick saying the meal was delivered.
        #expect(sameStreet("Waehringer Guertel 104", "Währinger Gürtel 104"))
    }
}
