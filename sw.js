const CACHE='lrx-v167';
const ASSETS=['./','./index.html','./styles.css','./app.js?v=2026-09-28-v167','./purchase-engine.js?v=2026-09-28-v167','./manifest.webmanifest','./hero-food.jpg','./LOGO XPRESS-4(5).jpg','./master.json?v=2026-09-28-v167'];
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(ASSETS)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',event=>{
 if(event.request.method!=='GET')return;
 const u=new URL(event.request.url);
 const critical=u.pathname.endsWith('/index.html')||u.pathname.endsWith('/app.js')||u.pathname.endsWith('/purchase-engine.js')||u.pathname.endsWith('/master.json')||u.pathname.endsWith('/styles.css')||u.pathname.endsWith('/sw.js');
 if(critical||event.request.mode==='navigate'){
  event.respondWith(fetch(event.request,{cache:'no-store'}).then(response=>{if(response&&response.ok)caches.open(CACHE).then(c=>c.put(event.request,response.clone())).catch(()=>{});return response}).catch(()=>caches.match(event.request).then(r=>r||caches.match('./index.html'))));
  return;
 }
 event.respondWith(caches.match(event.request).then(cached=>cached||fetch(event.request).then(response=>{if(response&&response.ok){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(event.request,copy)).catch(()=>{})}return response}).catch(()=>caches.match('./index.html'))));
});
