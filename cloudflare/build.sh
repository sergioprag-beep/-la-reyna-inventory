#!/usr/bin/env bash
set -euo pipefail

rm -rf dist
mkdir -p dist
cp index.html styles.css app.js purchase-engine.js catalog-controls.js cloudflare-sync.js ui-translation-extra.js recipe-price-mobile.js sw.js master.json manifest.webmanifest hero-food.jpg hero-bar.jpg LRX-LOGO-PLANTILLAS.png LRX-LOGO-IMPRESION-TRANSPARENTE.png dist/

# Apply the isolated Shift4 period-import correction to the built app bundle.
# The dashboard hunk is superseded by the normalization step below. Allow only
# that single stale hunk, or the three previously known stale hunks.
patch_log=$(mktemp)
if patch --batch --forward -p1 -d dist < shift4-period.patch >"$patch_log" 2>&1; then
  cat "$patch_log"
else
  cat "$patch_log"
  one_known_failure=0
  if grep -Eiq '1 out of 31 hunks failed' "$patch_log" && grep -Fq 'Hunk #1 FAILED at 330' "$patch_log"; then
    one_known_failure=1
  fi
  three_known_failures=0
  if grep -Eiq '3 out of 31 hunks failed' "$patch_log"; then
    three_known_failures=1
  fi
  if [ "$one_known_failure" -ne 1 ] && [ "$three_known_failures" -ne 1 ]; then
    rm -f "$patch_log" dist/app.js.rej
    exit 1
  fi
  echo "Continuing with known stale dashboard hunk(s); dashboard calculations are normalized below."
  rm -f dist/app.js.rej
fi
rm -f "$patch_log"

# Normalize dashboard calculations after the legacy patch. Its hunks can
# partially apply when the source has moved, leaving the template with missing
# variables and an empty dashboard.
python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
dashboard = s.index("function dashboard(){")
start = s.find(" const rangeSales=", dashboard)
if start < 0:
    start = s.find("const rangeSales=", dashboard)
end = s.find(" const invValue=", start)
if end < 0:
    end = s.find("const invValue=", start)
if start < 0 or end < 0:
    raise SystemExit("Could not locate dashboard calculation boundaries.")
replacement = """ const rangeSales=(state.sales||[]).filter(inSelectedRange),rangePurchases=(state.purchases||[]).filter(inSelectedRange),rangeSaleDetails=rangeSales.map(x=>saleDetail(x)),saleDetailByRecord=new Map(rangeSales.map((x,i)=>[x,rangeSaleDetails[i]]));
 const rangeDre=(state.dreRecords||[]).filter(inSelectedRange),dreMetrics=rangeDre.filter(x=>x.dreMetric),dreGross=dreMetrics.filter(x=>x.dreMetric==='grossSales').reduce((n,x)=>n+Number(x.amount||0),0),dreCogs=dreMetrics.filter(x=>x.dreMetric==='cogs').reduce((n,x)=>n+Number(x.amount||0),0),hasDreSales=dreMetrics.some(x=>x.dreMetric==='grossSales'),hasDreCogs=dreMetrics.some(x=>x.dreMetric==='cogs');
 const channelFeeRecords=rangeDre.filter(x=>x.type==='expense'&&(x.importSource==='UBER_EATS_CSV'||String(x.importSource||'').startsWith('CHANNEL_CSV:'))),channelFees=channelFeeRecords.reduce((n,x)=>n+Number(x.amount||0),0);
 const sales=hasDreSales?dreGross-channelFees:rangeSaleDetails.reduce((n,x)=>n+Number(x.net||0),0)-channelFees,posCogs=hasDreCogs?dreCogs:rangeSaleDetails.reduce((n,x)=>n+Number(x.cost||0),0),grossProfit=sales-posCogs,grossMargin=sales?grossProfit/sales*100:0,costIncompleteSales=hasDreCogs?[]:rangeSales.filter((x,i)=>rangeSaleDetails[i]?.missing?.length&&!(Number(x.cost)>0)),costComplete=costIncompleteSales.length===0;
 const dreExpenses=rangeDre.filter(x=>x.type==='expense'),dreIncome=rangeDre.filter(x=>x.type==='income'),expenseTotal=dreExpenses.reduce((n,x)=>n+Number(x.amount||0),0),incomeTotal=dreIncome.reduce((n,x)=>n+Number(x.amount||0),0),operatingExpenses=expenseTotal-channelFees,operatingResult=costComplete?grossProfit-operatingExpenses+incomeTotal:null;
 const purchases=rangePurchases.reduce((n,x)=>n+Number(x.total||0),0);
 """
s = s[:start] + replacement + s[end:]
food = s.find(" const fcTarget=", dashboard)
if food < 0:
    food = s.find("const fcTarget=", dashboard)
food_end = s.find(";", food)
if food < 0 or food_end < 0:
    raise SystemExit("Could not locate Food Cost calculation.")
s = s[:food] + " const fcTarget=Number(state.settings.targetFoodCost||30),actualFoodCost=sales&&costComplete?posCogs/sales*100:null" + s[food_end:]
p.write_text(s)
print("Normalized dashboard calculations after partial patch application.")
# Reject the malformed dashboard KPI quote sequence that previously stopped
# the browser from parsing the entire app bundle.
bad = "costIncompleteSales.length+' ventas,'green'"
good = "costIncompleteSales.length+' ventas','green'"
if bad in s:
    raise SystemExit("Dashboard KPI JavaScript is malformed after patching.")
PY

# app.js contains an obsolete service-worker update path. It competes with the
# versioned updater in index.html, which can make clients switch workers and reload.
python3 - <<'PY'
from pathlib import Path
import re
p = Path("dist/app.js")
s = p.read_text()
s, first = re.subn(
    r"if\(['\"]serviceWorker['\"]\s*in navigator\)\{navigator\.serviceWorker\.register\(.*?\.catch\(\(\)=>\{\}\)\}",
    "",
    s,
)
s, second = re.subn(
    r"if\(['\"]serviceWorker['\"]\s+in navigator\)setTimeout\(\(\)=>navigator\.serviceWorker\.register\(.*?\),1500\);",
    "",
    s,
)
if "serviceWorker.register" in s:
    raise SystemExit(f"Legacy service-worker registration remains after cleanup (removed {first + second})")
p.write_text(s)
print(f"Removed {first + second} legacy service worker registrations from app.js")
PY
mkdir -p dist/assets
cp -R assets/utensils dist/assets/

python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
needle = "function updateLanguageChip(){"
bridge = "const __lrxBaseApplyEnglishUI=applyEnglishUI;const __lrxRawText=new WeakMap();const __lrxRenderedText=new WeakMap();const __lrxRawAttrs=new WeakMap();const __lrxRenderedAttrs=new WeakMap();let __lrxTranslateLookup=new Map();let __lrxPhraseRegex=null;const __lrxBuildTranslationIndex=()=>{__lrxTranslateLookup=new Map(Object.entries(UI_EN).map(([k,v])=>[k.toLocaleLowerCase(),v]));const keys=Object.keys(UI_EN).filter(k=>k.length>=4&&/^[A-Za-zÀ-ÖØ-öø-ÿ0-9 ]+$/.test(k)).sort((a,b)=>b.length-a.length);__lrxPhraseRegex=keys.length?new RegExp('(^|[^A-Za-zÀ-ÖØ-öø-ÿ0-9])('+keys.join('|')+')(?=$|[^A-Za-zÀ-ÖØ-öø-ÿ0-9])','gi'):null};__lrxBuildTranslationIndex();const __lrxTranslateValue=value=>{if(typeof value!=='string'||state.settings?.language!=='en')return value;let out=UI_EN[value]??__lrxTranslateLookup.get(value.toLocaleLowerCase())??value;const monthNames={Enero:'January',Febrero:'February',Marzo:'March',Abril:'April',Mayo:'May',Junio:'June',Julio:'July',Agosto:'August',Septiembre:'September',Octubre:'October',Noviembre:'November',Diciembre:'December'};for(const [es,en] of Object.entries(monthNames))out=out.replace(new RegExp('(^|[^A-Za-zÀ-ÖØ-öø-ÿ])'+es+'(?=$|[^A-Za-zÀ-ÖØ-öø-ÿ])','g'),(m,p)=>p+en);out=out.replace(/\\bMostrando\\b/g,'Showing').replace(/\\bPágina\\b/g,'Page').replace(/\\bde (\\d+) records/g,'of $1 records').replace(/\\bde (\\d+) resultados/g,'of $1 results').replace(/\\bregistros\\b/g,'records').replace(/\\bfichas\\b/g,'records').replace(/\\bmovimientos\\b/g,'transactions').replace(/\\bcompras\\b/g,'purchases').replace(/\\bgastos\\b/g,'expenses').replace(/\\bingresos\\b/g,'income').replace(/\\bórdenes\\b/gi,'orders').replace(/\\bord enes\\b/gi,'orders');out=out.replace(/^(January|February|March|April|May|June|July|August|September|October|November|December) De (\\d{4})$/,'$1 $2').replace(/^Gastos generales: (.+?) \\(([\\d.]+)% de los gastos DRE\\)\\. Revisa factura, consumo y alternativas\\.$/,'General expenses: $1 ($2% of P&L expenses). Review the invoice, usage, and alternatives.').replace(/^Hay gastos en el período actual, pero no en el período anterior \\((.+?)\\)\\. Aún no se puede calcular si subieron o bajaron\\.$/,'There are expenses in the current period but none in the previous period ($1). It is not yet possible to determine whether they increased or decreased.').replace(/^Período comparable anterior \\((.+?)\\): (.+?) · Variación de gastos: (.+)$/,'Previous comparable period ($1): $2 · Expense change: $3').replace(/^Empleados activos (\\d+) Producciones en período (\\d+) Productos bajo mínimo (\\d+) Aumentos de costo sobre umbral (\\d+) Ingresos manuales DRE (.+)$/,'Active employees $1 · Production runs during period $2 · Products below minimum $3 · Cost increases over threshold $4 · Manual P&L income $5').replace(/^MASTER: (\\d+) Productos · (\\d+) Proveedores · (\\d+) Recetas · (\\d+) Pre-elaborados$/,'MASTER: $1 Products · $2 Suppliers · $3 Recipes · $4 Pre-prepared items').replace('Ventas Totales: ','Total Sales: ').replace('Compras de Alimentos: ','Food Purchases: ').replace('Margen Bruto: ','Gross Margin: ').replace('Resultado Operativo: ','Operating Profit: ').replace('Cuentas por Pagar: ','Accounts Payable: ').replace('Inventario: ','Inventory: ').replace('Empleados: ','Employees: ').replace('Abrir módulo','Open module').replace('utilidad bruta · costo POS','gross profit · POS cost').replace('Productos ·','Products ·').replace('Proveedores ·','Suppliers ·').replace('Recetas ·','Recipes ·').replace('Pre-elaborados','Pre-prepared items');out=out.split('DATOS DEL PERÍODO').join('PERIOD DATA').split('DATOS DEL PERIODO').join('PERIOD DATA').split('Gastos generales: ').join('General expenses: ').split(' de los gastos DRE). Revisa factura, consumo y alternativas.').join(' of P&L expenses). Review the invoice, usage, and alternatives.').split('Hay gastos en el período actual, pero no en el período anterior (').join('There are expenses in the current period but none in the previous period (').split('). Aún no se puede calcular si subieron o bajaron.').join('). It is not yet possible to determine whether they increased or decreased.').split('Período comparable anterior (').join('Previous comparable period (').split(' · Variación de gastos:').join(' · Expense change:').split('El período activo es ').join('The active period is ').split('Septiembre').join('September').split('Agosto').join('August').split('Julio').join('July').split('Junio').join('June').split('Mayo').join('May').split('Abril').join('April').split('Marzo').join('March').split('Febrero').join('February').split('Enero').join('January').split(' De 2026').join(' 2026').split('Abrir DRE').join('Open P&L').split('Ver reportes').join('View reports').split('Revisar DRE').join('Review P&L').split('Aún no se puede calcular').join('It is not yet possible to calculate').split('Revisa factura').join('Review the invoice').split('Cotiza proveedores alternos').join('Request quotes from alternative suppliers').split('aumento(s) sobre el umbral; el mayor es').join('increase(s) above the threshold; the largest is').split('Usa estas categorías').join('Use these categories').split('para revisar contratos, facturas, consumo y recurrencias.').join('to review contracts, invoices, usage, and recurring costs.').split('Consulta los movimientos del DRE dentro de cada mes.').join('Review P&L transactions within each month.').split('Los gastos generales').join('General expenses').split('El promedio divide el total del rango').join('The average divides the range total');out=out.split('Lectura ejecutiva ·').join('Executive summary ·').split('Oportunidades y alertas').join('Opportunities and alerts').split('Food Cost real').join('Actual food cost').split('Food Cost promedio').join('Average food cost').split('recetas ').join('recipes ').split(' completas · teórico').join(' complete · theoretical').split('Empleados activos ').join('Active employees ').split('Producciones en período ').join('Production runs during period ').split('Productos bajo mínimo ').join('Products below minimum ').split('Aumentos de costo sobre umbral ').join('Cost increases above threshold ').split('Ingresos manuales DRE ').join('Manual P&L income ').split('Septiembre De ').join('September ').split('Agosto De ').join('August ').split('Julio De ').join('July ').split('Junio De ').join('June ').split('Mayo De ').join('May ').split('Abril De ').join('April ').split('Marzo De ').join('March ').split('Febrero De ').join('February ').split('Enero De ').join('January ');out=out.split('recetas').join('recipes').split('completas').join('complete').split('teórico').join('theoretical').split('Empleados activos').join('Active employees').split('Producciones en período').join('Production runs during period').split('Productos bajo mínimo').join('Products below minimum').split('Aumentos de costo sobre umbral').join('Cost increases above threshold').split('Ingresos manuales DRE').join('Manual P&L income').split('registros').join('records').split('fichas').join('records').split('Septiembre').join('September').split('Agosto').join('August').split('Julio').join('July').split('Junio').join('June').split('Mayo').join('May').split('Abril').join('April').split('Marzo').join('March').split('Febrero').join('February').split('Enero').join('January').split(' De 2026').join(' 2026');out=out.replace(/Mostrando (\\d+[–-]\\d+) de (\\d+) · Página (\\d+) de (\\d+)/g,'Showing $1 of $2 · Page $3 of $4');if(out.includes('Mostrando ')){out=out.replace('Mostrando ','Showing ').replace(' de ',' of ').replace(' · Página ',' · Page ')}if(out.includes(' turnos · ')&&out.includes(' empleados')){for(const [es,en] of Object.entries(monthNames))out=out.split(es+' De ').join(en+' ');out=out.split(' turnos · ').join(' shifts · ').split(' empleados').join(' employees')}if(out.includes('Highest-cost day:'))out=out.replace(' oct ',' Oct ').replace('Día de menor costo con jornadas:','Lowest-cost day with shifts:');;if(out.includes(' · Page ')||out.includes(' · Página '))out=out.split('Mostrando ').join('Showing ').split(' · Página ').join(' · Page ').split(' de ').join(' of ');const __lrxMonthYear=out.split(' De ');if(__lrxMonthYear.length===2){const __lrxYear=__lrxMonthYear[1].slice(0,4);if(__lrxYear.length===4&&!isNaN(Number(__lrxYear))&&(__lrxMonthYear[1].length===4||__lrxMonthYear[1][4]===' '))out=(monthNames[__lrxMonthYear[0]]||__lrxMonthYear[0])+' '+__lrxYear+__lrxMonthYear[1].slice(4)}out=out.split(' de los expenses DRE').join(' of P&L expenses').split('consumo y alternativas').join('usage and alternatives').split('Variación de expenses').join('Expense change').split('Consulta los transactions del DRE dentro de cada mes.').join('Review P&L transactions within each month.').split('Abrir mes').join('Open month').split('Por página').join('Per page');if(out.includes('Highest-cost day:'))out=out.split('Día de menor costo con jornadas:').join('Lowest-cost day with shifts:').split(' oct ').join(' Oct ');if(out.endsWith(' estimado'))out=out.slice(0,-9)+' estimated';;if(out.startsWith('Showing ')&&out.includes(' de '))out=out.replace(' de ',' of ');out=out.split(' resultados · página ').join(' results · page ').split(' páginas de ').join(' pages of ').split('Actualizado ').join('Updated ').split('Todos (').join('All (').split('Con fotos (').join('With photos (').split(' unidad disponibles').join(' units available').split(' unidad ').join(' unit ').split(' unidades').join(' units').split(' mov. ').join(' transactions ').split('Hay expenses en el período actual, pero no en el período anterior').join('There are expenses in the current period but none in the previous period').split('Abrir mes').join('Open month').split('Abrir Recetas').join('Open Recipes').split('Costo pendiente').join('Cost pending').split('Mostrar el selector de fechas').join('Show date picker');;return out};applyEnglishUI=function(){const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;while(node=walker.nextNode())if(!__lrxRawText.has(node))__lrxRawText.set(node,node.nodeValue||'');__lrxBaseApplyEnglishUI();const textWalker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);while(node=textWalker.nextNode()){const current=node.nodeValue||'',last=__lrxRenderedText.get(node);if(last!==undefined&&current!==last)__lrxRawText.set(node,current);const raw=__lrxRawText.get(node)||'',next=__lrxTranslateValue(raw);if(current!==next)node.nodeValue=next;__lrxRenderedText.set(node,next)}document.querySelectorAll('[aria-label],[title],[placeholder],[data-label]').forEach(el=>{let raw=__lrxRawAttrs.get(el);if(!raw){raw={};__lrxRawAttrs.set(el,raw)}let rendered=__lrxRenderedAttrs.get(el);if(!rendered){rendered={};__lrxRenderedAttrs.set(el,rendered)}for(const attr of ['aria-label','title','placeholder','data-label']){const current=el.getAttribute(attr);if(current===null)continue;if(rendered[attr]!==undefined&&current!==rendered[attr])raw[attr]=current;else if(raw[attr]===undefined)raw[attr]=current;const next=__lrxTranslateValue(raw[attr]);if(current!==next)el.setAttribute(attr,next);rendered[attr]=next}})};window.extendLRXEnglishDictionary=extra=>{Object.assign(UI_EN,extra||{});for(const [key,value] of Object.entries(extra||{})){try{const repaired=decodeURIComponent(escape(key));if(repaired!==key)UI_EN[repaired]=value}catch{}}__lrxBuildTranslationIndex();applyEnglishUI()};let __lrxTranslationTimer=0;const __lrxTranslationObserver=new MutationObserver(()=>{if(state.settings?.language!=='en')return;clearTimeout(__lrxTranslationTimer);__lrxTranslationTimer=setTimeout(()=>applyEnglishUI(),180)});__lrxTranslationObserver.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['aria-label','title','placeholder','data-label']});function updateLanguageChip(){"
if "window.extendLRXEnglishDictionary" not in s:
    if needle not in s:
        raise SystemExit("Could not find language UI insertion point")
    s = s.replace(needle, bridge, 1)
    s = s.replace("const _lrxPreviewDreImport=previewDreImport;\npreviewDreImport=async function(file){", "const _lrxPreviewDreImport=typeof previewDreImport==='function'?previewDreImport:null;\nif(_lrxPreviewDreImport)previewDreImport=async function(file){")
    p.write_text(s)
PY

# Render the application before performing optional image normalization.
python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
changes = [
    ("const APP_VERSION='v556';", "const APP_VERSION='v571';"),
    ("master.json?v=2026-11-13-persist-recovery-v4", "master.json?v=2026-11-18-shopping-sync-v1"),
    ("seedRecipeUtensils();await normalizeUserUtensilImages();try{repairUnappliedPurchaseReceipts();reconcileInventoryFromPurchases()}catch(e){console.warn('LRX startup purchase reconciliation',e)}", "seedRecipeUtensils();setTimeout(async()=>{try{await normalizeUserUtensilImages();repairUnappliedPurchaseReceipts();reconcileInventoryFromPurchases();render()}catch(error){console.warn('LRX deferred startup maintenance',error)}},0);"),
    ("async function init(){try{await persistentStateReady;", "async function init(){const startupContent=document.getElementById('content');if(startupContent)startupContent.innerHTML='<div class=card><h2>Abriendo La Reyna Xpress…</h2><p>Cargando los datos del restaurante.</p></div>';try{await persistentStateReady;"),
]
for old, new in changes:
    if s.count(old) != 1:
        raise SystemExit(f"Expected one occurrence in dist/app.js: {old}")
    s = s.replace(old, new, 1)
p.write_text(s)
PY

# Force all clients and installed PWAs onto the fresh app shell and sync client.
python3 - <<'PY'
from pathlib import Path
index = Path("dist/index.html")
html = index.read_text()
replacements = {
    "app.js?v=2026-11-21-shift4-range-v2": "app.js?v=2026-11-22-doordash-productmix-v14",
    "cloudflare-sync.js?v=2026-11-21-shift4-range-v2": "cloudflare-sync.js?v=2026-11-22-doordash-productmix-v14",
}
for old, new in replacements.items():
    if html.count(old) != 1:
        raise SystemExit(f"Expected one asset URL in index.html: {old}")
    html = html.replace(old, new, 1)
index.write_text(html)
sw = Path("dist/sw.js")
worker = sw.read_text()
if "2026-11-21-shift4-range-v2" not in worker:
    raise SystemExit("Expected service worker version was not found.")
worker = worker.replace("2026-11-21-shift4-range-v2", "2026-11-22-doordash-productmix-v14")
old = "'/purchase-engine.js','/master.json'"
if old not in worker:
    raise SystemExit("Could not update critical service worker assets.")
worker = worker.replace(old, "'/purchase-engine.js','/cloudflare-sync.js','/master.json'", 1)
sw.write_text(worker)
PY

# When no date range is saved on this device, default to the current calendar year.
python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
for old, new in (("'2025-01-01'", "`${new Date().getFullYear()}-01-01`"), ("'2025-12-31'", "`${new Date().getFullYear()}-12-31`")):
    if old not in s:
        raise SystemExit(f"Expected fallback date {old} was not found.")
    s = s.replace(old, new)
p.write_text(s)
print("Set the default date range to the current calendar year.")
PY

# Show DRE supplier purchases in the financial summary without creating
# inventory receipts or accounts-payable purchase records.
python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
old = " const purchases=rangePurchases.reduce((n,x)=>n+Number(x.total||0),0);"
new = " const dreSupplierPurchases=(state.dreRecords||[]).filter(x=>x.type==='expense'&&['Compras a proveedores','Otros proveedores'].includes(String(x.category||'').trim())&&dreSupplierInRange(x,rangeFrom,rangeTo)),hasDreSupplierPurchases=dreSupplierPurchases.length>0,purchases=hasDreSupplierPurchases?dreSupplierPurchases.reduce((n,x)=>n+Number(x.amount||0),0):rangePurchases.reduce((n,x)=>n+Number(x.total||0),0);"
if s.count(old) != 1:
    raise SystemExit("Could not locate dashboard purchase calculation.")
s = s.replace(old, new, 1)
old = "['♨','Compras de Alimentos',money0(purchases),'Compras registradas en el período','orange']"
new = "['♨',hasDreSupplierPurchases?'Compras DRE':'Compras de Alimentos',money0(purchases),hasDreSupplierPurchases?'DRE · agrupadas por proveedor':'Compras registradas en el período','orange']"
if s.count(old) != 1:
    raise SystemExit("Could not locate dashboard purchase card.")
s = s.replace(old, new, 1)
needle = "function purchases(){"
helper = r'''function dreSupplierInRange(row,from,to){const period=String(row?.importPeriod||'');if(/^\d{4}-\d{2}$/.test(period)){const start=period+'-01',[year,month]=period.split('-').map(Number),end=new Date(year,month,0).toISOString().slice(0,10);return start<=to&&end>=from}const date=String(row?.date||row?.createdAt||'').slice(0,10);return Boolean(date&&date>=from&&date<=to)}
function dreSupplierPurchaseSummary(){
 const range=state.settings?.dateRange||{},year=new Date().getFullYear(),from=range.from||`${year}-01-01`,to=range.to||`${year}-12-31`,months=['Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Sep','Oct','Nov','Dic'],groups=new Map();
 for(const row of state.dreRecords||[]){const date=String(row.date||'').slice(0,10),category=String(row.category||'').trim(),supplier=String(row.description||'').trim();if(row.type!=='expense'||!['Compras a proveedores','Otros proveedores'].includes(category)||!dreSupplierInRange(row,from,to)||!supplier)continue;const key=supplier.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();let group=groups.get(key);if(!group){group={supplier,total:0,count:0,months:new Map()};groups.set(key,group)}const amount=Number(row.amount||0),month=date.slice(0,7);group.total+=amount;group.count++;group.months.set(month,(group.months.get(month)||0)+amount)}
 const rows=[...groups.values()].sort((a,b)=>b.total-a.total);if(!rows.length)return '';
 const body=rows.map(row=>{const monthly=[...row.months.entries()].sort(([a],[b])=>a.localeCompare(b)).map(([period,amount])=>{const m=Number(period.slice(5,7))-1,y=period.slice(0,4);return `${months[m]} ${y}: ${money(amount)}`}).join(' · ');return `<tr><td><b>${esc(row.supplier)}</b></td><td>${esc(monthly)}</td><td>${row.count}</td><td><b>${money(row.total)}</b></td></tr>`}).join('');
 return `<section class="card" style="margin-top:14px"><h3>Resumen financiero del DRE · compras por proveedor</h3><p class="muted">Montos agrupados desde las categorías de proveedores del DRE para el rango seleccionado. Solo informativo; no crea facturas, cuentas por pagar ni movimientos de inventario.</p><div class="tablewrap"><table><thead><tr><th>Proveedor / concepto</th><th>Detalle mensual</th><th>Registros</th><th>Total del rango</th></tr></thead><tbody>${body}</tbody><tfoot><tr><th colspan="3">Total DRE por proveedores</th><th>${money(rows.reduce((sum,row)=>sum+row.total,0))}</th></tr></tfoot></table></div></section>`
}
'''
if s.count(needle)!=1:
    raise SystemExit("Could not locate purchases module renderer.")
s=s.replace(needle,helper+needle,1)
old = "<div class=\"grid\"><div class=\"card kpi\"><small>Compras</small><strong>${rows.length}</strong></div><div class=\"card kpi\"><small>Valor comprado</small><strong>${money(total)}</strong></div><div class=\"card kpi\"><small>Por pagar</small><strong>${money(payable)}</strong></div><div class=\"card kpi\"><small>Recibidas</small><strong>${received}</strong></div></div><div class=\"card\" style=\"margin-top:14px\"><div class=\"toolbar\">"
new = "<div class=\"grid\"><div class=\"card kpi\"><small>Compras</small><strong>${rows.length}</strong></div><div class=\"card kpi\"><small>Valor comprado</small><strong>${money(total)}</strong></div><div class=\"card kpi\"><small>Por pagar</small><strong>${money(payable)}</strong></div><div class=\"card kpi\"><small>Recibidas</small><strong>${received}</strong></div></div>${dreSupplierPurchaseSummary()}<div class=\"card\" style=\"margin-top:14px\"><div class=\"toolbar\">"
if s.count(old)!=1:
    raise SystemExit("Could not insert the DRE supplier summary in the purchases module.")
s=s.replace(old,new,1)
p.write_text(s)
print("Added DRE supplier purchase totals to dashboard and Purchases financial summary.")
PY

# Read CSV reports directly so Spanish UTF-8 headers do not depend on XLSX autodetection.
python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
start = s.index("function parseShift4ProductMix(file,buffer){")
end = s.index("function shift4SalesImportModal(){", start)
replacement = r'''async function parseShift4ProductMix(file,buffer){
 const csv=/\.csv$/i.test(String(file?.name||''));let sheets=[];
 if(csv){let text=new TextDecoder('utf-8').decode(buffer);if(text.includes('�'))text=new TextDecoder('windows-1252').decode(buffer);text=text.replace(/^\uFEFF/,'');const first=text.split(/\r?\n/,1)[0],delimiters=[',',';','\t'],delimiter=delimiters.sort((a,b)=>first.split(b).length-first.split(a).length)[0],rows=[];let row=[],field='',quoted=false;for(let i=0;i<text.length;i++){const ch=text[i];if(quoted){if(ch==='"'&&text[i+1]==='"'){field+='"';i++}else if(ch==='"')quoted=false;else field+=ch}else if(ch==='"')quoted=true;else if(ch===delimiter){row.push(field);field=''}else if(ch==='\n'){row.push(field);rows.push(row);row=[];field=''}else if(ch!=='\r')field+=ch}if(field.length||row.length){row.push(field);rows.push(row)}sheets=[{name:String(file.name||'Product Mix').replace(/\.csv$/i,''),rows}];}
 else{if(!window.XLSX)return {error:'No se cargó el lector de Excel. Recarga la app e inténtalo otra vez.'};const wb=XLSX.read(buffer,{type:'array',cellDates:true});sheets=wb.SheetNames.map(name=>({name,rows:XLSX.utils.sheet_to_json(wb.Sheets[name],{header:1,raw:false,defval:''})}))}
 const normHeader=value=>String(value||'').trim().toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/\s+/g,' ');let found=null,seenHeaders=[];
 for(const sheet of sheets){for(let ri=0;ri<sheet.rows.length;ri++){const h=sheet.rows[ri].map(normHeader);if(ri===0)seenHeaders=h;const item=h.findIndex(x=>['item','product','product name','menu item','nombre del articulo','articulo'].includes(x)||x.includes('nombre del art')),gross=h.findIndex(x=>x.includes('gross sales')||x==='ventas brutas'||x==='venta bruta'),qty=h.findIndex(x=>x==='quantity'||x==='qty'||x==='total vendido'||x==='total sold');if(item>=0&&gross>=0&&qty>=0){found={name:sheet.name,rows:sheet.rows,ri,item,gross,qty,net:h.findIndex(x=>x.includes('net sales')||x==='ventas netas'),discount:h.findIndex(x=>x.includes('discount')||x.includes('descuento')),tax:h.findIndex(x=>x.includes('inclusive tax')||x.includes('impuesto incluido'))};break}}if(found)break}
 if(!found)return {error:`No reconocí las columnas del Product Mix. Encabezados detectados: ${seenHeaders.filter(Boolean).slice(0,20).join(' · ')||'ninguno'}. Se necesitan artículo, ventas brutas y cantidad.`};
 const parsePeriod=txt=>{const text=String(txt||''),m=text.match(/(?:period|periodo|período)\s*:?\s*(\d{4}-\d{1,2}-\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})(?:\s*(?:to|through|a|hasta|–|—|-)\s*(\d{4}-\d{1,2}-\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}))?/i);if(!m)return null;return {start:shift4DateValue(m[1]),end:shift4DateValue(m[2]||m[1])}};let period=null,periodSource='';for(const row of found.rows.slice(0,found.ri)){period=parsePeriod(row.map(x=>String(x||'')).join(' '));if(period?.start){periodSource='período del archivo';break}}if(!period?.start){const filename=String(file.name||''),range=filename.match(/(\d{4}-\d{2}-\d{2})_(\d{4}-\d{2}-\d{2})/i)||filename.match(/(\d{4}-\d{2}-\d{2})_to_(\d{4}-\d{2}-\d{2})/i),m=range||filename.match(/(\d{4}-\d{2}-\d{2})/);if(m){period={start:shift4DateValue(m[1]),end:shift4DateValue(m[2]||m[1])};periodSource='nombre del archivo'}}
 const products=[];for(const row of found.rows.slice(found.ri+1)){const name=String(row[found.item]||'').trim();if(!name||/^total\b/i.test(name))continue;const qty=shift4Num(row[found.qty]),gross=shift4Num(row[found.gross]);if(qty<=0)continue;const net=found.net>=0?shift4Num(row[found.net]):gross-(found.discount>=0?shift4Num(row[found.discount]):0);products.push({name,qty,gross,net,tax:found.tax>=0?shift4Num(row[found.tax]):0})}if(!products.length)return {error:'Encontré el reporte, pero no contiene artículos vendidos con cantidad.'};return {date:period?.start||'',dateSource:periodSource,periodStart:period?.start||'',periodEnd:period?.end||period?.start||'',periodSource,products,sheet:found.name}
}
'''
s=s[:start]+replacement+s[end:]
p.write_text(s)
print("Replaced Shift4 CSV handling with direct UTF-8 parsing and header diagnostics.")
PY


# Connect the asynchronous CSV reader to the DoorDash Product Mix import dialog.
python3 - <<'PYCODE'
from pathlib import Path
p=Path("dist/app.js")
s=p.read_text()
old="const parsed=parseShift4ProductMix(file,await file.arrayBuffer());"
new="const parsed=await parseShift4ProductMix(file,await file.arrayBuffer());"
if s.count(old)!=1: raise SystemExit("Could not wire the async Product Mix parser to the import dialog.")
s=s.replace(old,new,1)
for old,new in (
 ("Importar ventas Shift4 por período","Importar ventas Shift4 por período"),
 ("Importar Product Mix Shift4","Importar Shift4"),
 ("Reporte Product Mix de Shift4 (.xlsx, .xls o .csv)","Reporte Product Mix de Shift4 (.xlsx, .xls o .csv)"),
 ("Artículo Shift4","Artículo Shift4"),
 ("Selecciona primero el reporte Product Mix de Shift4","Selecciona primero el reporte Product Mix de Shift4"),
 (" registro(s) Shift4 importado(s)."," registro(s) Shift4 importado(s)."),
 ("Reporte Shift4 · ${items.length} productos","Reporte Shift4 · ${items.length} productos"),
 ("No pude leer este archivo. Selecciona el reporte Product Mix de Shift4 en Excel o CSV.","No pude leer este archivo. Selecciona el reporte Product Mix de Shift4 en Excel o CSV."),
 ("price:qty?gross/qty:0,channel:'Shift4',commission:0","price:qty?gross/qty:0,channel:'Shift4',commission:0"),
):

 if s.count(old)!=1: raise SystemExit(f"Could not update DoorDash import text or channel: {old}")
 s=s.replace(old,new,1)
p.write_text(s)
print("Connected async Shift4 Product Mix parser.")
PYCODE


# Recognize Spanish DoorDash Product Mix headers in the generic channel importer.
python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
changes = (
    ("<h3>Importar archivo · ${esc(channel)}</h3>", "<h3>Importar archivo · ${esc(String(channel).toLowerCase()==='doordash'?'Product Mix DoorDash':channel)}</h3>"),
    ("product:['nombredearticulo','articulo'", "product:['nombredelarticulo','nombredearticulo','articulo'"),
    ("qty:['cantidad','quantity','qty','units','itemsold']", "qty:['cantidad','quantity','qty','totalvendido','units','itemsold']"),
    ("sales:['ventassinimpuestos','grosssales'", "sales:['ventasbrutas','ventassinimpuestos','grosssales'"),
)
for old, new in changes:
    if s.count(old) != 1:
        raise SystemExit(f"Could not apply DoorDash generic-import change: {old}")
    s = s.replace(old, new, 1)
p.write_text(s)
print("Enabled Product Mix DoorDash headers in the generic channel importer.")
PY


# Group alternate names for the same sales platform and deduplicate matching item sales.
python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
def once(old, new, label):
    global s
    if s.count(old) != 1:
        raise SystemExit(f"Could not apply channel grouping change: {label} (found {s.count(old)})")
    s = s.replace(old, new, 1)
def twice(old,new,label):
    global s
    if s.count(old) != 2:
        raise SystemExit(f"Could not apply channel grouping change: {label} (found {s.count(old)})")
    s = s.replace(old,new)
once("function genericChannelColumnKey(value){return uberHeaderKey(value)}","function canonicalSalesChannelName(value){const raw=String(value||'').trim(),key=uberHeaderKey(raw).replace(/^productmix/,'');if(['shift4','salon','takeout','pickup','pos'].includes(key))return 'Shift4';if(['uber','ubereats'].includes(key))return 'Uber Eats';if(key==='doordash')return 'DoorDash';if(key==='grubhub')return 'Grubhub';return raw}function genericChannelColumnKey(value){return uberHeaderKey(value)}","canonical channel helper")
once("function genericChannelImportModal(channel){window._channelImportDraft=","function genericChannelImportModal(channel){channel=canonicalSalesChannelName(channel);window._channelImportDraft=","channel import normalization")
# genericChannelFingerprint is normalized in the complete channelImportDedupe replacement below.
# Cross-import dedupe is replaced below with item-level fingerprinting.
once("return {...s,gross,discountAmt,commissionPct,commission,card,fixedFee,net,cost,profit:net-cost,missing:[...new Set(missing)],margin:net?(net-cost)/net*100:0,foodCost:net?cost/net*100:0};","return {...s,channel:canonicalSalesChannelName(s.channel),gross,discountAmt,commissionPct,commission,card,fixedFee,net,cost,profit:net-cost,missing:[...new Set(missing)],margin:net?(net-cost)/net*100:0,foodCost:net?cost/net*100:0};","canonical sales report channel")
twice("channel:sale.channel||'Sin canal',date});","channel:canonicalSalesChannelName(sale.channel||'Sin canal'),date});","canonical menu engineering channel")
p.write_text(s)
print("Grouped platform aliases and deduplicated matching item-level imports.")
PY


# Route marketplace Product Mix files to Menu Engineering, not POS/DRE revenue.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js")
s=p.read_text()
def once(old,new,label):
    global s
    if s.count(old)!=1: raise SystemExit(f"Could not apply Product Mix routing: {label} ({s.count(old)} matches)")
    s=s.replace(old,new,1)
old=",'sales','promotions',"
if s.count(old)!=2: raise SystemExit(f"Could not register Product Mix state ({s.count(old)} matches)")
s=s.replace(old,",'sales','productMixReports','promotions',")
once(
    "const mapping={};for(const [k,tests] of Object.entries(aliases))mapping[k]=choose(headers,tests);const filenameDates=",
    "const mapping={};for(const [k,tests] of Object.entries(aliases))mapping[k]=choose(headers,tests);const headerKeys=headers.map(genericChannelColumnKey),isProductMix=/product[\\s_-]*mix/i.test(String(file.name||''))||(['nombredelarticulo','totalvendido','ventasbrutas'].every(k=>headerKeys.includes(k)));const filenameDates=",
    "Product Mix report detection")
once("window._channelImportDraft={channel,grid,headerRow,headers,fileName:file.name,mapping};","window._channelImportDraft={channel,grid,headerRow,headers,fileName:file.name,mapping,kind:isProductMix?'product-mix':'channel-sales'};","store import type")
once("renderChannelImportPreview()}catch(e){showError(e)}}}","document.getElementById('confirmChannelImport').textContent=isProductMix?'Importar Product Mix':'Importar ventas';renderChannelImportPreview()}catch(e){showError(e)}}}","import action label")
once("No se descuenta inventario.</p>","No se descuenta inventario.</p>\${p.kind==='product-mix'?'<p class=\\\"muted\\\"><b>Product Mix:</b> se usará en Menu Engineering; no suma ventas financieras ni descuenta inventario.</p>':''}","Product Mix preview notice")
start=s.index("function channelImportDedupe(rows){")
end=s.index("function renderChannelImportPreview()",start)
dedupe="""function channelImportDedupe(rows){const p=window._channelImportDraft,channel=canonicalSalesChannelName(p?.channel),existing=p?.kind==='product-mix'?(state.productMixReports||[]).filter(r=>canonicalSalesChannelName(r.channel)===channel).flatMap(r=>(r.products||[]).map(item=>genericChannelFingerprint({channel:r.channel,periodStart:r.periodStart,periodEnd:r.periodEnd,product:item.product,qty:item.qty,sales:item.gross}))):(state.sales||[]).filter(s=>canonicalSalesChannelName(s.channel)===channel).flatMap(s=>{const items=Array.isArray(s.items)&&s.items.length?s.items:[{product:s.product,qty:s.qty||1,price:s.price||0}];return items.map(item=>{const qty=Number(item.qty||1),sales=Number(item.price||s.price||0)*qty;return genericChannelFingerprint({channel:canonicalSalesChannelName(s.channel),date:s.date,periodStart:s.periodStart||s.date,periodEnd:s.periodEnd||s.date,product:item.product||s.product,qty,sales})})}),existingCounts=new Map(),seenCounts=new Map();for(const key of existing)existingCounts.set(key,(existingCounts.get(key)||0)+1);return rows.map(x=>{const fingerprint=genericChannelFingerprint({...x,channel}),seen=(seenCounts.get(fingerprint)||0)+1;seenCounts.set(fingerprint,seen);return {...x,fingerprint,duplicate:seen<=(existingCounts.get(fingerprint)||0)}})}\n"""
s=s[:start]+dedupe+s[end:]
once(
    "function confirmChannelImport(){const p=window._channelImportDraft,allRows=channelImportDedupe(channelImportRows()),rows=allRows.filter(x=>!x.duplicate),skipped=allRows.length-rows.length,from=document.getElementById('channelImportFrom')?.value||'',to=document.getElementById('channelImportTo')?.value||'',channel=String(p?.channel||'').trim();if(!rows.length)return toast('No hay líneas nuevas para importar; las filas duplicadas se omitieron.');if(!channel)return toast('Selecciona el canal del archivo');const source=",
    "function confirmChannelImport(){const p=window._channelImportDraft,allRows=channelImportDedupe(channelImportRows()),rows=allRows.filter(x=>!x.duplicate),skipped=allRows.length-rows.length,from=document.getElementById('channelImportFrom')?.value||'',to=document.getElementById('channelImportTo')?.value||'',channel=canonicalSalesChannelName(p?.channel);if(!rows.length)return toast('No hay líneas nuevas para importar; las filas duplicadas se omitieron.');if(!channel)return toast('Selecciona el canal del archivo');if(p?.kind==='product-mix'){const snapshot=JSON.stringify(state),discountCol=(p.headers||[]).findIndex(h=>['descuentos','discounts','discount'].includes(genericChannelColumnKey(h))),products=rows.map(x=>{const row=p.grid[p.headerRow+x.index]||[],discount=discountCol>=0?Math.abs(uberMoney(row[discountCol])):0;return {product:x.product,qty:Number(x.qty||0),gross:Number(x.sales||0),discount,net:Number(x.sales||0)-discount}});state.productMixReports=state.productMixReports||[];state.productMixReports.push({id:'PM-'+uberHeaderKey(channel)+'-'+from+'-'+to+'-'+Date.now(),channel,periodStart:from,periodEnd:to,fileName:p.fileName,importedAt:now(),products});audit('PRODUCT_MIX_IMPORT',channel+' · '+from+' a '+to+' · '+products.length+' productos para Menu Engineering');if(!save()){restoreStateSnapshot(snapshot);return}window._channelImportDraft=null;close();render();return toast(products.length+' productos de Product Mix guardados en Menu Engineering; ventas financieras sin cambio.')}const source=",
    "Product Mix routing branch")
start=s.index("function menuEngineeringSales(from='',to=''){")
end=s.index("function rentability(){",start)
part=s[start:end]
def part_once(old,new,label):
    global part
    if part.count(old)!=1: raise SystemExit(f"Could not update Menu Engineering: {label} ({part.count(old)} matches)")
    part=part.replace(old,new,1)
part_once(
    "const out=[],recipes=allRecipes(),products=menuCatalogProducts(),unlinked=new Map(),excludedSummaries=[],platformFees=new Map();let pending=0;",
    "const out=[],recipes=allRecipes(),products=menuCatalogProducts(),mixReports=state.productMixReports||[],unlinked=new Map(),excludedSummaries=[],platformFees=new Map();let pending=0;",
    "report list")
part_once(
    " for(const sale of state.sales||[]){\n  if(['CANCELADA','DEVUELTA']",
    " for(const sale of state.sales||[]){\n  const saleDate=String(sale.date||sale.createdAt||'').slice(0,10);if(String(sale.importSource||'').startsWith('CHANNEL_CSV:')&&mixReports.some(r=>canonicalSalesChannelName(r.channel)===canonicalSalesChannelName(sale.channel)&&saleDate>=String(r.periodStart||'')&&saleDate<=String(r.periodEnd||'')))continue;\n  if(['CANCELADA','DEVUELTA']",
    "skip duplicate channel menu sales")
part_once(
    " return {items:out,pending,unlinked:[...unlinked.values()].sort((a,b)=>b.gross-a.gross),excludedSummaries};",
    " for(const report of mixReports){const rs=String(report.periodStart||''),re=String(report.periodEnd||'');if(!inRange(rs,re)){const overlaps=Boolean(rs&&re&&rs<=String(to||'9999-12-31').slice(0,10)&&re>=String(from||'0000-01-01').slice(0,10));if(overlaps)excludedSummaries.push({start:rs,end:re,saleId:report.id});continue}for(const item of report.products||[]){const recipe=menuRecipeMatch(item.product,recipes),product=recipe?null:menuProductMatch(item.product,products);if(!recipe&&!saleableMenuProduct(product)){pending++;const name=String(item.product||'Artículo sin nombre').trim(),key=menuRecipeKey(name)||name.toLowerCase(),entry=unlinked.get(key)||{name,qty:0,gross:0,rows:0};entry.qty+=Number(item.qty||1);entry.gross+=Number(item.gross||0);entry.rows++;unlinked.set(key,entry);continue}const qty=Number(item.qty||1),gross=Number(item.gross||0),net=Number(item.net??gross);if(product){const unitCost=Number(product.finalCost||product.usableCost||product.cost||0),cost=unitCost*qty;out.push({product:product.name||item.product,productId:product.id,qty,gross,net,cost,unitCost,profit:net-cost,costComplete:unitCost>0,costMissing:[],costIssue:unitCost>0?'':'Falta costo de compra registrado',channel:canonicalSalesChannelName(report.channel),date:re});continue}const costDetail=menuEngineeringRecipeCost(recipe),unitCost=costDetail.unitCost,cost=unitCost*qty;out.push({product:recipe.name,recipeId:recipe.id,qty,gross,net,cost,unitCost,profit:net-cost,costComplete:costDetail.complete,costMissing:costDetail.detail.missing||[],costIssue:costDetail.issue,channel:canonicalSalesChannelName(report.channel),date:re})}}\n return {items:out,pending,unlinked:[...unlinked.values()].sort((a,b)=>b.gross-a.gross),excludedSummaries};",
    "add report details")
s=s[:start]+part+s[end:]
p.write_text(s)
print("Separated marketplace Product Mix from financial sales and linked it to Menu Engineering.")
PY


# Keep the selected channel name in the generic importer and render its Product Mix notice.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js")
s=p.read_text()
old="String(channel).toLowerCase()==='doordash'?'Product Mix DoorDash':channel"
if s.count(old)!=1: raise SystemExit("Could not restore the DoorDash channel heading.")
s=s.replace(old,"channel",1)
old=chr(92)+chr(36)+"{p.kind"
if s.count(old)!=1: raise SystemExit("Could not fix the Product Mix preview notice.")
s=s.replace(old,chr(36)+"{p.kind",1)
p.write_text(s)
print("Kept DoorDash as the selected channel and enabled the Product Mix preview notice.")
PY

 
# Merge channel cards and financial charges using the canonical platform name.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js")
s=p.read_text()
old=r"channelKey=value=>String(value||'Sin canal').normalize('NFD').replace(/[\u0300-\u036f]/g,'').trim().toLowerCase()"
new="channelKey=value=>canonicalSalesChannelName(value||'Sin canal')"
if s.count(old)!=1:
    raise SystemExit(f"Could not normalize the channel summary key ({s.count(old)} matches)")
s=s.replace(old,new,1)
old="const channels=state.settings.channels||[],configured=new Set(channels.map(c=>channelKey(c.name))),channelCards=[...channels,...[...channelStats.values()].filter(x=>!configured.has(channelKey(x.name))).map(x=>({name:x.name,type:'Importado',active:true}))],q=String(state._salesQ||'').toLowerCase(),grouped=new Map(),display=[];"
new="const channels=state.settings.channels||[],configured=new Set(channels.map(c=>channelKey(c.name))),channelCards=[...new Map(channels.map(c=>{const name=canonicalSalesChannelName(c.name);return [channelKey(name),{...c,name}]})).values(),...[...channelStats.values()].filter(x=>!configured.has(channelKey(x.name))).map(x=>({...x,name:canonicalSalesChannelName(x.name),type:'Importado',active:true}))],q=String(state._salesQ||'').toLowerCase(),grouped=new Map(),display=[];"
if s.count(old)!=1:
    raise SystemExit(f"Could not collapse duplicate channel cards ({s.count(old)} matches)")
s=s.replace(old,new,1)
p.write_text(s)
print("Grouped channel sales and imported fees under one canonical platform card.")
PY

# Bust the production browser and service-worker caches for channel aggregation.
python3 - <<'PY'
from pathlib import Path
tag = "2026-11-22-channel-rollup-v1"
index = Path("dist/index.html")
html = index.read_text()
old = "2026-11-22-doordash-productmix-v14"
for asset in ("app.js", "cloudflare-sync.js"):
    before = f"{asset}?v={old}"
    after = f"{asset}?v={tag}"
    if html.count(before) != 1:
        raise SystemExit(f"Expected one production URL for {asset}; found {html.count(before)}")
    html = html.replace(before, after, 1)
index.write_text(html)
worker = Path("dist/sw.js")
sw = worker.read_text()
if sw.count(old) != 1:
    raise SystemExit(f"Expected one service worker cache version; found {sw.count(old)}")
worker.write_text(sw.replace(old, tag, 1))
PY
