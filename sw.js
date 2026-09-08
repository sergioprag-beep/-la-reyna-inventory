/* La Reyna Xpress PWA — V57.10 cache reset */
const CACHE='lrx-v57.10-clean';
const CORE=['./','./index.html','./offline.html'];
const OLD_PREFIXES=['lrx-v57.7-6','lrx-v57.8','lrx-v57.9','lrx-v57.9.1','lrx-v57.9.2','lrx-v57.10'];
self.addEventListener('install',event=>{
  event.waitUntil(
    caches.open(CACHE)
      .then(cache=>cache.addAll(CORE))
      .then(()=>self.skipWaiting())
  );
});
self.addEventListener('activate',event=>{
  event.waitUntil(
    caches.keys().then(keys=>Promise.all(
      keys.filter(k=>k!==CACHE || OLD_PREFIXES.some(prefix=>k.startsWith(prefix)))
        .map(k=>caches.delete(k))
    )).then(()=>self.clients.claim())
  );
});
self.addEventListener('message',event=>{
  if(event.data && event.data.type==='SKIP_WAITING') self.skipWaiting();
  if(event.data && event.data.type==='CLEAR_LRX_CACHES'){
    event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))));
  }
});
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET') return;
  event.respondWith(
    fetch(event.request, {cache:'no-store'})
      .then(response=>{
        if(response && response.ok){
          const copy=response.clone();
          caches.open(CACHE).then(c=>c.put(event.request,copy)).catch(()=>{});
        }
        return response;
      })
      .catch(()=>caches.match(event.request).then(r=>r||caches.match('./offline.html')))
  );
});
