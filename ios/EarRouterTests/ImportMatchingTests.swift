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

        // Nothing in the paste differs from what is already stored, so nothing
        // is written and nothing is reported as changed. "Aktualisiert: 2" for
        // an import that changed nothing is a report about the app's own
        // plumbing rather than about the tour.
        #expect(result.updated == 0)
        #expect(result.inserted == 0)
        #expect(result.deleted == 0)
        #expect(a.delivered)
        #expect(!b.delivered)
    }

    /// The other half of that rule: an entry that really did change is counted,
    /// once, however many of its fields moved.
    @Test func anEntryThatActuallyChangedIsCountedOnce() async throws {
        let a = stop("Fam. Gruber", "Gentzgasse 129", paket: "1 Menü")
        let b = stop("Fam. Novak", "Währinger Straße 4", lat: 48.232)
        let (route, context) = try makeRoute([a, b])

        let result = try await RouteStore.importJSON(
            [entry("Fam. Gruber", "Gentzgasse 129", paket: "2 Menü", notiz: "Hund im Hof"),
             entry("Fam. Novak", "Währinger Straße 4")],
            into: route, in: context)

        #expect(result.updated == 1)
        #expect(a.paket == "2 Menü")
        #expect(a.notiz == "Hund im Hof")
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
    /// Two customers with the same name, and the pass that must decline.
    ///
    /// Matching a moved customer by name is what keeps "Fam. Gruber moved to a
    /// new flat" from reading as a delete plus an insert — which loses the
    /// delivered tick. But it is deliberately conservative: a name has to be
    /// unambiguous on *both* sides, or the pass declines. Guessing between two
    /// households called Fam. Gruber would write one customer's address, Paket
    /// and Notiz over the other's while the tick stayed where it was.
    @Test func twoCustomersWithOneNameAreNotMatchedByIt() throws {
        let (route, _) = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129"),
            stop("Fam. Gruber", "Alser Straße 21"),
        ])
        // Both have moved, so neither matches on address. The name is the only
        // thing left, and it names two people.
        let paste = [
            CustomerJSON(kunde: "Fam. Gruber", strasse: "Neubaugasse 1", plz: "1070",
                         paket: nil, notiz: nil),
            CustomerJSON(kunde: "Fam. Gruber", strasse: "Praterstraße 1", plz: "1020",
                         paket: nil, notiz: nil),
        ]
        let match = RouteStore.match(paste, against: route.customerStops)

        #expect(match.unresolved.count == 2)
        #expect(match.unresolved.allSatisfy { $0.existing == nil })
        #expect(match.matched.isEmpty)
    }

    /// The same rule from the other side: one on the route, two in the paste.
    @Test func aNameThatIsAmbiguousInThePasteIsNotMatchedEither() throws {
        let (route, _) = try makeRoute([stop("Fam. Gruber", "Gentzgasse 129")])
        let paste = [
            CustomerJSON(kunde: "Fam. Gruber", strasse: "Neubaugasse 1", plz: "1070",
                         paket: nil, notiz: nil),
            CustomerJSON(kunde: "Fam. Gruber", strasse: "Praterstraße 1", plz: "1020",
                         paket: nil, notiz: nil),
        ]
        let match = RouteStore.match(paste, against: route.customerStops)
        #expect(match.matched.isEmpty)
        #expect(match.unresolved.allSatisfy { $0.existing == nil })
    }

    /// And when the name *is* unambiguous on both sides it still matches,
    /// which is the whole point of the pass.
    @Test func oneCustomerWhoMovedIsStillMatchedByName() throws {
        let (route, _) = try makeRoute([stop("Fam. Gruber", "Gentzgasse 129")])
        let existing = try #require(route.customerStops.first)
        let paste = [CustomerJSON(
            kunde: "Fam. Gruber", strasse: "Neubaugasse 1", plz: "1070",
            paket: nil, notiz: nil)]
        let match = RouteStore.match(paste, against: route.customerStops)
        #expect(match.unresolved.count == 1)
        #expect(match.unresolved.first?.existing?.id == existing.id)
        #expect(match.matched.contains(existing.id))
    }

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

/// What the paste screen asks before it applies anything.
///
/// Every other destructive action in this app confirms first: deleting a stop
/// names it, deleting a tour names it twice. Applying a paste removed as many
/// customers as it liked and said nothing — and the two ways to trigger that
/// are the two most ordinary things anyone does on that screen. "Leeren" used
/// to leave a valid empty list behind, so Leeren-then-Übernehmen wiped the
/// round in two taps; and losing a few lines to a selection in a monospace
/// editor on a phone looks exactly like a correct paste.
///
/// The preview has to decide "this stop is accounted for" by *exactly* the
/// rules the import will use, or it warns about the wrong customers — which is
/// why it and `importJSON` now share one matcher.
@MainActor
struct DeletionPreviewTests {

    private func makeRoute(_ stops: [Stop]) throws -> Route {
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
        return route
    }

    private func stop(_ kunde: String, _ strasse: String, lat: Double = 48.23) -> Stop {
        Stop(kind: .customer, kunde: kunde, strasse: strasse, plz: "1180",
             lat: lat, lon: 16.32)
    }

    private func entry(_ kunde: String, _ strasse: String) -> CustomerJSON {
        CustomerJSON(kunde: kunde, strasse: strasse, plz: "1180", paket: nil, notiz: nil)
    }

    /// The paste that says nothing takes everything. This is the Leeren trap,
    /// and it is the one the driver must be asked about.
    @Test func anEmptyListAccountsForNobody() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231),
            stop("Hr. Novak", "Alser Straße 21", lat: 48.232),
        ])
        let preview = RouteStore.deletionPreview([], in: route)
        #expect(preview.names.count == 2)
        #expect(preview.names.contains("Fam. Gruber"))
        #expect(preview.names.contains("Hr. Novak"))
        #expect(!preview.blockedByFailures)
    }

    /// The normal morning: the same list back again, nothing to warn about, no
    /// dialog in the way of the one action the screen exists for.
    @Test func anUnchangedListWarnsAboutNothing() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231),
            stop("Hr. Novak", "Alser Straße 21", lat: 48.232),
        ])
        let preview = RouteStore.deletionPreview(
            [entry("Fam. Gruber", "Gentzgasse 129"), entry("Hr. Novak", "Alser Straße 21")],
            in: route)
        #expect(preview.names.isEmpty)
    }

    /// One customer dropped off the round: named, and only that one.
    @Test func namesExactlyTheCustomersTheListDropped() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231),
            stop("Hr. Novak", "Alser Straße 21", lat: 48.232),
            stop("Fr. Berger", "Hauptstraße 3", lat: 48.233),
        ])
        let preview = RouteStore.deletionPreview(
            [entry("Fam. Gruber", "Gentzgasse 129"), entry("Fr. Berger", "Hauptstraße 3")],
            in: route)
        #expect(preview.names == ["Hr. Novak"])
    }

    /// A customer who moved is *not* a deletion — the import edits their stop
    /// in place, keeping the delivered tick. The warning has to know that, or
    /// it cries wolf on the one case the matcher goes furthest out of its way
    /// to handle.
    @Test func aCustomerWhoMovedIsNotADeletion() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231),
        ])
        let preview = RouteStore.deletionPreview(
            [entry("Fam. Gruber", "Alser Straße 21")], in: route)
        #expect(preview.names.isEmpty)
    }

    /// The tidied spelling of an address the store still holds in its old form
    /// is the same door, and the same stop.
    @Test func aRespelledAddressIsNotADeletion() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Grossfeldstr. 9/Parz.68", lat: 48.231),
        ])
        let preview = RouteStore.deletionPreview(
            [entry("Fam. Gruber", "Großfeldstraße 9 / Parz. 68")], in: route)
        #expect(preview.names.isEmpty)
    }

    /// An entry that will fail validation stops the import deleting anything at
    /// all, so there is nothing to warn about — warning anyway would name
    /// customers who are then still there afterwards.
    @Test func aPasteThatWillFailValidationDeletesNothingAndWarnsAboutNothing() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231),
            stop("Hr. Novak", "Alser Straße 21", lat: 48.232),
        ])
        // No street: rejected per entry, which is what makes the whole round
        // keep its deletions.
        let preview = RouteStore.deletionPreview(
            [entry("Fam. Gruber", "Gentzgasse 129"), entry("Fr. Berger", "")], in: route)
        #expect(preview.blockedByFailures)
        #expect(preview.names.isEmpty)
    }

    /// The preview and the import must reject the same fields. In particular,
    /// a malformed phone number must not make the preview warn about deletions
    /// that the import will refuse before changing the route.
    @Test func aPasteWithAnInvalidPhoneAlsoBlocksTheDeletionPreview() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231),
            stop("Hr. Novak", "Alser Straße 21", lat: 48.232),
        ])
        let invalid = CustomerJSON(
            kunde: "Fam. Gruber", strasse: "Gentzgasse 129", plz: "1180",
            paket: nil, notiz: nil, telefon: String(repeating: "1", count: FieldLimits.telefon + 1))
        let preview = RouteStore.deletionPreview([invalid], in: route)
        #expect(preview.blockedByFailures)
        #expect(preview.names.isEmpty)
    }

    /// Two households behind one front door: a paste listing both accounts for
    /// both, and a paste listing one accounts for one.
    @Test func twoCustomersAtOneDoorAreCountedSeparately() throws {
        let route = try makeRoute([
            stop("Fam. Gruber", "Gentzgasse 129", lat: 48.231),
            stop("Fr. Berger", "Gentzgasse 129", lat: 48.231),
        ])
        #expect(
            RouteStore.deletionPreview(
                [entry("Fam. Gruber", "Gentzgasse 129"), entry("Fr. Berger", "Gentzgasse 129")],
                in: route
            ).names.isEmpty)
        #expect(
            RouteStore.deletionPreview(
                [entry("Fam. Gruber", "Gentzgasse 129")], in: route
            ).names == ["Fr. Berger"])
    }

    /// A stop with no name at all still has to be nameable in the warning —
    /// "wird gelöscht: " followed by nothing tells the driver less than
    /// nothing.
    @Test func aStopWithNoNameIsNamedByItsAddress() throws {
        let unnamed = Stop(
            kind: .customer, kunde: nil, strasse: "Gentzgasse 129", plz: "1180",
            lat: 48.231, lon: 16.32)
        let route = try makeRoute([unnamed])
        let preview = RouteStore.deletionPreview([], in: route)
        #expect(preview.names == ["Gentzgasse 129, 1180"])
    }
}
