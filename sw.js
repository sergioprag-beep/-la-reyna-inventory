const CACHE = "lrx-v123-rebuild";
const CORE = ["./", "./index.html", "./app.js", "./styles.css", "./master.json", "./manifest.webmanifest", "./LOGO XPRESS-4(5).jpg"];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(CORE)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  const critical = /\/(app\.js|styles\.css|master\.json|index\.html|manifest\.webmanifest)$/.test(url.pathname);
  const fresh = fetch(event.request).then(response => {
    const copy = response.clone();
    caches.open(CACHE).then(cache => cache.put(event.request, copy)).catch(() => {});
    return response;
  });
  event.respondWith((critical ? fresh.catch(() => caches.match(event.request)) : caches.match(event.request).then(cached => cached || fresh)).catch(() => caches.match("./index.html")));
});
