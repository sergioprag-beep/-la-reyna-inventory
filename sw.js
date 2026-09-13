const CACHE='lrx-pro-v66-inventory-save-fix';
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET') return;
  e.respondWith(fetch(e.request).then(r=>{
    const c=r.clone(); caches.open(CACHE).then(x=>x.put(e.request,c)); return r;
  }).catch(()=>caches.match(e.request)));
});
