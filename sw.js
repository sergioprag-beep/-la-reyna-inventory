const CACHE='lrx-2026-11-12-local-backup-quota';
const VERSION='2026-11-12-local-backup-quota';
const ASSETS=[
  './','./index.html','./styles.css?v=2026-11-12-local-backup-quota',
  `./app.js?v=${VERSION}`,`./purchase-engine.js?v=${VERSION}`,`./catalog-controls.js?v=${VERSION}`,`./cloudflare-sync.js?v=${VERSION}`,`./ui-translation-extra.js?v=${VERSION}`,
  './manifest.webmanifest','./hero-food.jpg','./hero-bar.jpg','./LRX-LOGO-PLANTILLAS.png',
  './recipe-price-mobile.js?v=2026-11-05-v546','./LRX-LOGO-LOCKUP-BRANDSAFE.svg','./LRX-LOGO-IMPRESION.jpeg','./LRX-LOGO-IMPRESION-TRANSPARENTE.png',
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
  // Auth and live state must always reach the server; cached GETs can restore
  // stale session responses or outdated shared data in an installed PWA.
  if(url.pathname.startsWith('/api/'))return;
  const critical=['/index.html','/app.js','/catalog-controls.js','/purchase-engine.js','/master.json','/styles.css','/sw.js'].some(path=>url.pathname.endsWith(path));
  if(critical||event.request.mode==='navigate'){
    event.respondWith((async()=>{
      try{
        const response=await fetch(event.request,{cache:'no-store'});
        if(response.ok){const cache=await caches.open(CACHE);await cache.put(event.request,response.clone())}
        return response;
      }