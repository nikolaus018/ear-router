// Service worker for EAR Routing — read straight off disk on every request
// and served at /sw.js, exactly like index.html (see `assets_dir`/
// `read_static` in src/main.rs), so this stays a two-file app with no
// separate static asset pipeline and editing it takes effect without a
// rebuild.
//
// This app is NOT fully offline-capable: adding/editing a stop calls
// Nominatim/Wien-OGD (geocoding) and OSRM (routing) live every time, and
// those responses are never cached here on purpose — a stale geocode or
// route would be actively wrong, not just outdated. What this cache DOES
// buy: the app shell (this origin's "/") and every third-party asset it
// needs to render (MapLibre GL JS/CSS, the
// OpenFreeMap style/glyphs/sprites/vector tiles and the Wien-Luftbild
// aerial tiles already panned into view)
// survive a dropped connection instead of a blank white tab — a driver
// mid-route who loses signal can still see the route they already loaded.
// Two caches, not one, because the two hold very different things and only
// one of them can grow without limit. The shell is a handful of files;
// map tiles are unbounded — a driver panning around Vienna for a week will
// happily accumulate hundreds of megabytes of them, and browsers respond
// to that by evicting the whole origin's storage, app shell included. Kept
// separate, the tiles can be trimmed (see `trimCache`) without ever
// touching the files the app needs to start.
const CACHE_NAME = 'ear-routing-v2';
const TILE_CACHE = 'ear-routing-tiles-v1';
// Raised from 600 when the aerial basemap landed (see `TILE_HOSTS`). A
// driver zoomed into a building on the Luftbild pulls the aerial imagery
// AND the label overlay for the same view, and the labels are fetched at
// retina density — four half-size tiles per nominal one (see
// `RETINA_LABEL_TILE_SIZE` in index.html; the imagery itself is
// deliberately left native, for exactly the reason that multiplier is
// expensive). One aerial screenful is therefore several times the tile
// count a vector-only screenful cost. Entries, not bytes: these are 8–20 KB
// JPEG/PNG tiles, so this is roughly 20 MB — enough to hold a morning's
// route area, small enough that a browser won't evict the whole origin
// (app shell included) over it.
const TILE_CACHE_MAX_ENTRIES = 1400;

// Hosts whose responses are map tiles — trimmed to `TILE_CACHE_MAX_ENTRIES`
// and kept out of the app-shell cache. `maps.wien.gv.at` serves both the
// aerial imagery and its label overlay (see `AERIAL_*` in index.html);
// without it listed here, every aerial tile a driver panned over would land
// in CACHE_NAME and grow it without limit — which is exactly the failure
// the two-cache split above exists to prevent.
const TILE_HOSTS = ['tiles.openfreemap.org', 'maps.wien.gv.at'];

// The app shell, precached so a first-ever offline launch works rather than
// only a second one. Each is added individually: `cache.addAll` is atomic,
// so one 404 would throw away the whole precache.
const PRECACHE_URLS = ['/', '/icon.png'];

self.addEventListener('install', (event) => {
  // A failed precache (server restarting mid-install, no connection at
  // first load) must not reject the install event, or the worker never
  // activates at all and the app loses offline support entirely over one
  // badly-timed request.
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(PRECACHE_URLS.map((url) => cache.add(url).catch(() => {})))
    ).catch(() => {})
  );
  self.skipWaiting();
});

const KNOWN_CACHES = [CACHE_NAME, TILE_CACHE];

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => !KNOWN_CACHES.includes(k)).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Cache API insertion order is oldest-first, so dropping from the front is
// a serviceable approximation of least-recently-added. Deliberately
// approximate: precise LRU would mean tracking access times in IndexedDB
// for something whose only job is to stop unbounded growth.
async function trimCache(cacheName, maxEntries) {
  const cache = await caches.open(cacheName);
  const keys = await cache.keys();
  if (keys.length <= maxEntries) return;
  await Promise.all(keys.slice(0, keys.length - maxEntries).map((k) => cache.delete(k)));
}

// Shared by every stale-while-revalidate fetch below: serve the cached
// response immediately if there is one (while a background fetch checks for
// something newer, via `event.waitUntil` — a service worker is free to be
// killed the instant its fetch handler resolves, so a refresh nobody is
// waiting on would otherwise get cut off before it can write the cache);
// fall back to waiting on the network if there's nothing cached yet.
// `onPut` runs after a successful network response is cached (used by the
// tile handler to also trim the cache) — everything else about the policy
// is identical between the app shell and third-party assets, so it isn't
// duplicated between the two call sites below.
function staleWhileRevalidate(event, cache, request, { onPut } = {}) {
  const network = fetch(request).then(async (res) => {
    // Only successful responses are worth keeping — caching a 500 from a
    // briefly-broken server would pin that error page as the offline
    // fallback until the cache is cleared by hand.
    if (res.ok) {
      await cache.put(request, res.clone()).catch(() => {});
      if (onPut) await onPut();
    }
    return res;
  });
  return cache.match(request).then((cached) => {
    if (cached) {
      event.waitUntil(network.catch(() => {}));
      return cached;
    }
    return network;
  });
}

// How many times a tile is fetched before the map is told it failed, and
// how long to wait between attempts.
//
// This is the single biggest reason the Luftbild looked like it "doesn't
// load everywhere". MapLibre does not retry a tile that errored: the
// request fails once, that square stays empty, and it stays empty until
// the driver pans far enough away for the tile to be unloaded and then
// comes back. On a moving van — handovers between cells, a tunnel, a dead
// spot in a courtyard — a handful of tiles per screenful fail that way, and
// what the driver sees is permanent holes in the imagery over exactly the
// area they are standing in. Panning back and forth to fill them in is what
// "sometimes it works the second time" looks like on the map.
//
// Retried here rather than in the app because this is the only layer that
// sees the individual tile request. Two extra attempts with a short backoff
// covers a cell handover (typically under a second) without turning a
// genuinely offline map into a long stall: three quick failures still
// resolve in well under a second and a half, and the map falls through to
// the street map underneath (see the comment on `mountAerialLayers` in
// index.html) rather than showing nothing.
const TILE_FETCH_ATTEMPTS = 3;
const TILE_RETRY_BASE_MS = 250;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// A 5xx counts as a failure worth retrying, the same as a dropped
// connection — Vienna's WMTS answers 502/503 under load, and that is
// transient by definition. A 404 is not: those are the real edges of the
// imagery's coverage (outside the city, above its top zoom), they will
// never become a tile, and retrying them would spend three requests per
// square on every pan past the city limits.
async function fetchTileWithRetry(request) {
  let lastError = null;
  let lastResponse = null;
  for (let attempt = 0; attempt < TILE_FETCH_ATTEMPTS; attempt++) {
    if (attempt > 0) await sleep(TILE_RETRY_BASE_MS * attempt);
    try {
      const res = await fetch(request);
      if (res.ok || res.status < 500) return res;
      lastResponse = res;
      lastError = null;
    } catch (err) {
      lastError = err;
      lastResponse = null;
    }
  }
  // Out of attempts. A server that kept answering 5xx gets its own last
  // response passed through, so the failure the map reports is the one that
  // actually happened rather than a synthetic stand-in. A connection that
  // never completed rethrows, which is indistinguishable from a plain
  // network failure — exactly how MapLibre has always seen it.
  if (lastResponse) return lastResponse;
  throw lastError || new Error('tile fetch failed');
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Never intercept the API — routing/geocoding must always hit the
  // network live, never serve a cached (possibly stale/wrong) response.
  if (url.origin === self.location.origin && url.pathname.startsWith('/api/')) return;

  if (url.origin === self.location.origin) {
    // The app shell: network raced against a short timeout, not plain
    // stale-while-revalidate. This app's `index.html`/`sw.js` are read
    // straight off disk on every request and hand-edited without a rebuild
    // (see the module doc comment in src/main.rs) — "a deploy is picked up
    // on the very next load" was a real, relied-on guarantee, not an
    // incidental side effect of network-first. Plain stale-while-revalidate
    // (tried here once, then reverted) silently gave that up: the existing
    // `controllerchange` reload in index.html only fires when *sw.js's own
    // bytes* change, so an index.html-only deploy would leave an
    // already-open tab — and this is a PWA the app's own comments describe
    // staying open "for days" — running stale JS against a new backend
    // indefinitely, with nothing forcing a reload.
    //
    // Racing instead of blocking on the full round-trip keeps the fast-
    // reopen win for a bad connection while keeping the freshness guarantee
    // for the common case: this app talks to its own self-hosted backend,
    // so the network normally answers well inside the timeout, and only
    // actually falls back to cache when it doesn't.
    const SHELL_NETWORK_TIMEOUT_MS = 400;
    event.respondWith((async () => {
      const cache = await caches.open(CACHE_NAME);
      const network = fetch(request).then((res) => {
        if (res.ok) cache.put(request, res.clone()).catch(() => {});
        return res;
      });
      const timedOut = new Promise((resolve) => setTimeout(() => resolve(undefined), SHELL_NETWORK_TIMEOUT_MS));
      // Raced against a version of `network` that can never *reject* — a
      // bare `Promise.race([network, timedOut])` looked equivalent but
      // isn't: `race` settles the instant ANY entry settles, rejection
      // included, so a network failure that arrives before the timeout
      // (not just a slow one) would reject the whole race immediately and
      // crash this handler with net::ERR_FAILED instead of falling through
      // to the cache fallback below, which is the entire point of this
      // handler. `network` itself (still able to reject) is what the later
      // fallbacks below correctly `.catch()` off of.
      const raced = await Promise.race([network.catch(() => undefined), timedOut]);
      if (raced) return raced;

      // The network didn't answer in time — serve whatever's cached right
      // now, but let the network attempt keep running in the background so
      // the cache (and this tab, via `controllerchange` if it was a real
      // update) still catches up as soon as it does answer.
      event.waitUntil(network.catch(() => {}));
      const cached = await cache.match(request);
      if (cached) return cached;
      // Nothing cached (first-ever load, or a cleared cache) and the
      // network already missed its window: wait it out for real rather
      // than serving nothing.
      return network.catch(async () => {
        // A navigation falls back to the cached shell itself: the app is a
        // single page, so "/" is the right answer for any in-app URL.
        const hit = request.mode === 'navigate' ? await caches.match('/') : undefined;
        return hit || new Response('Offline', { status: 503, statusText: 'Offline' });
      });
    })());
    return;
  }

  // Third-party assets (MapLibre GL JS/CSS,
  // OpenFreeMap style JSON/glyphs/sprites): stale-while-revalidate.
  // Tiles are handled separately just below — they get a stricter policy. Serving the cached copy immediately is what lets an
  // already-panned-into-view map area keep rendering with zero connection,
  // and it's why this is cache-first rather than network-first. Unlike the
  // app shell above, there's no "deploy this app just made" freshness
  // guarantee to protect here — a pinned MapLibre build or a
  // slightly-stale map tile is a cosmetic staleness, not this app's own
  // broken code silently running forever, so plain stale-while-revalidate
  // (not raced against a timeout) is the right trade.
  const isTile = TILE_HOSTS.includes(url.hostname);
  if (isTile) {
    // Map tiles are cache-first with NO background revalidation, which is
    // the one place this worker deviates from stale-while-revalidate above.
    //
    // A tile is immutable in every way that matters: aerial imagery is
    // reflown once a year, vector tiles change on their own slow schedule,
    // and the URL encodes the exact square being asked for. Revalidating
    // one therefore spends a request and a round-trip on a mobile
    // connection to be told what we already had — and it does that for
    // *every tile on screen*, so panning back over ground already visited,
    // or flipping between Karte and Luftbild, silently re-hit the network
    // for a screenful of tiles that were sitting in the cache the whole
    // time. On a van's connection that is the difference between the
    // imagery snapping in and watching it fill in square by square.
    event.respondWith(
      caches.open(TILE_CACHE).then(async (cache) => {
        const cached = await cache.match(request);
        if (cached) return cached;
        const res = await fetchTileWithRetry(request);
        if (res.ok) {
          // `waitUntil`, so the response goes to the map immediately rather
          // than waiting on the cache write.
          event.waitUntil(
            cache.put(request, res.clone())
              .then(() => trimCache(TILE_CACHE, TILE_CACHE_MAX_ENTRIES))
              .catch(() => {})
          );
        }
        return res;
      })
    );
    return;
  }
  event.respondWith(
    caches.open(CACHE_NAME).then((cache) => staleWhileRevalidate(event, cache, request))
  );
});
