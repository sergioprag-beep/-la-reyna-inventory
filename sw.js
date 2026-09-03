const CACHE='la-reyna-inventory-v3';
const CORE=['./','./index.html','./manifest.webmanifest','./offline.html',
'./icons/icon-192.png','./icons/icon-512.png','./icons/icon-180.png'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{if(e.request.method!=='GET')return;e.respondWith(caches.match(e.request).then(c=>c||fetch(e.request).catch(()=>caches.match('./offline.html'))));});
