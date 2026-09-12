const CACHE='lrx-pro-v58-2-recipe-cost-fix';
self.addEventListener('install',e=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.add('./')).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',e=>{
  e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET')return;
  e.respondWith(fetch(e.request).then(r=>{
    const copy=r.clone();caches.open(CACHE).then(c=>c.put(e.request,copy));return r;
  }).catch(()=>caches.match(e.request).then(r=>r||caches.match('./'))));
});
