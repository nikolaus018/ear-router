import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import EarRouter

@MainActor
struct FixedPointAddressEditingTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Route.self, Stop.self, StockwerkNote.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func startStopAddressCanBeUpdated() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let route = Route(name: "Test Tour")
        context.insert(route)

        let startStop = Stop(kind: .start, strasse: "Initial Start", plz: "1010", lat: 48.2000, lon: 16.3600)
        startStop.route = route
        context.insert(startStop)

        #expect(startStop.kind == .start)
        #expect(startStop.fixedTitle == "Start")

        // Update Start stop address and coordinates
        let newCoordinate = (lat: 48.2100, lon: 16.3700)
        startStop.strasse = "Stephansplatz 1"
        startStop.plz = "1010"
        startStop.lat = newCoordinate.lat
        startStop.lon = newCoordinate.lon
        startStop.pinned = true
        startStop.precision = nil

        try context.save()

        #expect(startStop.strasse == "Stephansplatz 1")
        #expect(startStop.plz == "1010")
        #expect(startStop.lat == 48.2100)
        #expect(startStop.lon == 16.3700)
        #expect(startStop.pinned == true)
        #expect(startStop.fixedTitle == "Start")
    }

    @Test func endStopAddressCanBeUpdated() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let route = Route(name: "Test Tour")
        context.insert(route)

        let endStop = Stop(kind: .end, strasse: "Initial End", plz: "1010", lat: 48.2000, lon: 16.3600)
        endStop.route = route
        context.insert(endStop)

        #expect(endStop.kind == .end)
        #expect(endStop.fixedTitle == "Ziel")

        // Update Ziel stop address and coordinates
        let newCoordinate = (lat: 48.1900, lon: 16.3800)
        endStop.strasse = "Rennweg 1"
        endStop.plz = "1030"
        endStop.lat = newCoordinate.lat
        endStop.lon = newCoordinate.lon
        endStop.pinned = true

        try context.save()

        #expect(endStop.strasse == "Rennweg 1")
        #expect(endStop.plz == "1030")
        #expect(endStop.lat == 48.1900)
        #expect(endStop.lon == 16.3800)
        #expect(endStop.fixedTitle == "Ziel")
    }

    @Test func updateStopStoreHelperWorksForFixedStops() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let route = Route(name: "Test Tour")
        context.insert(route)

        let startStop = Stop(kind: .start, strasse: "Old Depot", plz: "1230", lat: 48.1500, lon: 16.3000)
        startStop.route = route
        context.insert(startStop)
        try context.save()

        let pinCoord = (lat: 48.2088, lon: 16.3722)
        let moved = try await RouteStore.updateStop(
            startStop,
            kunde: "Start",
            strasse: "Graben 10",
            plz: "1010",
            paket: "",
            notiz: "",
            telefon: "",
            coordinate: pinCoord,
            reroute: false,
            in: context
        )

        #expect(moved)
        #expect(startStop.strasse == "Graben 10")
        #expect(startStop.plz == "1010")
        #expect(startStop.lat == 48.2088)
        #expect(startStop.lon == 16.3722)
        #expect(startStop.pinned == true)
        #expect(startStop.fixedTitle == "Start")
    }
}

/// What the stop editor gets back from the store, now that it closes on the
/// write and routes the tour behind itself rather than under its spinner.
@MainActor
struct StopEditingTests {

    private func makeRoute() throws -> (Route, ModelContext) {
        let context = ModelContext(
            try ModelContainer(
                for: Route.self, Stop.self, StockwerkNote.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let route = try RouteStore.createRoute(name: "Tour", in: context)
        route.needsOptimize = false
        try context.save()
        return (route, context)
    }

    /// Written and saved before the call returns — so closing the sheet at that
    /// point loses nothing — and left flagged for the caller to route.
    @Test func aStopAddedWithoutReroutingIsWrittenAndLeftToRoute() async throws {
        let (route, context) = try makeRoute()

        let stop = try await RouteStore.addStop(
            to: route, kunde: "Fam. Gruber", strasse: "Gentzgasse 129", plz: "1180",
            paket: nil, notiz: nil, coordinate: (lat: 48.2301, lon: 16.3201),
            reroute: false, in: context)

        #expect(route.customerStops.map(\.id) == [stop.id])
        #expect(!context.hasChanges)
        #expect(route.needsOptimize)
    }

    /// An edit that moves nothing says so, and the editor then routes nothing.
    @Test func anEditOfTheNoteAloneMovesNothing() async throws {
        let (route, context) = try makeRoute()
        let stop = try await RouteStore.addStop(
            to: route, kunde: "Fam. Gruber", strasse: "Gentzgasse 129", plz: "1180",
            paket: nil, notiz: nil, coordinate: (lat: 48.2301, lon: 16.3201),
            reroute: false, in: context)

        let moved = try await RouteStore.updateStop(
            stop, kunde: "Fam. Gruber", strasse: "Gentzgasse 129", plz: "1180",
            paket: nil, notiz: "Hund im Hof", reroute: false, in: context)

        #expect(!moved)
        #expect(stop.notiz == "Hund im Hof")
    }
}
