/* LRX Purchase Engine v179
   One canonical OCR/document parser for supplier purchases.
   No inventory mutation occurs here; this engine only reads and structures data.
*/
(function(global){
 'use strict';
 const ENGINE_VERSION='v179';
 const unitAliases={
  cs:'caja',case:'caja',cases:'caja',caja:'caja',cajas:'caja',carton:'caja',cartons:'caja',
  ea:'unidad',each:'unidad',unit:'unidad',units:'unidad',unidad:'unidad',unidades:'unidad',pc:'unidad',pcs:'unidad',piece:'unidad',pieces:'unidad',pieza:'unidad',piezas:'unidad',
  dz:'docena',doz:'docena',dozen:'docena',docena:'docena',docenas:'docena',
  lb:'lb',lbs:'lb',pound:'lb',pounds:'lb',libra:'lb',libras:'lb',
  oz:'oz',ounce:'oz',ounces:'oz',onza:'oz',onzas:'oz',
  kg:'kg',kgs:'kg',kilo:'kg',kilos:'kg',kilogram:'kg',kilograms:'kg',
  g:'g',gr:'g',gram:'g',grams:'g',gramo:'g',gramos:'g',
  gal:'gal',gallon:'gal',gallons:'gal',galon:'gal',galones:'gal',
  l:'L',lt:'L',lts:'L',liter:'L',liters:'L',litro:'L',litros:'L',
  ml:'mL',milliliter:'mL',milliliters:'mL',mililitro:'mL',mililitros:'mL'
 };
 const STOP=/^(subtotal|sub total|tax|sales tax|impuesto|iva|grand total|invoice total|total due|amount due|balance due|shipping|freight|discount|payment|terms|thank|product category|number of pieces|misc|received by|signature|please cut|pay this amount)/i;
 const HEADER=/^(invoice|factura|vendor|proveedor|subtotal|total|tax|iva|balance|amount|fecha|date|phone|tel|fax|email|www\.|http|address|direccion|due|terms|invoice no|order no|page|ship to|bill to|customer|customer no|sales rep|thank|thank you|please|payment|cashier|location)/i;
 function norm(s){return String(s??'').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/[^a-z0-9]+/g,' ').replace(/\s+/g,' ').trim()}
 function num(v){let x=String(v??'').replace(/[$€£\s]/g,'').trim();if(x.includes(',')&&x.includes('.'))x=x.lastIndexOf(',')>x.lastIndexOf('.')?x.replace(/\./g,'').replace(',','.'):x.replace(/,/g,'');else if(x.includes(',')&&/,\d{1,2}$/.test(x))x=x.replace(',','.');else x=x.replace(/,/g,'');const n=Number(x);return Number.isFinite(n)?n:0}
 function uniqueCatalog(arr){const m=new Map();for(const p of arr||[]){const name=String(p?.name||'').trim();const k=norm(name);if(k&&!m.has(k))m.set(k,p)}return [...m.values()]}
 function productCode(p){return String(p?.code??p?.sku??p?.itemCode??p?.item_code??p?.upc??p?.barcode??'').replace(/[^A-Za-z0-9]/g,'').toLowerCase()}
 function matchProduct(name,catalog,code=''){
  const ck=String(code||'').replace(/[^A-Za-z0-9]/g,'').toLowerCase();
  if(ck){for(const p of catalog){const pc=productCode(p);if(pc&&pc===ck)return {p,score:1,byCode:true}}}
  const nk=norm(name);if(!nk)return null;
  for(const p of catalog){const pk=norm(p.name);if(pk&&nk===pk)return {p,score:1}}
  let best=null,bestScore=0;
  const nw=nk.split(' ').filter(x=>x.length>=3);
  for(const p of catalog){const pw=norm(p.name).split(' ').filter(x=>x.length>=3);if(!pw.length)continue;let hits=0;for(const w of pw)if(nw.includes(w)||nk.includes(w))hits++;const score=hits/pw.length;if(score>bestScore){bestScore=score;best=p}}
  return best&&bestScore>=0.66?{p:best,score:bestScore}:null;
 }
 function groupLayout(items){
  const clean=(items||[]).filter(x=>String(x?.text||'').trim()).map(x=>({x:Number(x.x||0),y:Number(x.y||0),text:String(x.text||'').trim()}));
  clean.sort((a,b)=>b.y-a.y||a.x-b.x);
  const groups=[];
  for(const it of clean){let g=groups.find(z=>Math.abs(z.y-it.y)<=4);if(!g){g={y:it.y,items:[]};groups.push(g)}g.items.push(it)}
  return groups.sort((a,b)=>b.y-a.y).map(g=>{g.items.sort((a,b)=>a.x-b.x);g.text=g.items.map(x=>x.text).join(' ');return g});
 }
 function role(text){const n=norm(text);if(n==='unit price'||n==='price'||n==='unitprice')return'unitprice';if(n==='amount'||n==='extended'||n==='line total'||n==='total price')return'total';if(n==='qty'||n==='quantity'||n==='ordered'||n==='shipped')return'qty';if(n==='item code'||n==='code'||n==='sku'||n==='upc'||n==='product code')return'code';if(n==='description'||n==='product'||n==='item'||n==='material'||n==='ingredient'||n==='article'||n==='name')return'desc';return''}
 function moneyTokens(s){
  return (String(s||'').match(/(?:\$|€|£)?\s*\d[\d,]*(?:\.\d{1,4})?/g)||[]).map(x=>num(x));
 }
 function parseCandidateLine(line,catalog){
  let s=String(line||'').replace(/\s+/g,' ').trim();
  if(!s||HEADER.test(s)||STOP.test(s))return null;
  const numsIn=(str)=>[...String(str||'').matchAll(/(?:\$|€|£)?\s*\d[\d,]*(?:\.\d{1,4})?/g)].map(m=>({raw:m[0],value:num(m[0]),index:m.index,end:m.index+m[0].length}));
  let m=s.match(/^(\d+(?:[.,]\d+)?)\s+([A-Za-z0-9][A-Za-z0-9._\/-]{2,})\s+(.+)$/i);
  if(m){
    const qty=num(m[1]),code=m[2],rest=m[3],ns=numsIn(rest);
    if(ns.length>=2){
      const a=ns[ns.length-2],b=ns[ns.length-1];
      const desc=(rest.slice(0,a.index).trim()+' '+rest.slice(b.end).trim()).replace(/\s+/g,' ').trim();
      if(qty>0&&desc&&a.value>=0&&b.value>=0){
        const arithmetic=a.value===0||b.value===0||Math.abs(qty*a.value-b.value)<=Math.max(.10,Math.max(1,b.value)*.03);
        if(arithmetic){const mt=matchProduct(desc,catalog,code);return {product:mt?.p?.name||desc,qty,unit:mt?.p?.standardUnit||mt?.p?.unit||inferUnit(desc),unitCost:a.value,lineTotal:b.value,source:'universal-text',matchScore:mt?.score||0,code,matchedBy:mt?.byCode?'SKU':(mt?'NAME':'')}}
      }
    }
  }
  m=s.match(/^(\d+(?:[.,]\d+)?)\s+(.+)$/i);
  if(m){
    const qty=num(m[1]),rest=m[2],ns=numsIn(rest);
    if(ns.length>=2){
      const a=ns[ns.length-2],b=ns[ns.length-1],desc=(rest.slice(0,a.index).trim()+' '+rest.slice(b.end).trim()).replace(/\s+/g,' ').trim();
      if(qty>0&&desc&&a.value>=0&&b.value>=0&&(a.value===0||b.value===0||Math.abs(qty*a.value-b.value)<=Math.max(.10,Math.max(1,b.value)*.03))){const mt=matchProduct(desc,catalog);return {product:mt?.p?.name||desc,qty,unit:mt?.p?.standardUnit||mt?.p?.unit||inferUnit(desc),unitCost:a.value,lineTotal:b.value,source:'universal-text',matchScore:mt?.score||0,code:'',matchedBy:mt?'NAME':''}}
    }
  }
  return null;
 }
 function textRows(text,catalog){
  const raw=String(text||'').replace(/\r/g,'').split('\n').map(x=>x.replace(/\s+/g,' ').trim()).filter(Boolean);
  const rows=[];
  // Join wrapped descriptions with the preceding candidate line. We only join when the
  // next line is clearly continuation text, never when it looks like another item/header/total.
  for(let i=0;i<raw.length;i++){
    let line=raw[i];
    if(HEADER.test(line)||STOP.test(line))continue;
    if(/^(\d+(?:[.,]\d+)?)\s+[A-Za-z0-9][A-Za-z0-9._\/-]{2,}\s+/.test(line) || /^(\d+(?:[.,]\d+)?)\s+.+\s+\$?\d/.test(line)){
      let combined=line;
      let j=i+1;
      while(j<raw.length && !/^(\d+(?:[.,]\d+)?)\s+/.test(raw[j]) && !HEADER.test(raw[j]) && !STOP.test(raw[j])){
        // A continuation normally contains words but no independent monetary pair.
        if(moneyTokens(raw[j]).length>=2)break;
        combined+=' '+raw[j];j++;
      }
      const r=parseCandidateLine(combined,catalog);if(r)rows.push(r);i=j-1;continue;
    }
    const r=parseCandidateLine(line,catalog);if(r)rows.push(r);
  }
  const seen=new Set();return rows.filter(r=>{const k=(r.code||'')+'|'+norm(r.product)+'|'+r.qty+'|'+r.lineTotal;if(seen.has(k))return false;seen.add(k);return true});
 }
 function layoutRows(pages,catalog){
  // Layout-aware extraction is intentionally provider-neutral. We do not use fixed X
  // coordinates. Each OCR/PDF text row is reconstructed from its visible text and then
  // passed through the same universal parser used by plain OCR text.
  const text=[];
  for(const page of pages||[]){
    const groups=groupLayout(page.items||[]);
    for(const g of groups)text.push(g.text);
  }
  return textRows(text.join('\n'),catalog);
 }
 function inferUnit(desc){const first=String(desc).trim().split(/\s+/)[0].toLowerCase();return unitAliases[first]||'unidad'}
 function parseHeader(text,catalogProducts,catalogSuppliers){
  const lines=String(text||'').replace(/\r/g,'').split('\n').map(x=>x.replace(/\s+/g,' ').trim()).filter(Boolean);const compact=lines.join('\n');
  let supplier='';
  const suppliers=uniqueCatalog(catalogSuppliers).sort((a,b)=>String(b.name||'').length-String(a.name||'').length);
  const normalizedText=norm(compact);
  for(const s of suppliers){const sn=norm(s.name);if(sn&&normalizedText.includes(sn)){supplier=s.name;break}}
  if(!supplier){const gm=compact.match(/Gordon\s+Food\s+Service(?:,?\s+Inc\.?)?/i);if(gm)supplier=gm[0].replace(/\s+/g,' ').trim();else{const m=compact.match(/\bGFS\b/i);if(m)supplier='GFS'}}
  let invoice='';
  const datedInvoice=compact.match(/\b(\d{5,})\s+\d{1,2}[\/-]\d{1,2}[\/-]20\d{2}\b/);
  if(datedInvoice)invoice=datedInvoice[1];
  const idx=lines.findIndex(l=>/^(invoice|factura)(?:\s*#)?\s*$/i.test(l));
  if(!invoice&&idx>=0){const n=lines[idx+1]||'';const m=n.match(/^([A-Z0-9][A-Z0-9\-\/\.]{4,})\s+(\d{1,2}[\/-]\d{1,2}[\/-]20\d{2})$/i);if(m)invoice=m[1]}
  if(!invoice){for(const line of lines){const ms=line.match(/(?:invoice|factura)\s*(?:for\s+order\s*)?(?:number|numero|número|no\.?|#)?\s*[:#-]?\s*([A-Z0-9][A-Z0-9\-\/\.]{3,})\b/i);if(ms){invoice=ms[1];break}}}
  if(!invoice){const om=compact.match(/(?:order\s*(?:#|no\.?|number)?|invoice\s+for\s+order\s*#?)\s*([A-Z0-9][A-Z0-9\-\/\.]{3,})/i);if(om)invoice=om[1]}
  let date='';const dm=compact.match(/\b(\d{1,2})[\/-](\d{1,2})[\/-](20\d{2})\b/);if(dm)date=`${dm[3]}-${String(dm[1]).padStart(2,'0')}-${String(dm[2]).padStart(2,'0')}`;else{const iso=compact.match(/\b(20\d{2})[-\/](\d{1,2})[-\/](\d{1,2})\b/);if(iso)date=`${iso[1]}-${String(iso[2]).padStart(2,'0')}-${String(iso[3]).padStart(2,'0')}`;else{const ord=compact.match(/\b(\d{1,2})(?:st|nd|rd|th)\s+(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+(20\d{2})\b/i);if(ord){const months={jan:1,feb:2,mar:3,apr:4,may:5,jun:6,jul:7,aug:8,sep:9,oct:10,nov:11,dec:12};const key=ord[2].slice(0,3).toLowerCase();date=`${ord[3]}-${String(months[key]).padStart(2,'0')}-${String(ord[1]).padStart(2,'0')}`}}}
  const labeled=(rx)=>{for(let i=0;i<lines.length;i++){const m=lines[i].match(rx);if(m)return num(m[1]);if(rx.test(lines[i])){const n=lines[i+1]?.match(/^\$?\s*([0-9][0-9,.]*)\s*$/);if(n)return num(n[1])}}return 0};
  let subtotal=labeled(/(?:^|\s)(?:subtotal|sub\s*total)\s*[:#-]?\s*\$?\s*([0-9][0-9,.]*)\s*$/i);
  let tax=labeled(/(?:^|\s)(?:sales\s*tax|tax\s+amount|taxes|impuesto|impuestos|iva|total\s+tax)\s*[:#-]?\s*\$?\s*([0-9][0-9,.]*)\s*$/i);
  const totals=[];for(const l of lines){const m=l.match(/(?:invoice\s+total|grand\s+total|total\s+due|amount\s+due|balance\s+due|total\s+factura|^total)\s*[:#-]?\s*\$?\s*([0-9][0-9,.]*)/i);if(m)totals.push(num(m[1]))}
  let total=totals.length?totals[totals.length-1]:0;if(!total&&subtotal)total=subtotal+tax;
  return {supplier,invoice,date,subtotal,tax,total,lines:[]};
 }
 function parseInvoice(text,layout,ctx){
  const products=uniqueCatalog(ctx?.products||[]), suppliers=uniqueCatalog(ctx?.suppliers||[]);
  const base=parseHeader(text,products,suppliers);
  let lines=layoutRows(layout,products);
  // Universal text fallback is always available. It is intentionally conservative:
  // only rows with a plausible quantity, product description, and monetary tail become
  // purchase lines. Supplier names, addresses, phones, ZIP codes and totals are rejected.
  if(!lines.length) lines=textRows(text,products);
  if(!base.subtotal&&lines.length)base.subtotal=lines.reduce((a,r)=>a+Number(r.lineTotal||Number(r.qty||0)*Number(r.unitCost||0)),0);
  const explicitTax=/\b(?:tax|sales\s+tax|taxes|impuesto|impuestos|iva|total\s+tax)\b[^\n]*?(?:\$|€|£)?\s*[-]?\d[\d,]*(?:\.\d{1,4})?/i.test(String(text||''));
  if(!base.tax&&!explicitTax){
    const implied=Number(base.total||0)-Number(base.subtotal||0);
    base.tax=Math.abs(implied)<0.01?0:0;
  }
  base.lines=lines;
  if(!explicitTax)base.tax=0;
  if(base.subtotal>0&&base.total>0&&base.tax>0&&Math.abs(base.subtotal+base.tax-base.total)>Math.max(.1,base.total*.03))base.tax=0;
  return base;
 }
 async function ensureTesseract(){if(global.Tesseract)return global.Tesseract;const el=document.querySelector('script[data-lrx-ocr]');if(el){await new Promise((res,rej)=>{if(global.Tesseract)return res();el.addEventListener('load',res,{once:true});el.addEventListener('error',rej,{once:true})});if(global.Tesseract)return global.Tesseract}return await new Promise((resolve,reject)=>{const s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js';s.async=true;s.dataset.lrxOcr='1';s.onload=()=>global.Tesseract?resolve(global.Tesseract):reject(new Error('OCR no disponible'));s.onerror=()=>reject(new Error('No se pudo cargar OCR'));document.head.appendChild(s)})}
 function tsvLayout(tsv){const by=new Map();for(const raw of String(tsv||'').split(/\r?\n/)){const a=raw.split('\t');if(a.length<12||a[0]!=='5')continue;const text=(a[11]||'').trim(),conf=Number(a[10]);if(!text||(!Number.isNaN(conf)&&conf<20))continue;const key=[a[1],a[2],a[3],a[4],a[5]].join(':');let arr=by.get(key);if(!arr){arr=[];by.set(key,arr)}arr.push({x:Number(a[6]||0),y:Number(a[7]||0),text})}const items=[...by.values()].flat();return items.length?[{items}]:[]}
 async function ocrImage(file){const T=await ensureTesseract();const r=await T.recognize(file,'spa+eng');return {text:String(r?.data?.text||'').trim(),layout:tsvLayout(r?.data?.tsv||'')}}
 async function pdfTextWith(pdfjs,file){
  if(!pdfjs)return null;
  if(pdfjs.GlobalWorkerOptions)pdfjs.GlobalWorkerOptions.workerSrc='https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
  const pdf=await pdfjs.getDocument({data:await file.arrayBuffer(),useWorkerFetch:true,isEvalSupported:true}).promise;
  let text='',layout=[];const pages=Math.min(pdf.numPages,12);
  for(let i=1;i<=pages;i++){
    const page=await pdf.getPage(i);
    const tc=await page.getTextContent({normalizeWhitespace:true,disableCombineTextItems:false});
    const items=(tc?.items||[]).filter(x=>String(x?.str||'').trim()).map(x=>({x:Number(x.transform?.[4]||0),y:Number(x.transform?.[5]||0),text:String(x.str||'').trim()}));
    const groups=groupLayout(items);const pageText=groups.map(g=>g.text).join('\n').trim();
    if(pageText)text+=(text?'\n':'')+pageText;layout.push({items});
  }
  return text.trim()?{text:text.trim(),layout}:null;
 }
 async function readDocument(file){
  if(!file)return {text:'',layout:[]};
  const isPdf=file.type==='application/pdf'||/\.pdf$/i.test(file.name);
  if(!isPdf){if(file.type?.startsWith('image/'))return await ocrImage(file);if(file.type==='text/plain'||/\.txt$/i.test(file.name))return {text:await file.text(),layout:[]};return {text:'',layout:[]}}
  let lastError=null;
  // Preferred path: classic PDF.js is loaded by index.html for Safari/iOS compatibility.
  try{const r=await pdfTextWith(global.pdfjsLib,file);if(r)return r;}catch(e){lastError=e}
  // Secondary path for environments where the classic global is unavailable.
  const loaders=[async()=>await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.mjs')];
  for(const load of loaders){try{const mod=await load();const pdfjs=mod?.default||mod;const r=await pdfTextWith(pdfjs,file);if(r)return r;}catch(e){lastError=e}}
  throw lastError||new Error('No se pudo leer el PDF');
 }
 global.LRXPurchaseEngine={version:ENGINE_VERSION,parseInvoice,readDocument};
})(window);
