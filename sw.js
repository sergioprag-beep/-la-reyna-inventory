const CACHE_NAME = 'lrx-management-v96';
const CORE = ['./index.html','./manifest.webmanifest'];
self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(CORE)).catch(()=>{}));
});
self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch', event => {
  if(event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if(url.origin !== location.origin) return;
  // Never serve stale HTML to navigation requests.
  if(event.request.mode === 'navigate' || url.pathname.endsWith('/index.html')){
    event.respondWith(fetch(event.request, {cache:'no-store'}).then(response => {
      const copy=response.clone();
      caches.open(CACHE_NAME).then(c=>c.put('./index.html',copy)).catch(()=>{});
      return response;
    }).catch(()=>caches.match('./index.html')));
    return;
  }
  event.respondWith(caches.match(event.request).then(hit=>hit || fetch(event.request)));
});
