// The service worker: the app shell works offline-first (it opens at once and says when Sofa is
// not reachable); Sofa's data and media never pass through it - they are live, per device, and
// on another origin anyway.

export {};
declare const self: ServiceWorkerGlobalScope;
declare const __SOFA_BUILD__: string;
declare const __SOFA_SHELL__: string[];

const CACHE = `sofa-shell-${__SOFA_BUILD__}`;

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(__SOFA_SHELL__)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k.startsWith('sofa-shell-') && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin) return;
  // the page itself: network first (a new version shows at once), the cached shell offline
  if (e.request.mode === 'navigate') {
    e.respondWith(fetch(e.request).catch(async () => (await caches.match('./', { cacheName: CACHE })) ?? Response.error()));
    return;
  }
  e.respondWith(caches.match(e.request, { cacheName: CACHE }).then((hit) => hit ?? fetch(e.request)));
});
