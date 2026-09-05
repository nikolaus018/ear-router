# EAR Router

Delivery route planner for *Essen auf Rädern* (Meals on Wheels) in Vienna,
for the Arbeiter-Samariter-Bund Österreichs.

A native iOS app. Tours, stops and delivery status live on the phone; the
network is needed only to look an address up and to optimise the route.

```
ios/            The app. Open ios/EarRouter.xcodeproj in Xcode.
legacy-web/     The previous Rust + PWA version, kept for reference.
icon.png        ASBÖ logo, source for the app icon.
```

## The app

SwiftUI, SwiftData, MapKit. iOS 26, Swift 6 with strict concurrency. No
third-party dependencies.

| | |
|---|---|
| `Model/` | `Route` and `Stop` — the whole persistent store — plus its versioned schema |
| `Services/AddressText` | Address normalisation, Stiege/Parzelle sub-addresses, match keys |
| `Services/Geocoder` | Wien OGD → Nominatim cascade, throttled, with wrong-district detection |
| `Services/GeocodeCache` | Resolved addresses, and the addresses known not to exist |
| `Services/ListeOCR` | Reads the printed tour list off a photo of it — rows, columns and all |
| `Services/OSRMClient` | `/route` and `/trip`, with a public-server fallback |
| `Services/RouteOptimizer` | Stop ordering and route geometry |
| `Services/RouteStore` | Every mutation, plus the JSON bulk import |
| `Services/SameDoor` | Which stops share a front door |

### External services

| Service | Used for |
|---|---|
| [Adressservice Wien](https://digitales.wien.gv.at/adressservice-doku) | Primary geocoder — the city's own building register |
| [Nominatim](https://nominatim.openstreetmap.org) | Fallback geocoder. Rate-limited to 1 req/s in `Geocoder` |
| `osrm.ringtwo.win` | Routing and stop-order optimisation. Configurable in Mehr; falls back to the public OSRM demo server |
| Apple MapKit | The map |

OCR runs entirely on the device (Vision `RecognizeDocumentsRequest`); no photo
leaves the phone. Vision supplies the words and where they sit; `ListeOCR`
works out the table itself, because a photographed page of this list has its
rows wrapped over two and three lines with no clear space between them, and
leans differently at the top of the sheet than at the bottom.

### Building

```bash
cd ios
xcodebuild -project EarRouter.xcodeproj -scheme EarRouter \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## legacy-web

The Rust (Axum + SQLite) backend and the single-file PWA it served. Superseded
by `ios/`, which does the same work without a server: the phone calls the
geocoders and OSRM directly and keeps its own data. Kept because it is the
reference for how every rule in this app is meant to behave.
