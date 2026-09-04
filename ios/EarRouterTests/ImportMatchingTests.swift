import Testing
import Foundation
import SwiftData
@testable import EarRouter

/// The bulk paste, which is the one screen in this app that can destroy a
/// morning's work.
///
/// A driver re-pastes a corrected list at midday, with half the tour already
/// delivered. Every case here is network-free on purpose — matching an
/// unchanged address is exactly the path that must never reach a geocoder —
/// so these run offline and in milliseconds.
@MainActor
struct ImportMatchingTests {

    private func makeRoute(_ stops: [Stop]) throws -> (Route, ModelContext) {
        let container = try ModelContainer(
            for: Route.self, Stop.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let route = Route(name: "Tour")
        context.insert(route)
        for (i, s) in stops.enumerated() {
            s.orderIndex = i
            s.route = route
            context.insert(s)
        }
        try context.save()
        return (route, context)
    }

    private func stop(
        _ kunde: String, _ strasse: String, _ plz: String = "1180",
        paket: String? = nil, notiz: String? = nil,
        delivered: Bool = false, lat: Double = 48.23
    ) -> Stop {
        let s = Stop(
            kind: .customer, kunde: kunde, strasse: strasse, plz: plz,
            paket: paket, notiz: notiz, lat: lat, lon: 16.32)
        s.delivered = delivered
        return s
    }

    private func entry(
        _ kunde: String, _ strasse: String, _ plz: String = "1180",
        paket: String? = nil, notiz: String? = nil
    ) -> CustomerJSON {
        CustomerJSON(kunde: kunde, strasse: strasse, plz: plz, paket: paket, notiz: notiz)
    }

    // MARK: - The tick has to survive

    /// The whole point of matching rather than delete-and-reinsert. `delivered`
    /// is not in the paste, so anything that replaces a stop loses it — and
    /// what it loses is "this customer has already had their meal".
    @Test func rePastingAnUnchangedListKeepsEveryDeliveredTick() async throws {
        let a = stop("Fam. Gruber", "Gentzgasse 129/1", delivered: true, lat: 48.231)
        let b = stop("Fam. Novak", "Währinger Straße 4", lat: 48.232)
        let (route, context) = try makeRoute([a, b])

        let result = try await RouteStore.importJSON(
            [entry("Fam. Gruber", "Gentzgasse 129/1"),
             entry("Fam. Novak", "Währinger Straße 4")],
            into: route, in: context)

        #expect(result.updated == 2)
        #expect(result.inserted == 0)
        #expect(result.deleted == 0)
        #expect(a.delivered)
        #expect(!b.delivered)
    }

    /// Two households in one Gemeindebau, re-pasted in the other order. Matching
    /// the address bucket positionally would hand each entry the *other's* stop
    /// — writing the names over each other while the delivered ticks stayed
    /// where they were, so the app would claim the wrong customer had been fed.
    @Test func twoCustomersAtOneDoorKeepTheirOwnTicksWhateverOrderThePasteLists() async throws {
        let gruber = stop("Fam. Gruber", "Gentzgasse 129/1", paket: "1 Menü", delivered: true)
        let novak = stop("Fam. Novak", "Gentzgasse 129/1", paket: "2 Menü")
        let (route, context) = try makeRoute([gruber, novak])

        // Deliberately the other way round from the store.
        _ = try await RouteStore.importJSON(
            [entry("Fam. Novak", "Gentzgasse 129/1", paket: "2 Menü"),
             entry("Fam. Gruber", "Gentzgasse 129/1", paket: "1 Menü")],
            into: route, in: context)

        #expect(gruber.kunde == "Fam. Gruber")
        #expect(gruber.delivered)
        #expect(novak.kunde == "Fam. Novak")
        #expect(!novak.delivered)
    }

    /// An address matched through the normalised key can still be spelled
    /// differently in the paste. The stop is the same door — nothing to
    /// geocode — but the list should read back what the driver last pasted.
    @Test func adoptsATidiedSpellingOfAnAddressItAlreadyMatched() async throws {
        let a = stop("Fam. Gruber", "Hauptstr. 5", delivered: true)
        let (route, context) = try makeRoute([a])

        let result = try await RouteStore.importJSON(
            [entry("Fam. Gruber", "Hauptstraße 5")], into: route, in: context)

        #expect(result.updated == 1)
        #expect(result.inserted == 0)
        #expect(a.strasse == "Hauptstraße 5")
        // Same door, so nothing moved and the tick stands.
        #expect(a.delivered)
    }

    @Test func carriesTheEditedPaketAndNotizOntoAMatchedStop() async throws {
        let a = stop("Fam. Gruber", "Gentzgasse 129", paket: "1 Menü", notiz: "alt")
        let (route, context) = try makeRoute([a])

        _ = try await RouteStore.importJSON(
            [entry("Fam. Gruber", "Gentzgasse 129", paket: "2 Menü", notiz: "Hund im Hof")],
            into: route, in: context)

        #expect(a.paket == "2 Menü")
        #expect(a.notiz == "Hund im Hof")
    }

    // MARK: - The paste that would wipe the tour

    /// The worst thing this screen could do. Every entry rejected means nothing
    /// matched, which looks identical to "every customer was removed from the
    /// tour" — and a round that deleted on that reading would wipe a full day of
    /// stops over one malformed paste.
    @Test func aPasteWhereEverythingFailsValidationDeletesNothing() async throws {
        let a = stop("Fam. Gruber", "Gentzgasse 129", delivered: true, lat: 48.231)
        let b = stop("Fam. Novak", "Währinger Straße 4", lat: 48.232)
        let (route, context) = try makeRoute([a, b])

        let result = try await RouteStore.importJSON(
            [entry("", "", ""), entry("Fam. X", "", "1180")],
            into: route, in: context)

        #expect(result.validationFailures.count == 2)
        #expect(result.deletionsSkipped)
        #expect(result.deleted == 0)
        #expect(route.customerStops.count == 2)
        #expect(a.delivered)
    }

    /// One bad entry among good ones is not a reason to drop a customer either:
    /// "not in the paste" and "in the paste but rejected" are the same thing
    /// from here, so a round with any failure deletes nothing at all.
    @Test func oneRejectedEntryHoldsBackEveryDeletionInThatRound() async throws {
        let a = stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231)
        let b = stop("Fam. Novak", "Währinger Straße 4", lat: 48.232)
        let (route, context) = try makeRoute([a, b])

        // Gruber is present and valid; Novak's entry is missing its street, so
        // it never gets a chance to match the stop that is on the route.
        let result = try await RouteStore.importJSON(
            [entry("Fam. Gruber", "Gentzgasse 129"), entry("Fam. Novak", "", "1180")],
            into: route, in: context)

        #expect(result.deletionsSkipped)
        #expect(result.deleted == 0)
        #expect(route.customerStops.count == 2)
    }

    /// …but a clean paste that genuinely drops someone does remove them. The
    /// guard above must not turn into "this screen can never delete".
    @Test func aCleanPasteRemovesTheCustomerItLeftOut() async throws {
        let a = stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231)
        let b = stop("Fam. Novak", "Währinger Straße 4", lat: 48.232)
        let (route, context) = try makeRoute([a, b])

        let result = try await RouteStore.importJSON(
            [entry("Fam. Gruber", "Gentzgasse 129")], into: route, in: context)

        #expect(!result.deletionsSkipped)
        #expect(result.deleted == 1)
        #expect(route.customerStops.map(\.kunde) == ["Fam. Gruber"])
    }

    @Test func refusesAPasteLongerThanOneTourCanHold() async throws {
        let (route, context) = try makeRoute([])
        let tooMany = (0...maxBulkStops).map { entry("K\($0)", "Gasse \($0)") }
        await #expect(throws: AppError.self) {
            _ = try await RouteStore.importJSON(tooMany, into: route, in: context)
        }
    }
}

/// The JSON either side of the bulk editor: what it accepts from a paste, and
/// what it hands back to be pasted somewhere else.
struct ImportParsingTests {

    @Test func acceptsABarePastedList() throws {
        let list = try RouteStore.parseImport(
            #"[{"kunde":"Fam. Gruber","strasse":"Gentzgasse 129","plz":"1180"}]"#)
        #expect(list.count == 1)
        #expect(list[0].kunde == "Fam. Gruber")
    }

    /// The web app this replaced wrapped its export in an object.
    @Test func acceptsTheWrappedShapeTheWebAppExported() throws {
        let list = try RouteStore.parseImport(
            #"{"stops":[{"kunde":"A","strasse":"Gasse 1","plz":"1100"}]}"#)
        #expect(list.count == 1)
    }

    @Test func rejectsAnythingElse() throws {
        #expect(throws: AppError.self) { try RouteStore.parseImport("not json") }
        #expect(throws: AppError.self) { try RouteStore.parseImport("") }
        #expect(throws: AppError.self) { try RouteStore.parseImport("[1, 2, 3]") }
    }

    /// One entry missing a key is a problem with that entry, not with the
    /// paste. Decoded strictly it aborted all thirty stops with a message that
    /// named none of them; now it survives decoding and is reported by name.
    @Test func survivesAnEntryWithAMissingKeySoItCanBeNamedLater() throws {
        let list = try RouteStore.parseImport(
            """
            [{"kunde":"Fam. Gruber","strasse":"Gentzgasse 129","plz":"1180"},
             {"kunde":"Fam. Novak","strasse":"Währinger Straße 4"}]
            """)
        #expect(list.count == 2)
        #expect(list[1].kunde == "Fam. Novak")
        #expect(list[1].plz.isEmpty)
    }

    /// Nominatim enforces its policy per client, so a client that sends it
    /// garbage risks the whole app being blocked. These are the guards.
    @Test func refusesValuesThatShouldNeverReachAThirdPartyService() {
        #expect(throws: AppError.self) {
            try RouteStore.validateCustomerFields(
                kunde: String(repeating: "a", count: FieldLimits.kunde + 1),
                strasse: "Gasse 1", paket: nil, notiz: nil)
        }
        #expect(throws: AppError.self) {
            try RouteStore.validateCustomerFields(
                kunde: "Fam.\u{0007}Gruber", strasse: "Gasse 1", paket: nil, notiz: nil)
        }
        // A note is the one field a newline belongs in.
        #expect(throws: Never.self) {
            try RouteStore.validateCustomerFields(
                kunde: "Fam. Gruber", strasse: "Gasse 1", paket: nil,
                notiz: "Bitte laut klingeln.\nHund im Hof.")
        }
    }
}
