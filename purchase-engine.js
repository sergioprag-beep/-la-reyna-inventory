/* LRX Purchase Engine v157
   One canonical OCR/document parser for supplier purchases.
   No inventory mutation occurs here; this engine only reads and structures data.
*/
(function(global){
 'use strict';
 const ENGINE_VERSION='v166';
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
 function layoutRows(pages,catalog){
  const out=[];
  for(const page of pages||[]){
   const groups=groupLayout(page.items||[]);if(!groups.length)continue;
   let hi=-1,heads=[];
   for(let i=0;i<groups.length;i++){
    const t=norm(groups[i].text);
    if(/item code/.test(t)&&/qty/.test(t)&&/description/.test(t)&&/unit/.test(t)&&/price/.test(t)&&/amount/.test(t)){hi=i;heads=groups[i].items;break}
   }
   if(hi<0)continue;
   // GFS and similar invoices use the header words themselves as column anchors.
   const findX=(predicate,fallback)=>{const a=heads.filter(it=>predicate(norm(it.text))).map(it=>Number(it.x)).filter(Number.isFinite);return a.length?a[a.length-1]:fallback};
   const codeX=findX(t=>t==='code',30),qtyX=findX(t=>t==='qty',82),descX=findX(t=>t==='description',205),catX=findX(t=>t==='cat'||t==='category',354),guideX=findX(t=>t==='guide'||t==='cost',383),specX=findX(t=>t==='specs'||t==='spec',433),priceX=findX(t=>t==='price'||t==='unit',463),taxX=findX(t=>t==='tax',515),amountX=findX(t=>t==='amount',549);
   const mid=(a,b)=>(a+b)/2;
   // Header labels are often centered over their columns. GFS is a good example: the
   // DESCRIPTION label begins at x≈206 while the actual description text begins at x≈106.
   // Use a small gap after QTY as the left edge of the description column instead of the
   // midpoint between the QTY and DESCRIPTION header centers.
   const descStart=qtyX+10;
   const bucket=x=>{if(x<mid(codeX,qtyX))return'code';if(x<descStart)return'qty';if(x<mid(descX,catX))return'desc';if(x<mid(catX,guideX))return'ignore';if(x<mid(guideX,specX))return'ignore';if(x<mid(specX,priceX))return'ignore';if(x<mid(priceX,taxX))return'unitprice';if(x<mid(taxX,amountX))return'ignore';return'total'};
   for(let i=hi+1;i<groups.length;i++){
    const g=groups[i];if(STOP.test(g.text))break;
    const b={code:[],qty:[],desc:[],unitprice:[],total:[]};
    for(const it of g.items){const k=bucket(Number(it.x||0));if(b[k])b[k].push(it.text)}
    const code=b.code.join('').replace(/[^A-Za-z0-9_-]/g,'');
    const qty=num(b.qty.join(' '));
    const desc=b.desc.join(' ').replace(/\s+/g,' ').trim();
    const unitPrice=num(b.unitprice.join(' '));
    const total=num(b.total.join(' '));
    if(!/^\d{4,12}$/.test(code)||qty<=0||!desc||unitPrice<=0||total<=0)continue;
    if(Math.abs(qty*unitPrice-total)>Math.max(0.10,total*0.03))continue;
    const match=matchProduct(desc,catalog,code);const product=match?.p;
    out.push({product:product?.name||desc,qty,unit:product?.standardUnit||product?.unit||inferUnit(desc),unitCost:unitPrice,lineTotal:total,source:'structured-table',matchScore:match?.score||0,code});
   }
  }
  const seen=new Set();return out.filter(r=>{const k=(r.code||'')+'|'+norm(r.product);if(seen.has(k))return false;seen.add(k);return true});
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
  if(!invoice){for(const line of lines){const ms=line.match(/(?:invoice|factura)\s*(?:number|numero|número|no\.?|#)?\s*[:#-]?\s*([A-Z0-9][A-Z0-9\-\/\.]{4,})\b/i);if(ms){invoice=ms[1];break}}}
  let date='';const dm=compact.match(/\b(\d{1,2})[\/-](\d{1,2})[\/-](20\d{2})\b/);if(dm)date=`${dm[3]}-${String(dm[1]).padStart(2,'0')}-${String(dm[2]).padStart(2,'0')}`;else{const iso=compact.match(/\b(20\d{2})[-\/](\d{1,2})[-\/](\d{1,2})\b/);if(iso)date=`${iso[1]}-${String(iso[2]).padStart(2,'0')}-${String(iso[3]).padStart(2,'0')}`}
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
  // Critical safety rule: if the document exposes a structured table header but its rows
  // cannot be validated, do NOT fall back to arbitrary numeric OCR lines.
  const hasStructuredHeader=/item\s+code[\s\S]*qty[\s\S]*description[\s\S]*unit\s+price[\s\S]*amount/i.test(String(text||'').replace(/\s+/g,' '));
  if(!lines.length&&!hasStructuredHeader){
   // Conservative generic fallback: only lines with explicit qty + unit + price are eligible.
   const raw=String(text||'').split(/\r?\n/).map(x=>x.replace(/\s+/g,' ').trim()).filter(Boolean);
   for(const l of raw){if(HEADER.test(l)||STOP.test(l))continue;const m=l.match(/^(.{3,120}?)\s+(\d+(?:[.,]\d+)?)\s+(case|cases|cs|ea|each|unit|units|unidad|unidades|lb|lbs|oz|kg|g|gal|l|ml)\s+\$?([\d,]+(?:\.\d{1,4})?)(?:\s+\$?([\d,]+(?:\.\d{1,2})?))?$/i);if(!m)continue;const q=num(m[2]),cost=num(m[4]),total=num(m[5]||m[4]);if(q>0&&cost>0&&Math.abs(q*cost-total)<=Math.max(.1,total*.03)){const mt=matchProduct(m[1],products);lines.push({product:mt?.p?.name||m[1],qty:q,unit:unitAliases[m[3].toLowerCase()]||'unidad',unitCost:cost,lineTotal:total,source:'explicit-row',matchScore:mt?.score||0})}}
  }
  // GFS-style text fallback: if the PDF/image layout is unavailable, require the
  // actual item-code + quantity + description + numeric tail structure. This prevents
  // addresses, phone numbers, customer IDs and ZIP codes from becoming products.
  if(!lines.length){
   const raw=String(text||'').split(/\r?\n/).map(x=>x.replace(/\s+/g,' ').trim()).filter(Boolean);
   for(const l of raw){
    const m=l.match(/^(\d{4,12})\s+(\d+(?:[.,]\d+)?)\s+(.+?)\s+\d+(?:[.,]\d+)?\s+\d+(?:[.,]\d+)?\s+(\d+(?:[.,]\d+)?)\s+(\d+(?:[.,]\d+)?)$/);
    if(!m)continue;
    const code=m[1],q=num(m[2]),unitPrice=num(m[4]),lineTotal=num(m[5]);
    if(q<=0||unitPrice<=0||lineTotal<=0||Math.abs(q*unitPrice-lineTotal)>Math.max(.10,lineTotal*.03))continue;
    const mt=matchProduct(m[3],products,code);
    lines.push({product:mt?.p?.name||m[3],qty:q,unit:mt?.p?.standardUnit||mt?.p?.unit||inferUnit(m[3]),unitCost:unitPrice,lineTotal,source:'structured-text',matchScore:mt?.score||0,code});
   }
  }
  if(!base.subtotal&&lines.length)base.subtotal=lines.reduce((a,r)=>a+Number(r.lineTotal||Number(r.qty||0)*Number(r.unitCost||0)),0);
  if(!base.tax){
    const implied=Number(base.total||0)-Number(base.subtotal||0);
    base.tax=Math.abs(implied)<0.01?0:(implied>0?implied:0);
  }
  base.lines=lines;
  if(!/\b(?:tax|sales\s+tax|taxes|impuesto|impuestos|iva|total\s+tax)\b/i.test(text||''))base.tax=0;
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
