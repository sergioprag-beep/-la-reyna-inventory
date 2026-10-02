const CACHE='lrx-v221';
const VERSION='2026-10-01-v221';
const ASSETS=[
  './','./index.html','./styles.css',
  `./app.js?v=${VERSION}`,`./purchase-engine.js?v=${VERSION}`,
  './manifest.webmanifest','./hero-food.jpg','./LOGO XPRESS-4(5).jpg',
  `./master.json?v=${VERSION}`
];

self.addEventListener('install',event=>{
  event.waitUntil((async()=>{
    const cache=await caches.open(CACHE);
    await Promise.allSettled(ASSETS.map(async asset=>{
      try{const response=await fetch(asset,{cache:'reload'});if(response.ok)await cache.put(asset,response)}catch(error){console.warn('LRX precache skipped',asset,error)}
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate',event=>{
  event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('lrx-')&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()));
});

self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET')return;
  const url=new URL(event.request.url);
  if(url.origin!==self.location.origin)return;
  const critical=['/index.html','/app.js','/purchase-engine.js','/master.json','/styles.css','/sw.js'].some(path=>url.pathname.endsWith(path));
  if(critical||event.request.mode==='navigate'){
    event.respondWith((async()=>{
      try{
        const response=await fetch(event.request,{cache:'no-store'});
        if(response.ok){const cache=await caches.open(CACHE);await cache.put(event.request,response.clone())}
        return response;
      }catch(error){
        const cached=await caches.match(event.request)||await caches.match('./index.html');
        if(cached)return cached;
        return new Response('LRX no está disponible sin conexión.',{status:503,headers:{'Content-Type':'text/plain;charset=utf-8'}});
      }
    })());
    return;
  }
  event.respondWith((async()=>{
    const cached=await caches.match(event.request);
    if(cached)return cached;
    try{const response=await fetch(event.request);if(response.ok){const cache=await caches.open(CACHE);cache.put(event.request,response.clone()).catch(()=>{})}return response}
    catch(error){return await caches.match('./index.html')||new Response('',{status:503})}
  })());
});
