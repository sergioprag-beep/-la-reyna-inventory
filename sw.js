const CACHE='lrx-v107.3';
self.addEventListener('install',event=>{self.skipWaiting()});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET') return;
  event.respondWith(fetch(event.request,{cache:'no-store'}).then(r=>{const copy=r.clone(); if(new URL(event.request.url).origin===self.location.origin) caches.open(CACHE).then(c=>c.put(event.request,copy)).catch(()=>{}); return r}).catch(()=>caches.match(event.request)));
});
