/* Shared LRX state through Cloudflare Pages Functions. */
(()=>{
'use strict';

const DATA_KEY='lrx_state_v140',BACKUP_KEY=DATA_KEY+'.backup';
let revision=0,lastSynced='',pollTimer=null,publishTimer=null,pollDelay=12000,localCacheFailed=false,localPending=false,localMutationSeq=0;
let publishRetryDelay=1500,busy=false,queuedSnapshot=null,conflict=false,ready=false,connectPromise=null,reconciling=false,checkPromise=null;
const BOOTSTRAP_KEY='lrx_cloud_bootstrapped_v1',PENDING_KEY='lrx_cloud_local_pending_v1';

const statusEl=()=>document.getElementById('syncStatus');
function status(label,kind='local'){
  const el=statusEl();if(!el)return;
  if(kind==='cloud'&&localCacheFailed){label='Nube sincronizada; copia local pendiente';kind='error'}
  el.querySelector('b').textContent=label;el.dataset.state=kind;
  el.title=localCacheFailed?'Cloudflare conserva los datos sincronizados, pero este navegador no pudo guardar su copia local.':kind==='cloud'?'Datos sincronizados en Cloudflare':kind==='error'?'Hay cambios pendientes o dos copias por revisar':'Sincroniza los registros en Cloudflare';
}
function localState(){try{const shared=window.LRXGetSharedState?.();if(shared&&typeof shared==='object')return shared;return JSON.parse(localStorage.getItem(DATA_KEY)||'{}')}catch{return{}}}
function stableJSON(value,path=''){
  if(Array.isArray(value))return '['+value.map((item,index)=>stableJSON(item,`${path}[${index}]`)).join(',')+']';
  if(value&&typeof value==='object')return '{'+Object.keys(value).sort().filter(key=>value[key]!==undefined&&key!=='legacyRecoveredAt'&&!(path==='_recipeLegacyRecovered'&&key==='at')).map(key=>JSON.stringify(key)+':'+stableJSON(value[key],path?path+'.'+key:key)).join(',')+'}';
  return JSON.stringify(value);
}
function hasRecords(value){return Object.entries(value||{}).some(([key,items])=>key!=='users'&&key!=='audit'&&Array.isArray(items)&&items.length>0)}
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));

async function saveLocal(value,{cloudConfirmed=false}={}){
  const serialized=JSON.stringify(value),storage=window.LRXPersistentState;
  try{
    if(typeof window.LRXApplySharedState==='function'){
      const applied=window.LRXApplySharedState(value);
      if(applied===false)throw Error('La app rechazó la copia compartida.');
    }else throw Error('La app todavía no está lista para recibir la copia compartida.');
  }catch(error){localCacheFailed=true;console.warn('LRX cloud copy could not be applied in memory',error);status('Nube sincronizada; vuelve a cargar para aplicar la copia','error');return false}
  try{
    if(storage?.ready)await storage.ready;
    if(storage?.persist){
      try{await storage.persist(storage.key||DATA_KEY,serialized)}
      catch(error){
        let recoveryError=error,recovered=false;
        try{if(storage.clearDuplicateBackup)recovered=await storage.clearDuplicateBackup()}catch(cleanupError){recoveryError=cleanupError}
        if(recovered){try{await storage.persist(storage.key||DATA_KEY,serialized);recovered='saved'}catch(retryError){recoveryError=retryError;recovered=false}}
        // A cloud-confirmed snapshot is a safe source to atomically replace
        // this browser's stale local backup if quota prevents a normal write.
        if(recovered!=='saved'&&cloudConfirmed&&storage.clearBackupForCloudSave){
          try{recovered=await storage.clearBackupForCloudSave(storage.key||DATA_KEY,serialized)?'saved':false}catch(replaceError){recoveryError=replaceError;recovered=false}
        }
        if(recovered!=='saved')throw recoveryError;
      }
    }
    else{localStorage.setItem(DATA_KEY,serialized);if(localStorage.getItem(DATA_KEY)!==serialized)throw Error('El navegador no confirmó el guardado local.')}
    localCacheFailed=false;
    return true;
  }catch(error){localCacheFailed=true;console.warn('LRX cloud copy was applied, but browser cache could not be saved',error);status(cloudConfirmed?'Nube sincronizada; copia local pendiente':'Copia local pendiente; nube por confirmar','error');return false}
}
function hasPendingLocalChanges(){if(localPending)return true;try{return localStorage.getItem(PENDING_KEY)==='1'}catch{return false}}
function markLocalChangesPending(){localPending=true;try{localStorage.setItem(PENDING_KEY,'1')}catch(error){console.warn('LRX could not mark local changes as pending',error)}}
function markCloudBootstrapComplete(){try{localStorage.setItem(BOOTSTRAP_KEY,'1')}catch(error){console.warn('LRX could not store sync bootstrap marker',error)}}
function clearPendingIfCurrent(snapshot){if(stableJSON(localState())!==stableJSON(snapshot)||queuedSnapshot)return false;localPending=false;try{localStorage.removeItem(PENDING_KEY)}catch{}return true}
async function api(path,options={}){
  const response=await fetch(path,{cache:'no-store',credentials:'same-origin',...options,headers:{...(options.body?{'Content-Type':'application/json'}:{}),...(options.headers||{})}});
  let body={};try{body=await response.json()}catch{}
  if(!response.ok){const error=Error(body.error||`Error HTTP ${response.status}`);error.status=response.status;error.revision=body.revision;throw error}
  return body;
}
async function getCloud(){
  // Download the immutable snapshot in bounded pieces. A single full-state
  // read can exceed the Pages Worker resource budget for larger restaurants.
  for(let attempt=0;attempt<3;attempt++){
    const manifest=await api('./api/state?manifest=1');
    const count=Number(manifest.chunkCount)||0;
    if(!manifest.snapshotId)return{payload:null,revision:Number(manifest.revision)||0,updatedAt:manifest.updatedAt||null};
    if(!Number.isSafeInteger(count)||count<1||count>512)throw Error('La copia compartida informó fragmentos inválidos. No se modificó la copia local.');
    const pieces=Array.from({length:count},()=>[]);let changed=false;
    const fetchParts=async jobs=>{
      for(let start=0;start<jobs.length;start+=4){
        const batchJobs=jobs.slice(start,start+4);
        try{
          const batch=await Promise.all(batchJobs.map(({index,part})=>api(`./api/state?chunk=${index}&part=${part}&snapshot=${encodeURIComponent(manifest.snapshotId)}`)));
          for(let position=0;position<batch.length;position++){
            const item=batch[position],job=batchJobs[position];
            if(item.snapshotId!==manifest.snapshotId||item.index!==job.index||item.part!==job.part||!Number.isSafeInteger(item.partCount)||item.partCount<1||item.partCount>4||typeof item.data!=='string')
              throw Error('La copia compartida devolvió un fragmento inválido. No se modificó la copia local.');
            if(job.part===0){pieces[job.index].length=item.partCount;pieces[job.index].fill(undefined);}
            else if(pieces[job.index].length!==item.partCount)throw Error('La copia compartida cambió durante la descarga. No se modificó la copia local.');
            pieces[job.index][job.part]=item.data;
          }
        }catch(error){if(error.status===409){changed=true;return}throw error}
      }
    };
    await fetchParts(Array.from({length:count},(_,index)=>({index,part:0})));
    if(changed)continue;
    const remaining=[];
    for(let index=0;index<count;index++){
      const partCount=pieces[index].length;
      if(!partCount)throw Error('La copia compartida está incompleta. No se modificó la copia local.');
      for(let part=1;part<partCount;part++)remaining.push({index,part});
    }
    await fetchParts(remaining);
    if(changed)continue;
    const chunks=pieces.map((parts,index)=>{
      if(!parts.length||parts.some(part=>typeof part!=='string'))throw Error('La copia compartida está incompleta. No se modificó la copia local.');
      return parts.join('');
    });
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
function mergeValues(local,cloud,path=''){
  if(Array.isArray(local)||Array.isArray(cloud)){
    const left=Array.isArray(local)?local:[],right=Array.isArray(cloud)?cloud:[],out=[],positions=new Map();
    const keyOf=value=>value&&typeof value==='object'&&!Array.isArray(value)?String(value.id??value.uuid??value.key??value.code??value.name??JSON.stringify(value)):JSON.stringify(value);
    for(const item of [...right,...left]){const key=keyOf(item);if(!positions.has(key)){positions.set(key,out.length);out.push(item)}else{const at=positions.get(key),existing=out[at];if(item&&existing&&typeof item==='object'&&typeof existing==='object'&&!Array.isArray(item)&&!Array.isArray(existing))out[at]=mergeValues(item,existing,path)}}
    return out;
  }
  if(local&&cloud&&typeof local==='object'&&typeof cloud==='object'){
    const localCompleted=path==='production'&&local.status==='completed',cloudCompleted=path==='production'&&cloud.status==='completed';
    const localTime=Date.parse(local.updatedAt||local.modifiedAt||local.finishedAt||local.startedAt||''),cloudTime=Date.parse(cloud.updatedAt||cloud.modifiedAt||cloud.finishedAt||cloud.startedAt||''),preferred=localCompleted!==cloudCompleted?(localCompleted?local:cloud):Number.isFinite(localTime)&&localTime>cloudTime?local:cloud,other=preferred===local?cloud:local,out={...other,...preferred};
    for(const key of new Set([...Object.keys(local),...Object.keys(cloud)]))if(local[key]&&cloud[key]&&typeof local[key]==='object'&&typeof cloud[key]==='object')out[key]=mergeValues(local[key],cloud[key],key);
    if(path==='production'&&(localCompleted||cloudCompleted)){out.status='completed';out.finishedAt=preferred.finishedAt||other.finishedAt||null;out.lot=preferred.lot||other.lot||null}
    return out;
  }
  return local===undefined?cloud:cloud===undefined?local:cloud;
}
function purchaseTombstones(state){
  const tombstones=Array.isArray(state?.syncTombstones)?state.syncTombstones.slice():[];
  const known=new Set(tombstones.filter(x=>x?.collection==='purchases'&&x?.scope==='group').map(x=>String(x.targetId)));
  for(const event of Array.isArray(state?.audit)?state.audit:[]){
    if(event?.event!=='PURCHASE_DELETE')continue;
    const match=String(event.detail||'').match(/Compra eliminada:\s*(.+)$/i),targetId=match?.[1]?.trim();
    if(!targetId||known.has(targetId))continue;
    tombstones.push({id:`TOMB-purchases-group-${targetId}`,collection:'purchases',scope:'group',targetId,createdAt:event.date||''});
    known.add(targetId);
  }
  return tombstones;
}
function applyPurchaseTombstones(state){
  const tombstones=purchaseTombstones(state),deleted=new Set(tombstones.filter(x=>x?.collection==='purchases'&&x?.scope==='group').map(x=>String(x.targetId)));
  state.syncTombstones=tombstones;
  const deletedRows=new Map();
  for(const tombstone of tombstones){if(tombstone?.scope!=='record'||!tombstone?.collection||!tombstone?.targetId)continue;if(!deletedRows.has(tombstone.collection))deletedRows.set(tombstone.collection,new Set());deletedRows.get(tombstone.collection).add(String(tombstone.targetId))}
  for(const [collection,ids] of deletedRows){if(Array.isArray(state[collection]))state[collection]=state[collection].filter(row=>!ids.has(String(row?.id||'')))}
  if(deletedRows.has('production')){const ids=deletedRows.get('production');if(Array.isArray(state.labels))state.labels=state.labels.filter(row=>!ids.has(String(row?.productionId||'')))}
  if(deleted.size){
    for(const collection of ['purchases','purchasePayments','purchaseReceipts']){
      if(Array.isArray(state[collection]))state[collection]=state[collection].filter(row=>!deleted.has(String(row?.purchaseId||row?.id||'')));
    }
    if(Array.isArray(state.documents))state.documents=state.documents.filter(row=>!deleted.has(String(row?.contextRecordId||row?.purchaseId||'')));
    if(Array.isArray(state.movements))state.movements=state.movements.filter(row=>!deleted.has(String(row?.purchaseId||''))||String(row?.type||'').toUpperCase()==='REVERSA COMPRA');
  }
  return state;
}
async function publishMerged(local,cloud){
  // Freeze the input. `localState()` returns the live application object, which
  // can be edited while a large snapshot is being uploaded to Cloudflare.
  const initial=JSON.parse(JSON.stringify(local||{})),initialText=stableJSON(initial),mutationAtStart=localMutationSeq;
  let base=cloud,merged=initial;
  for(let attempt=0;attempt<3;attempt++){
    merged=applyPurchaseTombstones(mergeValues(merged,base?.payload||{}));revision=Number(base?.revision)||0;
    try{
      await publish(merged);
      // From this point Cloudflare accepted the merge and is authoritative.
      // A quota/IndexedDB error on this device must not turn a successful
      // cloud commit back into a conflict or cause stale data to be merged.
      markCloudBootstrapComplete();
      const current=localState(),changedDuringPublish=localMutationSeq!==mutationAtStart||stableJSON(current)!==initialText;
      if(!changedDuringPublish){
        const saved=await saveLocal(merged,{cloudConfirmed:true});
        clearPendingIfCurrent(merged);
        if(!saved)status('Nube sincronizada; copia local pendiente','error');
      }else{
        // Preserve edits made during the network request and queue them on top
        // of the committed merge instead of replacing them with an older copy.
        const followup=applyPurchaseTombstones(mergeValues(localState(),merged));
        if(stableJSON(followup)!==stableJSON(merged)){
          queuedSnapshot=JSON.parse(JSON.stringify(followup));markLocalChangesPending();
        }else clearPendingIfCurrent(merged);
      }
      return merged;
    }
    catch(error){if(error.status!==409||attempt===2)throw error;base=await getCloud();if(!base)throw error}
  }
  throw Error('La copia compartida siguió cambiando. Espera unos segundos y vuelve a sincronizar.');
}
async function reconcileConflict(cloud,local=localState()){
  if(reconciling)return false;
  reconciling=true;conflict=true;status('Combinando copias…','local');
  try{
    const merged=await publishMerged(local,cloud);
    conflict=false;ready=true;lastSynced=stableJSON(merged);markCloudBootstrapComplete();clearPendingIfCurrent(merged);pollDelay=12000;publishRetryDelay=1500;
    if(queuedSnapshot){status('Guardando cambios…','local');schedulePublish(0)}else status('Sincronizado','cloud');return true;
  }catch(error){
    console.error('LRX automatic reconciliation',error);
    status('Conflicto pendiente; reintentando','error');pollDelay=12000;return false;
  }finally{reconciling=false}
}
function chooseCopy(){
  return new Promise(resolve=>{
    const layer=document.createElement('div');layer.style.cssText='position:fixed;inset:0;z-index:31000;background:#10182899;display:grid;place-items:center;padding:18px';
    layer.innerHTML='<div style="background:#fff;color:#182235;width:min(480px,100%);padding:22px;border-radius:16px;box-shadow:0 18px 70px #0005"><h2 style="margin:0 0 8px">Hay dos copias de los datos</h2><p style="line-height:1.5">La copia de Cloudflare se conserva hasta que el envío se confirme. Si el navegador no logra guardar su copia local, los cambios pueden seguir en la nube, pero este dispositivo podría volver a mostrar datos antiguos al recargar. La combinación también respeta las compras eliminadas registradas en la auditoría.</p><div style="display:grid;gap:9px;margin-top:18px"><button data-choice="merge" style="padding:12px;background:#c92d70;color:white;border:0;border-radius:9px;font-weight:700">Combinar ambas copias</button><button data-choice="cloud" style="padding:11px;background:white;border:1px solid #cbd5e1;border-radius:9px">Usar la copia de Cloudflare</button><button data-choice="local" style="padding:11px;background:white;border:1px solid #cbd5e1;border-radius:9px">Subir la copia de esta computadora</button><button data-choice="cancel" style="padding:9px;background:transparent;border:0">Cancelar</button></div></div>';
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
    if(!confirm('Cloudflare todavía no tiene una copia de LRX. ¿Quieres publicar los datos de esta computadora?')){ready=true;status('Solo en esta computadora','local');startPolling();return}
    await publish(local);lastSynced=stableJSON(local);markCloudBootstrapComplete();clearPendingIfCurrent(local);ready=true;status('Sincronizado','cloud');startPolling();return;
  }
  const cloudText=stableJSON(cloud.payload);
  if(localText===cloudText){lastSynced=cloudText;markCloudBootstrapComplete();try{localStorage.removeItem(PENDING_KEY)}catch{}status('Sincronizado','cloud');ready=true;startPolling();if(queuedSnapshot)schedulePublish(0);return}
  if(!hasRecords(local)){
    const saved=await saveLocal(cloud.payload,{cloudConfirmed:true});lastSynced=cloudText;ready=true;startPolling();
    markCloudBootstrapComplete();localPending=false;try{localStorage.removeItem(PENDING_KEY)}catch{}
    if(saved)status('Sincronizado','cloud')
    else status('Nube disponible; falta guardar copia local','error');return;
  }
  // Before first bootstrap, combine existing device data once. Later, only a
  // device with real local edits may contribute; otherwise Cloudflare is the
  // canonical copy and stale browser storage must not resurrect deleted data.
  if(localStorage.getItem(BOOTSTRAP_KEY)==='1'&&!hasPendingLocalChanges()){
    const saved=await saveLocal(cloud.payload,{cloudConfirmed:true});lastSynced=cloudText;ready=true;startPolling();
    markCloudBootstrapComplete();localPending=false;try{localStorage.removeItem(PENDING_KEY)}catch{}
    if(saved)status('Sincronizado','cloud');else status('Nube disponible; falta guardar copia local','error');return;
  }
  conflict=true;ready=true;startPolling();await reconcileConflict(cloud,local);
}
function connectOnce(){if(!connectPromise)connectPromise=connect().finally(()=>{connectPromise=null});return connectPromise}
async function checkCloud(){
  if(checkPromise)return checkPromise;
  if(reconciling||busy||!ready)return false;
  checkPromise=(async()=>{
    const head=await api('./api/state?revisionOnly=1');
    if(Number(head.revision)===revision&&!conflict)return false;
    const cloud=await getCloud(),local=localState(),cloudText=stableJSON(cloud.payload||{});
    if(stableJSON(local)===lastSynced&&!hasPendingLocalChanges()&&!queuedSnapshot){const saved=await saveLocal(cloud.payload||{},{cloudConfirmed:true});revision=Number(cloud.revision)||0;lastSynced=cloudText;if(saved){markCloudBootstrapComplete();localPending=false;try{localStorage.removeItem(PENDING_KEY)}catch{}status('Sincronizado','cloud')}else status('Nube disponible; falta guardar copia local','error');return saved}
    revision=Number(cloud.revision)||0;conflict=true;return reconcileConflict(cloud,local);
  })();
  try{return await checkPromise}finally{checkPromise=null}
}
function startPolling(){
  if(pollTimer)return;
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
    await publish(snapshot);publishRetryDelay=1500;
    if(queuedSnapshot)status('Guardando cambios…','local');
    else{markCloudBootstrapComplete();clearPendingIfCurrent(snapshot);status('Sincronizado','cloud')}
  }catch(error){
    console.error('LRX Cloudflare publish',error);
    if(error.status===409){conflict=true;queuedSnapshot=localState();revision=Number(error.revision)||revision;status('Conflicto: sincronizando copias…','error');try{await reconcileConflict(await getCloud(),localState())}catch(syncError){console.warn('LRX reconciliation deferred',syncError)}}
    else{queuedSnapshot=localState();status('Guardado local; nube pendiente','error');retryDelay=publishRetryDelay;publishRetryDelay=Math.min(publishRetryDelay*2,60000)}
  }finally{busy=false;if(queuedSnapshot&&!conflict)schedulePublish(retryDelay)}
}
function onLocalSave(value){
  localMutationSeq++;
  queuedSnapshot=JSON.parse(JSON.stringify(value));
  markLocalChangesPending();
  if(conflict){status(reconciling?'Combinando copias…':'Conflicto pendiente; reintentando','error');return}
  if(ready)schedulePublish(900);else status('Guardado local; conectando…','local');
}
function onLocalCacheFailure(error){localCacheFailed=true;console.warn('LRX local cache unavailable; cloud publish remains enabled',error);status('Copia local falló; nube pendiente','error')}
function onLocalCacheSaved(){if(!localCacheFailed)return;localCacheFailed=false;if(ready&&!queuedSnapshot&&!conflict)status('Sincronizado','cloud')}
function refreshWhenActive(){
  if(!ready||document.visibilityState==='hidden'||!navigator.onLine||busy||reconciling)return;
  clearTimeout(pollTimer);pollTimer=null;
  checkCloud().catch(error=>{console.warn('LRX foreground sync',error);status('Sin conexión; guardado local','error')}).finally(startPolling);
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
      const cloud=await getCloud(),local=localState(),choice=await chooseCopy();if(!choice)return;revision=Number(cloud.revision)||0;
      if(choice==='cloud'){queuedSnapshot=null;const saved=await saveLocal(cloud.payload||{},{cloudConfirmed:true});lastSynced=stableJSON(cloud.payload||{});markCloudBootstrapComplete();localPending=false;try{localStorage.removeItem(PENDING_KEY)}catch{}conflict=false;ready=true;status(saved?'Sincronizado':'Nube sincronizada; copia local pendiente',saved?'cloud':'error');startPolling();return}
      if(choice==='local'){await publish(local);queuedSnapshot=null;markCloudBootstrapComplete();clearPendingIfCurrent(local)}
      else{await publishMerged(local,cloud);queuedSnapshot=null;conflict=false;ready=true;status('Sincronizado','cloud');startPolling();return}
      conflict=false;ready=true;status('Sincronizado','cloud');startPolling();return;
    }
    if(queuedSnapshot){schedulePublish(0);return}
    if(!ready){await connectOnce();return}
    await checkCloud();
  }catch(error){
    console.error('LRX Cloudflare connection',error);status('Guardado local; nube no disponible','error');alert(error.message||'No se pudo conectar con Cloudflare. Tus datos locales se conservan.');
  }
}
window.LRXCloudSync={onLocalSave,onLocalCacheFailure,onLocalCacheSaved,uploadResourceFile,downloadResourceFile};
document.addEventListener('DOMContentLoaded',()=>{
  status('Esperando acceso…','local');statusEl()?.addEventListener('click',handle);
  window.addEventListener('online',refreshWhenActive);
  window.addEventListener('pageshow',refreshWhenActive);
  window.addEventListener('focus',refreshWhenActive);
  document.addEventListener('visibilitychange',refreshWhenActive);
  loginGate().then(()=>connectOnce().catch(error=>{console.error('LRX Cloudflare connect',error);status('Guardado local; nube no disponible','error')}));
});
})();
