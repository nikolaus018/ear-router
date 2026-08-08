// Service worker for EAR Routing — embedded into the server binary the same
// way index.html is (see `include_str!("../sw.js")` in src/main.rs) and
// served at /sw.js, so this stays a two-file app with no separate static
// asset pipeline.
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
const CACHE_NAME = 'ear-routing-v1';

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.add('/')));
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))))
  );
  self.clients.claim();
});

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
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          return res;
        })
        .catch(() => caches.match(request))
    );
    return;
  }

  // Third-party assets (Tailwind CDN runtime, MapLibre GL JS/CSS,
  // OpenFreeMap style JSON/glyphs/sprites/vector tiles): cache-first. These
  // are either versioned/immutable (unpkg URLs pin a major version) or fine
  // to serve slightly stale (a map tile a few days old is still correct),
  // and cache-first is what actually lets an already-panned-into-view map
  // area keep rendering with zero network connection.
  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached;
      return fetch(request).then((res) => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
        }
        return res;
      });
    })
  );
});
