/* Shared LRX state through Cloudflare Pages Functions. */
(()=>{
'use strict';

const DATA_KEY='lrx_state_v140',BACKUP_KEY=DATA_KEY+'.backup';
let revision=0,lastSynced='',pollTimer=null,publishTimer=null,pollDelay=60000,checkingCloud=false;
let publishRetryDelay=1500,busy=false,queuedSnapshot=null,conflict=false,ready=false,connectPromise=null;

const statusEl=()=>document.getElementById('syncStatus');
function status(label,kind='local'){
  const el=statusEl();if(!el)return;
  el.querySelector('b').textContent=label;el.dataset.state=kind;
  el.title=kind==='cloud'?'Datos sincronizados en Cloudflare':kind==='error'?'Hay cambios pendientes o dos copias por revisar':'Sincroniza los registros en Cloudflare';
}
function localState(){try{return JSON.parse(localStorage.getItem(DATA_KEY)||'{}')}catch{return{}}}
function stableJSON(value,path=''){
  if(Array.isArray(value))return '['+value.map((item,index)=>stableJSON(item,`${path}[${index}]`)).join(',')+']';
  if(value&&typeof value==='object')return '{'+Object.keys(value).sort().filter(key=>value[key]!==undefined&&key!=='legacyRecoveredAt'&&!(path==='_recipeLegacyRecovered'&&key==='at')).map(key=>JSON.stringify(key)+':'+stableJSON(value[key],path?path+'.'+key:key)).join(',')+'}';
  return JSON.stringify(value);
}
function hasRecords(value){return Object.entries(value||{}).some(([key,items])=>key!=='users'&&key!=='audit'&&Array.isArray(items)&&items.length>0)}
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));

async function saveLocal(value){
  const persistent=window.LRXPersistentState;
  if(persistent?.ready)await persistent.ready;
  if(persistent?.error?.())throw Error('No se pudo preparar el almacenamiento local. La copia de Cloudflare sigue intacta; recarga la app actualizada antes de volver a sincronizar.');
  try{localStorage.setItem(DATA_KEY,JSON.stringify(value));if(persistent?.flush)await persistent.flush()}
  catch{throw Error('El navegador no pudo guardar la copia local. La copia de Cloudflare sigue intacta; no borres los datos del sitio.')}
  return true;
}
function preserveLocal(value){
  try{localStorage.setItem(BACKUP_KEY,JSON.stringify({savedAt:new Date().toISOString(),state:value}))}catch(error){console.warn('LRX local backup unavailable',error)}
  if(typeof URL?.createObjectURL==='function')try{
    const link=document.createElement('a'),url=URL.createObjectURL(new Blob([JSON.stringify({savedAt:new Date().toISOString(),state:value},null,2)],{type:'application/json'}));
    link.href=url;link.download=`LRX-respaldo-${new Date().toISOString().slice(0,10)}.json`;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);
  }catch(error){console.warn('LRX backup download unavailable',error)}
}
async function api(path,options={}){
  const method=String(options.method||'GET').toUpperCase(),safeRead=method==='GET';
  for(let attempt=0;;attempt++){
    try{
      const response=await fetch(path,{cache:'no-store',credentials:'same-origin',...options,headers:{...(options.body?{'Content-Type':'application/json'}:{}),...(options.headers||{})}});
      const body=await response.json();
      if(!response.ok){const error=Error(body.error||`Error HTTP ${response.status}`);error.status=response.status;error.revision=body.revision;throw error}
      return body;
    }catch(error){
      const retryable=!error.status||error.status===408||error.status===425||error.status===429||error.status>=500;
      if(!safeRead||!retryable||attempt>=3){
        if(safeRead&&!error.status){
          const offline=Error('No se pudo cargar la copia compartida después de varios intentos. No combines las copias; cierra este aviso y vuelve a intentarlo con conexión estable. Tus datos locales no se modificaron.');
          offline.cause=error;throw offline;
        }
        throw error;
      }
      // Safari may drop one large D1 fragment during a transient radio/network
      // interruption. Reads are idempotent, so retry that request before
      // surfacing a failure; writes intentionally never pass through this path.
      await wait(Math.min(500*2**attempt,4000)+Math.floor(Math.random()*250));
    }
  }
}
async function getCloud(){
  // Fetch the shared state in bounded pieces. A single response forces a Pages
  // Worker/D1 query to materialize the whole restaurant database and can hit
  // Cloudflare's 1102 resource limit on larger backups.
  for(let attempt=0;attempt<3;attempt++){
    const manifest=await api('./api/state?manifest=1');
    const count=Number(manifest.chunkCount)||0;
    if(!manifest.snapshotId)return{payload:null,revision:Number(manifest.revision)||0,updatedAt:manifest.updatedAt||null};
    if(!Number.isSafeInteger(count)||count<1||count>256)throw Error('La copia compartida informó fragmentos inválidos. No se modificó la copia local.');
    const chunks=new Array(count);let changed=false;
    for(let start=0;start<count;start+=2){
      const end=Math.min(start+2,count);
      try{
        const batch=await Promise.all(Array.from({length:end-start},(_,offset)=>{
          const index=start+offset;
          return api(`./api/state?chunk=${index}&snapshot=${encodeURIComponent(manifest.snapshotId)}`);
        }));
        for(const item of batch){
          if(item.snapshotId!==manifest.snapshotId||!Number.isSafeInteger(item.index)||typeof item.data!=='string')throw Error('La copia compartida devolvió un fragmento inválido. No se modificó la copia local.');
          chunks[item.index]=item.data;
        }
      }catch(error){if(error.status===409){changed=true;break}throw error}
    }
    if(changed)continue;
    for(let index=0;index<chunks.length;index++)if(typeof chunks[index]!=='string')throw Error('La copia compartida está incompleta. No se modificó la copia local.');
    let payload;
    try{payload=JSON.parse(chunks.join(''))}catch{throw Error('No se pudo reconstruir la copia compartida. No se modificó la copia local.')}
    return{payload,revision:Number(manifest.revision)||0,updatedAt:manifest.updatedAt||null};
  }
  throw Error('La copia compartida cambió mientras se descargaba. Vuelve a sincronizar en unos segundos.');
}
async function publishOnce(payload){
  return api('./api/state',{method:'PUT',body:JSON.stringify(payload),headers:{'X-LRX-Expected-Revision':String(revision)}});
}
async function publish(payload){
  const target=stableJSON(payload);
  for(let attempt=0;attempt<5;attempt++){
    try{
      const result=await publishOnce(payload);revision=result.revision;lastSynced=target;return result;
    }catch(error){
      if(error.status===409)throw error;
      const temporary=!error.status||error.status>=500;
      if(!temporary)throw error;
      if(attempt<4)await wait(Math.min(1500*2**attempt,12000));
      // A 503 or lost response can happen after the server committed the write.
      // Read back before retrying so we never mistake a successful save for a failure.
      try{
        const latest=await getCloud();
        if(stableJSON(latest.payload||{})===target){revision=Number(latest.revision)||revision;lastSynced=target;return latest}
        if(Number(latest.revision)!==revision){const stale=Error('La copia compartida cambió desde otro dispositivo. Revisa y combina las dos copias.');stale.status=409;stale.revision=Number(latest.revision)||0;throw stale}
      }catch(readError){if(readError.status===409)throw readError;console.warn('LRX could not confirm a pending cloud write',readError)}
      if(attempt===4)throw error;
    }
  }
  throw Error('No se pudo confirmar el guardado en la nube. Tus cambios siguen guardados en este dispositivo y se volverán a intentar.');
}
function mergeRecord(local,cloud){
  const isProduction=record=>String(record?.id||'').startsWith('PRD-')||('startedAt' in (record||{})&&'finishedAt' in (record||{}));
  const localCompleted=String(local?.status||'').toLowerCase()==='completed';
  const cloudCompleted=String(cloud?.status||'').toLowerCase()==='completed';
  // Production is a one-way workflow: a completed record must not revert to in-progress.
  if(isProduction(local)&&isProduction(cloud)&&localCompleted!==cloudCompleted)return localCompleted?local:cloud;
  const timestamp=record=>{
    for(const key of ['updatedAt','modifiedAt','finishedAt','completedAt','startedAt','createdAt']){
      const value=Date.parse(record?.[key]||'');
      if(Number.isFinite(value))return value;
    }
    return NaN;
  };
  const localTime=timestamp(local),cloudTime=timestamp(cloud);
  if(Number.isFinite(localTime)&&Number.isFinite(cloudTime)&&localTime!==cloudTime)return localTime>cloudTime?local:cloud;
  return mergeValues(local,cloud);
}
function mergeValues(local,cloud){
  if(Array.isArray(local)||Array.isArray(cloud)){
    const left=Array.isArray(local)?local:[],right=Array.isArray(cloud)?cloud:[],out=[],positions=new Map();
    const keyOf=value=>value&&typeof value==='object'&&!Array.isArray(value)?String(value.id??value.uuid??value.key??value.code??value.name??JSON.stringify(value)):JSON.stringify(value);
    for(const item of [...right,...left]){const key=keyOf(item);if(!positions.has(key)){positions.set(key,out.length);out.push(item)}else{const at=positions.get(key),existing=out[at];if(item&&existing&&typeof item==='object'&&typeof existing==='object'&&!Array.isArray(item)&&!Array.isArray(existing))out[at]=mergeRecord(item,existing)}}
    return out;
  }
  if(local&&cloud&&typeof local==='object'&&typeof cloud==='object'){
    const lt=Date.parse(local.updatedAt||local.modifiedAt||''),ct=Date.parse(cloud.updatedAt||cloud.modifiedAt||''),preferred=Number.isFinite(lt)&&lt>ct?local:cloud,other=preferred===local?cloud:local,out={...other,...preferred};
    for(const key of new Set([...Object.keys(local),...Object.keys(cloud)]))if(local[key]&&cloud[key]&&typeof local[key]==='object'&&typeof cloud[key]==='object')out[key]=mergeValues(local[key],cloud[key]);
    return out;
  }
  return local===undefined?cloud:cloud===undefined?local:cloud;
}
function purchaseTombstones(state){
  const found=new Map();
  for(const item of Array.isArray(state?.syncTombstones)?state.syncTombstones:[]){
    if(item?.collection==='purchases'&&item?.scope==='group'&&item?.targetId){
      const targetId=String(item.targetId);
      found.set(targetId,{id:String(item.id||`TOMB-purchases-group-${targetId}`),collection:'purchases',scope:'group',targetId,createdAt:item.createdAt||''});
    }
  }
  for(const item of Array.isArray(state?.audit)?state.audit:[]){
    if(item?.event!=='PURCHASE_DELETE')continue;
    const detail=String(item.detail||'');
    const match=detail.match(/Compra eliminada:\s*(.+)$/i);
    if(!match)continue;
    const targetId=match[1].trim();
    if(targetId)found.set(targetId,{id:`TOMB-purchases-group-${targetId}`,collection:'purchases',scope:'group',targetId,createdAt:item.date||''});
  }
  return [...found.values()];
}
function applyPurchaseTombstones(state){
  const tombstones=purchaseTombstones(state);
  if(!tombstones.length)return state;
  state.syncTombstones=tombstones;
  const deleted=new Set(tombstones.map(item=>item.targetId));
  const belongsToDeletedPurchase=item=>deleted.has(String(item?.purchaseId||item?.id||''));
  for(const key of ['purchases','purchaseHeaders','purchasePayments','purchaseReceipts']){
    if(Array.isArray(state[key]))state[key]=state[key].filter(item=>!belongsToDeletedPurchase(item));
  }
  if(Array.isArray(state.documents))state.documents=state.documents.filter(item=>!deleted.has(String(item?.contextRecordId||item?.purchaseId||'')));
  if(Array.isArray(state.movements))state.movements=state.movements.filter(item=>!belongsToDeletedPurchase(item)||String(item?.type||'').toUpperCase()==='REVERSA COMPRA');
  return state;
}
async function publishMerged(local,cloud){
  let base=cloud,merged=local;
  for(let attempt=0;attempt<3;attempt++){
    merged=applyPurchaseTombstones(mergeValues(merged,base?.payload||{}));revision=Number(base?.revision)||0;await saveLocal(merged);
    try{await publish(merged);return merged}
    catch(error){if(error.status!==409||attempt===2)throw error;base=await getCloud();if(!base)throw error}
  }
  throw Error('La copia compartida siguió cambiando. Espera unos segundos y vuelve a sincronizar.');
}
function chooseCopy(){
  return new Promise(resolve=>{
    const layer=document.createElement('div');layer.style.cssText='position:fixed;inset:0;z-index:31000;background:#10182899;display:grid;place-items:center;padding:18px';
    layer.innerHTML='<div style="background:#fff;color:#182235;width:min(480px,100%);padding:22px;border-radius:16px;box-shadow:0 18px 70px #0005"><h2 style="margin:0 0 8px">Hay dos copias de los datos</h2><p style="line-height:1.5">Se guardará un respaldo antes de combinar. La combinación conserva los cambios de ambos equipos y respeta las compras eliminadas registradas en la auditoría.</p><div style="display:grid;gap:9px;margin-top:18px"><button data-choice="merge" style="padding:12px;background:#c92d70;color:white;border:0;border-radius:9px;font-weight:700">Combinar ambas copias</button><button data-choice="cloud" style="padding:11px;background:white;border:1px solid #cbd5e1;border-radius:9px">Usar la copia de Cloudflare</button><button data-choice="local" style="padding:11px;background:white;border:1px solid #cbd5e1;border-radius:9px">Subir la copia de esta computadora</button><button data-choice="cancel" style="padding:9px;background:transparent;border:0">Cancelar</button></div></div>';
    layer.addEventListener('click',event=>{const choice=event.target.closest('[data-choice]')?.dataset.choice;if(!choice)return;layer.remove();resolve(choice==='cancel'?null:choice)});document.body.append(layer);
  });
}
function loginGate(){
  return new Promise(async resolve=>{
    const wall=document.createElement('div');wall.id='lrxLoginWall';wall.setAttribute('role','dialog');wall.setAttribute('aria-modal','true');wall.style.cssText='position:fixed;inset:0;z-index:999999;background:#f2f4f8;display:grid;place-items:center;padding:20px;font-family:system-ui,-apple-system,sans-serif;color:#172033';
    wall.innerHTML='<form style="width:min(440px,100%);background:white;border:1px solid #dbe2ec;border-radius:18px;padding:26px;box-shadow:0 18px 60px #18223520"><h1 style="margin:0 0 8px;font-size:26px">La Reyna Inventory</h1><p style="margin:0 0 20px;color:#667085">Ingresa tu contraseña para abrir la aplicación.</p><label style="display:block;font-weight:700;margin-bottom:7px" for="lrxAccessPassword">Contraseña</label><input id="lrxAccessPassword" type="password" autocomplete="current-password" required style="box-sizing:border-box;width:100%;padding:13px;border:1px solid #cbd5e1;border-radius:10px;font:inherit"><button type="submit" style="width:100%;margin-top:14px;padding:13px;border:0;border-radius:10px;background:#c92d70;color:white;font:inherit;font-weight:800;cursor:pointer">Entrar</button><p data-error style="min-height:1.5em;margin:12px 0 0;color:#b42318" role="status"></p></form>';
    document.body.append(wall);const app=document.getElementById('app'),form=wall.querySelector('form'),input=wall.querySelector('input'),error=wall.querySelector('[data-error]'),button=wall.querySelector('button');
    if(app){app.inert=true;app.setAttribute('aria-hidden','true')}
    const remove=()=>{if(app){app.inert=false;app.removeAttribute('aria-hidden')}wall.remove();resolve(true)};
    try{const response=await fetch('./api/auth?action=session',{cache:'no-store',credentials:'same-origin'}),body=await response.json();if(response.ok&&body.authenticated){remove();return}if(response.status===503)error.textContent='El acceso seguro aún no está activado en Cloudflare.'}catch{error.textContent='No se pudo conectar con el servicio de acceso.'}
    input.focus();form.addEventListener('submit',async event=>{event.preventDefault();button.disabled=true;button.textContent='Verificando…';error.textContent='';try{const response=await fetch('./api/auth?action=login',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:input.value})}),body=await response.json();if(!response.ok)throw Error(body.error||'No se pudo iniciar sesión.');remove()}catch(err){error.textContent=err.message||'No se pudo iniciar sesión.';input.select()}finally{button.disabled=false;button.textContent='Entrar'}});
  });
}
async function connect(){
  if(window.LRXAppReady)await window.LRXAppReady;if(window.LRXPersistentState?.ready)await window.LRXPersistentState.ready;
  const cloud=await getCloud(),local=localState(),localText=stableJSON(local);revision=Number(cloud.revision)||0;
  if(!cloud.payload){
    if(!hasRecords(local)){ready=true;status('Sin copia compartida','local');startPolling();return}
    preserveLocal(local);if(!confirm('Cloudflare todavía no tiene una copia de LRX. ¿Quieres publicar los datos de esta computadora? Se descargó un respaldo antes de continuar.')){ready=true;status('Solo en esta computadora','local');startPolling();return}
    await publish(local);ready=true;status('Sincronizado','cloud');startPolling();return;
  }
  const cloudText=stableJSON(cloud.payload);
  if(localText===cloudText){lastSynced=cloudText;status('Sincronizado','cloud');ready=true;startPolling();if(queuedSnapshot)schedulePublish(0);return}
  if(!hasRecords(local)){preserveLocal(local);await saveLocal(cloud.payload);lastSynced=cloudText;location.reload();return}
  conflict=true;status('Conflicto: toca para revisar','error');ready=true;startPolling();
}
function connectOnce(){if(!connectPromise)connectPromise=connect().finally(()=>{connectPromise=null});return connectPromise}
async function checkCloud(){
  if(checkingCloud||busy)return false;
  checkingCloud=true;
  try{
    const head=await api('./api/state?revisionOnly=1');
    if(Number(head.revision)===revision)return false;
    const cloud=await getCloud(),local=localState(),cloudText=stableJSON(cloud.payload||{});
    if(stableJSON(local)===lastSynced&&!queuedSnapshot){await saveLocal(cloud.payload||{});revision=Number(cloud.revision)||0;lastSynced=cloudText;status('Sincronizado','cloud');location.reload();return true}
    conflict=true;revision=Number(cloud.revision)||0;status('Conflicto: toca para revisar','error');return false;
  }finally{checkingCloud=false}
}
function startPolling(){
  if(pollTimer)return;
  const refresh=()=>{if(document.visibilityState!=='visible'||!ready||busy||checkingCloud)return;checkCloud().catch(error=>{console.warn('LRX Cloudflare foreground sync',error);status('Sin conexión; guardado local','error')})};
  window.addEventListener('focus',refresh);window.addEventListener('online',refresh);
  document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')refresh()});
  const schedule=()=>{pollTimer=setTimeout(async()=>{
    pollTimer=null;
    try{await checkCloud();pollDelay=60000}
    catch(error){console.warn('LRX Cloudflare poll',error);status('Sin conexión; guardado local','error');pollDelay=Math.min(pollDelay*2,900000)}
    schedule();
  },pollDelay)};
  schedule();
}
function schedulePublish(delay=900){clearTimeout(publishTimer);if(!queuedSnapshot||!ready||conflict)return;publishTimer=setTimeout(flushQueued,delay)}
async function flushQueued(){
  if(busy||!queuedSnapshot||!ready||conflict)return;
  const snapshot=queuedSnapshot;queuedSnapshot=null;busy=true;let retryDelay=900;
  try{
    await window.LRXPersistentState?.flush?.();await publish(snapshot);publishRetryDelay=1500;
    if(queuedSnapshot)status('Guardando cambios…','local');else status('Sincronizado','cloud');
  }catch(error){
    console.error('LRX Cloudflare publish',error);
    if(error.status===409){conflict=true;queuedSnapshot=localState();revision=Number(error.revision)||revision;status('Conflicto: toca para revisar','error')}
    else{queuedSnapshot=localState();status('Guardado local; nube pendiente','error');retryDelay=publishRetryDelay;publishRetryDelay=Math.min(publishRetryDelay*2,60000)}
  }finally{busy=false;if(queuedSnapshot&&!conflict)schedulePublish(retryDelay)}
}
function onLocalSave(value){
  queuedSnapshot=JSON.parse(JSON.stringify(value));
  if(conflict){status('Conflicto: toca para revisar','error');return}
  if(ready)schedulePublish(900);else status('Guardado local; conectando…','local');
}
async function uploadResourceFile(file,resourceId){
  const safeName=String(file.name||'documento').normalize('NFKD').replace(/[^\w.-]+/g,'_').slice(-120)||'documento',path=`cloudflare/${String(resourceId).replace(/[^\w-]/g,'_')}/${crypto.randomUUID()}-${safeName}`;
  const response=await fetch(`./api/resources/${path.split('/').map(encodeURIComponent).join('/')}`,{method:'POST',credentials:'same-origin',body:file,headers:{'Content-Type':file.type||'application/octet-stream'}});
  if(!response.ok)throw Error('No se pudo guardar el documento en Cloudflare.');
  return {path,name:file.name||safeName,type:file.type||'application/octet-stream',size:file.size||0,uploadedAt:new Date().toISOString()};
}
async function downloadResourceFile(path){
  const parts=String(path||'').split('/').filter(Boolean);if(parts[0]!=='cloudflare')throw Error('Este adjunto se guardó en Supabase y su archivo no viene dentro del respaldo JSON. Hay que transferirlo por separado cuando Supabase vuelva a permitir la descarga.');
  const safe=parts.map(encodeURIComponent).join('/'),response=await fetch(`./api/resources/${safe}`,{credentials:'same-origin',cache:'no-store'});
  if(!response.ok)throw Error('No se pudo leer el documento ('+response.status+').');return response.blob();
}
async function handle(){
  try{
    if(conflict){
      const cloud=await getCloud(),local=localState(),choice=await chooseCopy();if(!choice)return;preserveLocal(local);revision=Number(cloud.revision)||0;
      if(choice==='cloud'){queuedSnapshot=null;await saveLocal(cloud.payload||{});lastSynced=stableJSON(cloud.payload||{});location.reload();return}
      if(choice==='local'){await publish(local);queuedSnapshot=null}
      else{await publishMerged(local,cloud);queuedSnapshot=null;location.reload();return}
      conflict=false;ready=true;status('Sincronizado','cloud');startPolling();return;
    }
    if(queuedSnapshot){schedulePublish(0);return}
    if(!ready){await connectOnce();return}
    await checkCloud();
  }catch(error){
    console.error('LRX Cloudflare connection',error);status('Guardado local; nube no disponible','error');alert(error.message||'No se pudo conectar con Cloudflare. Tus datos locales se conservan.');
  }
}
window.LRXCloudSync={onLocalSave,uploadResourceFile,downloadResourceFile};
document.addEventListener('DOMContentLoaded',()=>{
  status('Esperando acceso…','local');statusEl()?.addEventListener('click',handle);
  loginGate().then(()=>connectOnce().catch(error=>{console.error('LRX Cloudflare connect',error);status('Guardado local; nube no disponible','error')}));
});
})();
