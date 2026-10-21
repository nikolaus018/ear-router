<h1 align="center">EAR Router</h1>

<p align="center">
  <b>Offline-first route planner for a real delivery service.</b><br>
  Built for and used by the drivers of Essen auf Rädern (Meals on Wheels) in Vienna. Native SwiftUI, no third-party dependencies.
</p>

<p align="center">
  <a href="https://github.com/nikolaus018/ear-router/actions/workflows/ci.yml"><img src="https://github.com/nikolaus018/ear-router/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/nikolaus018/ear-router" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/iOS-26-blue" alt="iOS 26">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/SwiftData-MapKit-green" alt="SwiftData, MapKit">
</p>

<p align="center">
  <img src="docs/screenshots/tour.png" alt="Tour with arrival times" width="23%">
  <img src="docs/screenshots/now.png" alt="Next stop" width="23%">
  <img src="docs/screenshots/map.png" alt="Route map" width="23%">
  <img src="docs/screenshots/import.png" alt="Import review" width="23%">
</p>
<p align="center"><sub>Demo data. Tour with arrival estimates, the stop to drive to now, the optimised route, and the import review.</sub></p>

Delivery route planner for *Essen auf Rädern* (Meals on Wheels) in Vienna,
for the Arbeiter-Samariter-Bund Österreichs.

A native iOS app. Tours, stops, delivery status and every floor ever learned
live on the phone; the network is needed only to load a day's tour from the
Zusteller-Portal, to look an address up and to optimise the route.

```
ios/            The app. Open ios/EarRouter.xcodeproj in Xcode.
ios/Tools/      Draws the app icon. Not part of the build.
```

## The app

SwiftUI, SwiftData, MapKit. iOS 26, Swift 6 with strict concurrency. No
third-party dependencies.

| | |
|---|---|
| `Model/` | `Route`, `Stop` and `StockwerkNote` — the whole persistent store — plus its versioned schema and the migrations between versions. `Stop` records a `DeliveryOutcome`, not a tick: delivered, bei Nachbarn, nicht angetroffen, abbestellt |
| `Model/RouteSnapshot` | Everything one pass of a stop list needs to know about a tour, worked out in a single walk of its stops — including when the van gets to each remaining door, off the day's own measured pace |
| `Model/Districts` | Vienna's 23 districts, and `Postcodes` — any Austrian PLZ is a valid stop |
| `Services/AddressText` | Address normalisation, Stiege/Parzelle sub-addresses, match keys — and `Search`, the one rule every search field in the app answers to |
| `Services/Geocoder` | Wien OGD → Nominatim cascade, throttled, with wrong-district detection. The city register is only asked about Vienna postcodes; anywhere else in Austria is Nominatim alone |
| `Services/GeocodeCache` | Resolved addresses, and the addresses known not to exist |
| `Services/OSRMClient` | `/route` and `/trip`, with a public-server fallback |
| `Services/RouteOptimizer` | Stop ordering and route geometry |
| `Services/RouteStore` | Every mutation, plus the JSON bulk import |
| `Services/BackupArchive` | The whole store out to one readable JSON file, and back again. Everything here lives on one phone, which is the point of it and also the risk; this is the other half of that deal |
| `Services/SameDoor` | Which stops share a front door |
| `Services/StockwerkStore` | "Globale Infos": what is kept about a customer across every tour — which floor they live on, and whatever the driver wrote down. The things about a delivery that never change and that no list the office sends ever carries: asked once, in the stairwell, and on the row from then on |
| `Services/TourReport` | The day in the form the office has to hear it, plain text, ready to share |
| `Services/Preflight` | The checklist that runs while the van is still in the yard, where every failure this app can have is still cheap |
| `Services/NextStopIntent` | "Hey Siri, nächster Stopp" — read-only, and deliberately so |
| `Services/GourmetPortal` | The Zusteller-Portal: login, the day's tours and their deliveries; the login lives in the Keychain |
| `Support/NavigationHandoff` | Hands a stop to Apple Maps, Waze or Google Maps: a hand-placed pin if there is one, else the house number's entrance from the city's register, else the address. The map pin stays on the building |
| `Support/Theme` | The palette, and why each colour is the colour it is |

### External services

| Service | Used for |
|---|---|
| Zusteller-Portal (`odoo.gourmet.at`) | Loading a day's tour instead of typing it in |
| [Adressservice Wien](https://digitales.wien.gv.at/adressservice-doku) | Primary geocoder — the city's own building register |
| [Nominatim](https://nominatim.openstreetmap.org) | Fallback geocoder. Rate-limited to 1 req/s in `Geocoder` |
| `osrm.ringtwo.win` | Routing and stop-order optimisation. Configurable in Mehr; falls back to the public OSRM demo server |
| Apple MapKit | The map |

### Building

```bash
cd ios
xcodebuild -project EarRouter.xcodeproj -scheme EarRouter \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
cd ios
xcodebuild -project EarRouter.xcodeproj -scheme EarRouter \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

### The two schemes

| Scheme | Run builds | For |
|---|---|---|
| `EarRouter` | Debug | Developing. Debugger, incremental builds, `@testable` |
| `EarRouter (Fahrbetrieb)` | Release | Installing the driver's phone |

Installing from Xcode *is* how this app ships — a free developer account signs
a profile good for seven days, so the phone is reinstalled about weekly,
straight from the Run button (see `Support/SideloadExpiry`). Whatever Run
builds is what somebody uses for a week, and Debug means `-Onone`: no
inlining, no generic specialisation, no ARC elision. That is the wrong
build to hand over for the map's per-frame change keys, the union-find behind
"2 an dieser Tür", and the polyline simplification.

So: develop with `EarRouter`, and reinstall the van's phone with
`EarRouter (Fahrbetrieb)`. Tests run under Debug in both, which is where
`ENABLE_TESTABILITY` lives.

## License

MIT, see [`LICENSE`](LICENSE).
