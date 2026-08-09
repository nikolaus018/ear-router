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
// needs to render (Tailwind's CDN runtime, MapLibre GL JS/CSS, the
// OpenFreeMap style/glyphs/sprites/vector tiles already panned into view)
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
const TILE_CACHE_MAX_ENTRIES = 600;

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

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);

  // Never intercept the API — routing/geocoding must always hit the
  // network live, never serve a cached (possibly stale/wrong) response.
  if (url.origin === self.location.origin && url.pathname.startsWith('/api/')) return;

  if (url.origin === self.location.origin) {
    // The app shell: network-first so a redeploy is picked up on the very
    // next load, falling back to the last cached copy only when the
    // network request itself fails (offline, DNS down, etc).
    event.respondWith(
      fetch(request)
        .then((res) => {
          // Only successful responses are worth keeping — caching a 500
          // from a briefly-broken server would pin that error page as the
          // offline fallback until the cache is cleared by hand.
          if (res.ok) {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy)).catch(() => {});
          }
          return res;
        })
        .catch(async () => {
          // `caches.match` resolves to undefined on a miss, and
          // respondWith(undefined) is a hard error ("Failed to convert
          // value to 'Response'") that shows as a browser network-error
          // page — worse than the offline notice below. A navigation also
          // falls back to the cached shell itself: the app is a single
          // page, so "/" is the right answer for any in-app URL.
          const hit = (await caches.match(request)) ||
            (request.mode === 'navigate' ? await caches.match('/') : undefined);
          return hit || new Response('Offline', { status: 503, statusText: 'Offline' });
        })
    );
    return;
  }

  // Third-party assets (Tailwind CDN runtime, MapLibre GL JS/CSS,
  // OpenFreeMap style JSON/glyphs/sprites/vector tiles): stale-while-
  // revalidate. Serving the cached copy immediately is what lets an
  // already-panned-into-view map area keep rendering with zero connection,
  // and it's why this is cache-first rather than network-first.
  //
  // The revalidation in the background is the part that was missing.
  // Plain cache-first never re-fetches anything it has ever stored, so a
  // fixed MapLibre patch release, an updated OpenFreeMap style, or a tile
  // covering a street that has since been re-mapped would be pinned at the
  // first version this device ever saw — for as long as the cache lives,
  // which is to say indefinitely. Now the driver still gets the instant
  // cached response, and the next load gets the fresh one.
  const isTile = url.hostname === 'tiles.openfreemap.org';
  const cacheName = isTile ? TILE_CACHE : CACHE_NAME;

  event.respondWith((async () => {
    const cache = await caches.open(cacheName);
    const cached = await cache.match(request);

    const network = fetch(request).then(async (res) => {
      if (res.ok) {
        await cache.put(request, res.clone()).catch(() => {});
        if (isTile) await trimCache(TILE_CACHE, TILE_CACHE_MAX_ENTRIES).catch(() => {});
      }
      return res;
    });

    if (cached) {
      // `waitUntil` is what makes the "revalidate" half actually happen: a
      // service worker is free to be killed the moment its fetch handler
      // resolves, so a background refresh nobody is waiting on gets
      // terminated before it can write to the cache. Errors are swallowed
      // — a failed refresh just means the cached copy stays another round.
      event.waitUntil(network.catch(() => {}));
      return cached;
    }
    // Nothing cached and the network is gone: let the caller see the
    // failure. MapLibre treats a failed tile as "not loaded yet" and leaves
    // that square blank, which is the right outcome — far better than a
    // synthesized error response it would try to parse as vector data.
    return network;
  })());
});
