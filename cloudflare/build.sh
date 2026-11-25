#!/usr/bin/env bash
set -euo pipefail

rm -rf dist
mkdir -p dist
cp index.html styles.css app.js purchase-engine.js catalog-controls.js cloudflare-sync.js ui-translation-extra.js recipe-price-mobile.js sw.js master.json manifest.webmanifest hero-food.jpg hero-bar.jpg LRX-LOGO-PLANTILLAS.png LRX-LOGO-IMPRESION-TRANSPARENTE.png dist/

# The current production app already contains the migrated modules. The legacy
# patch pipeline below targets an older app.js and aborts on newer source.
if grep -Fq "const APP_VERSION='v584';" dist/app.js \
  && grep -Fq 'function repairDuplicateDreImports(state)' dist/cloudflare-sync.js \
  && grep -Fq '2026-11-24-prod-tax-yield-dedupe-v21' dist/index.html \
  && grep -Fq '2026-11-24-prod-tax-yield-dedupe-v21' dist/sw.js; then
  mkdir -p dist/assets
  cp -R assets/utensils dist/assets/
  echo "Built the current production source directly; skipped obsolete migration patches."
  exit 0
fi

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
    ("const APP_VERSION='v556';", "const APP_VERSION='v578';"),
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
    "app.js?v=2026-11-21-shift4-range-v2": "app.js?v=2026-11-24-tax-sale-report-v6",
    "cloudflare-sync.js?v=2026-11-21-shift4-range-v2": "cloudflare-sync.js?v=2026-11-24-tax-sale-report-v6",
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
worker = worker.replace("2026-11-21-shift4-range-v2", "2026-11-24-tax-sale-report-v6")
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
old = "2026-11-24-tax-sale-report-v6"
for asset in ("app.js", "cloudflare-sync.js"):
    before = f"{asset}?v={old}"
    after = f"{asset}?v={tag}"
    if html.count(before) != 1:
        raise SystemExit(f"Expected one production URL for {asset}; found {html.count(before)}")
    html = html.replace(before, after, 1)
index.write_text(html)
worker = Path("dist/sw.js")
sw = worker.read_text()
count = sw.count(old)
if count < 1:
    raise SystemExit("Expected service worker cache version was not found.")
worker.write_text(sw.replace(old, tag))
PY



# Compact multi-month sales reports and restore real product drill-down.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text();tick=chr(96)
helper=r"""function isSyntheticSalesProduct(value){return /^(?:venta owner(?:\s+\d{4}-\d{2}-\d{2})?|orden(?:es)? de owner|reporte(?: diario)? shift4|resumen(?: diario)? shift4)\b/i.test(String(value||'').trim())}"""+"\n"
marker="function sales(){"
if s.count(marker)!=1: raise SystemExit("Could not locate POS sales renderer.")
if "function isSyntheticSalesProduct(" not in s:s=s.replace(marker,helper+marker,1)
old="else{group.items.push(...(Array.isArray(r.items)&&r.items.length?r.items:[{product:r.product,qty:r.qty,price:r.price}]));group.qty+=Number(r.qty||0);group.shift4Tax+=Number(r.shift4Tax||0)}"
new="else{const sourceItems=Array.isArray(r.items)&&r.items.length?r.items:(r.product&&!isSyntheticSalesProduct(r.product)?[{product:r.product,qty:r.qty,price:r.price}]:[]);group.items.push(...sourceItems.filter(x=>!isSyntheticSalesProduct(x.product||x.name)));group.qty+=Number(r.qty||0);group.shift4Tax+=Number(r.shift4Tax||0)}"
if s.count(old)!=1: raise SystemExit("Could not safely filter placeholder products.")
s=s.replace(old,new,1)
a=s.find(" const periodSummaryPanel=");b=s.find("\n const monthlyOverview=",a)
if a<0 or b<0: raise SystemExit("Could not locate multi-month report panel.")
period_block=""" const periodSummaryPanel=periodSummaries.length?""" + tick + """<details class="card sales-period-summary" style="margin-top:14px"><summary>Reportes de varios meses · ${periodSummaries.length} · ${money(periodSummaries.reduce((n,r)=>n+Number(r.net||0),0))}</summary><p class="muted">Los totales abarcan el rango completo y no se distribuyen entre meses. Expande un reporte para ver sus artículos.</p><div class="catalog-results">${periodSummaries.map(r=>{const products=(r.items||[]).filter(x=>!isSyntheticSalesProduct(x.product||x.name));return """ + tick + """<article class="catalog-card"><div class="catalog-title"><span class="status">SHIFT4 · PERÍODO</span><h3>${esc(salePeriodLabel(r))}</h3></div><div class="catalog-grid"><div><small>Productos</small><b>${products.length?products.length+' artículos':'Sin detalle de artículos'}</b></div><div><small>Venta neta del período</small><b>${money(r.net)}</b></div></div><div class="catalog-actions"><button class="btn primary" data-action="view-sale" data-id="${esc(r.id)}">${products.length?'Ver productos':'Ver detalle del total'}</button></div></article>""" + tick + """}).join('')}</div></details>""" + tick + ":'';"
s=s[:a]+period_block+s[b:]
d=s.find(" const dailyMonthView=")
if d<0 or s.count(" const dailyMonthView=")!=1: raise SystemExit("Could not locate month detail view.")
products=""" const monthProductTotals=new Map();for(const sale of monthRows){if(sale.ownerDaySummary||sale.importSource==='OWNER_ORDERS_CSV')continue;const source=Array.isArray(sale.items)?sale.items:(sale.product&&!isSyntheticSalesProduct(sale.product)?[{product:sale.product,qty:sale.qty,price:sale.price}]:[]);for(const item of source){const name=String(item.product||item.name||'').trim();if(!name||isSyntheticSalesProduct(name))continue;const key=String(item.productId||name).toLowerCase(),row=monthProductTotals.get(key)||{name,qty:0,gross:0},qty=Number(item.qty||1);row.qty+=qty;row.gross+=Number(item.gross??(item.price*qty)??0);monthProductTotals.set(key,row)}}const monthProductRows=[...monthProductTotals.values()].sort((a,b)=>b.gross-a.gross),monthlyProductsPanel='<details class="sales-month-products"><summary>Productos del mes · '+monthProductRows.length+' productos</summary>'+(monthProductRows.length?'<div class="tablewrap"><table><thead><tr><th>Producto</th><th>Cantidad</th><th>Venta de productos</th></tr></thead><tbody>'+monthProductRows.map(x=>'<tr><td>'+esc(x.name)+'</td><td>'+x.qty+'</td><td>'+money(x.gross)+'</td></tr>').join('')+'</tbody></table></div>':'<p class="muted">Los registros de este mes no incluyen líneas de productos. Aquí no se inventan artículos a partir del monto total.</p>')+'</details>';
"""
s=s[:d]+products+s[d:]
month_marker='</div></div><div class="toolbar"><input id="salesQ"'
if s.count(month_marker)!=1: raise SystemExit("Could not place monthly product summary.")
s=s.replace(month_marker,'</div></div>${monthlyProductsPanel}<div class="toolbar"><input id="salesQ"',1)
modal_marker="function saleViewModal(id){";modal_start=s.find(modal_marker)
if modal_start<0 or s.count(modal_marker)!=1: raise SystemExit("Could not locate product modal.")
fallback=""" if(!s){const match=String(id).match(/^SHIFT4-(\\d{4}-\\d{2}-\\d{2})-(\\d{4}-\\d{2}-\\d{2})$/);if(match){const start=match[1],end=match[2],rows=(state.sales||[]).filter(x=>isShift4DailyLine(x)&&salePeriodBounds(x).start===start&&salePeriodBounds(x).end===end);if(rows.length){const ds=rows.map(x=>saleDetail(x)),items=rows.flatMap(x=>Array.isArray(x.items)?x.items:(x.product&&!isSyntheticSalesProduct(x.product)?[{product:x.product,qty:x.qty,price:x.price}]:[])).filter(x=>!isSyntheticSalesProduct(x.product||x.name));s={id,date:start,periodStart:start,periodEnd:end,periodSummary:true,product:""" + tick + """Reporte Shift4 · ${items.length} artículos""" + tick + """,channel:'Shift4',status:'COMPLETADA',qty:items.reduce((n,x)=>n+Number(x.qty||0),0),items,salesGrossOverride:ds.reduce((n,x)=>n+x.gross,0),salesDiscountOverride:ds.reduce((n,x)=>n+x.discountAmt,0),salesNetOverride:ds.reduce((n,x)=>n+x.net,0),cost:ds.reduce((n,x)=>n+x.cost,0),dailySummary:true,sourceIds:rows.map(x=>x.id)}}}}
"""
nf=" if(!s)return toast('Venta no encontrada');"
if s.count(nf)!=1: raise SystemExit("Could not insert multi-month lookup.")
s=s.replace(nf,fallback+nf,1)
old_items=" const d=saleDetail(s),items=s.items||[],owner=s.importSource==='OWNER_ORDERS_CSV';"
new_items=" const d=saleDetail(s),items=(Array.isArray(s.items)?s.items:(s.product&&!isSyntheticSalesProduct(s.product)?[{product:s.product,qty:s.qty||1,price:s.price||0}]:[])).filter(x=>!isSyntheticSalesProduct(x.product||x.name)),owner=s.importSource==='OWNER_ORDERS_CSV';"
if s.count(old_items)!=1: raise SystemExit("Could not prepare product detail rows.")
s=s.replace(old_items,new_items,1)
branch=":"+tick+'<div class="tablewrap"><table><thead><tr><th>Producto</th>'
if s.count(branch)!=1: raise SystemExit("Could not locate modal product table.")
s=s.replace(branch,":items.length?"+tick+'<div class="tablewrap"><table><thead><tr><th>Producto</th>',1)
table_end="</tbody></table></div>"+tick+";"
detail_start=s.find("const detail=s.ownerDaySummary?",modal_start);detail_end=s.find("\n modal(",detail_start)
detail_block=s[detail_start:detail_end]
if detail_start<0 or detail_end<0 or detail_block.count(table_end)!=1: raise SystemExit("Could not isolate product detail table.")
empty="<p class="+chr(34)+"muted"+chr(34)+">Este archivo solo contiene el total del período; no incluye líneas de productos para mostrar.</p>"
detail_block=detail_block.replace(table_end,"</tbody></table></div>"+tick+":'"+empty+"';",1)
s=s[:detail_start]+detail_block+s[detail_end:]
p.write_text(s);print("Updated sales grouping and product drill-down.")
PY

python3 - <<'PY'
from pathlib import Path
old="2026-11-22-channel-rollup-v1"
new="2026-11-22-sales-month-products-v2"
for name in ("dist/index.html","dist/sw.js"):
 path=Path(name);content=path.read_text()
 if old not in content:raise SystemExit("Expected cache tag missing from "+name)
 path.write_text(content.replace(old,new))
PY

# Make imported multi-month sales visible in monthly summaries without presenting estimates as exact facts.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text()
needle=" const filtered=display.filter(r=>!q||JSON.stringify(r).toLowerCase().includes(q)),years="
group=""" const periodBatchGroups=new Map(),normalizedDisplay=[];for(const r of display){if(isSalesPeriodSummary(r)&&String(r.importSource||'').startsWith('CHANNEL_CSV:')){const {start,end}=salePeriodBounds(r),key=[r.importSource,r.importBatch||r.importFile||r.id,start,end].join('|');let g=periodBatchGroups.get(key);if(!g){g={...r,id:'RANGE-'+key,periodStart:start,periodEnd:end,periodSummary:true,items:[],qty:0,salesGrossOverride:0,salesDiscountOverride:0,salesNetOverride:0,cost:0,sourceIds:[]};periodBatchGroups.set(key,g)}g.items.push(...(Array.isArray(r.items)?r.items:(r.product?[{product:r.product,qty:r.qty,price:r.price}]:[])));g.qty+=Number(r.qty||0);g.salesGrossOverride+=Number(r.gross||0);g.salesDiscountOverride+=Number(r.discountAmt||0);g.salesNetOverride+=Number(r.net||0);g.cost+=Number(r.cost||0);g.sourceIds.push(r.id)}else normalizedDisplay.push(r)}for(const g of periodBatchGroups.values()){g.product='Reporte '+String(g.channel||g.importSource||'ventas')+' · '+g.items.length+' líneas';normalizedDisplay.push(saleDetail(g))}display.splice(0,display.length,...normalizedDisplay);
"""
if s.count(needle)!=1: raise SystemExit("Could not locate monthly sales summary setup.")
s=s.replace(needle,group+needle,1)
sales_start=s.find("function sales(){")
a=s.find("const monthNames=Array.from",sales_start)
b=s.find(";\n const size=",a)
if sales_start<0 or a<0 or b<0: raise SystemExit("Could not locate monthly totals block.")
monthblock="""const monthNames=Array.from({length:12},(_,i)=>new Date(2026,i,15).toLocaleDateString('es-US',{month:'long'})),yearRows=filtered.filter(r=>String(r.date||'').slice(0,4)===year),monthlyTotals=Array.from({length:12},(_,i)=>{const key=`${year}-${String(i+1).padStart(2,'0')}`,monthStart=key+'-01',next=new Date(Number(year),i+1,1),monthEnd=new Date(next.getTime()-86400000).toISOString().slice(0,10),rows=yearRows.filter(r=>!r.periodSummary&&String(r.date||'').slice(0,7)===key),ranges=yearRows.filter(r=>r.periodSummary&&salePeriodBounds(r).start<=monthEnd&&salePeriodBounds(r).end>=monthStart);let estimated=0;for(const r of ranges){const {start,end}=salePeriodBounds(r),from=new Date(Math.max(Date.parse(start+'T12:00:00'),Date.parse(monthStart+'T12:00:00'))),to=new Date(Math.min(Date.parse(end+'T12:00:00'),Date.parse(monthEnd+'T12:00:00')));const overlap=Math.max(0,Math.round((to-from)/86400000)+1),whole=Math.max(1,Math.round((Date.parse(end+'T12:00:00')-Date.parse(start+'T12:00:00'))/86400000)+1);estimated+=Number(r.net||0)*overlap/whole}return {key,count:rows.length,reportCount:ranges.length,net:rows.reduce((a,r)=>a+Number(r.net||0),0)+estimated,estimated}})"""
monthblock=monthblock.replace("__BT__",chr(96)).replace("__DOL__","$")

s=s[:a]+monthblock+s[b:]
old="monthIndex>=0?yearRows.filter(r=>String(r.date||'').slice(0,7)===selectedMonth):[]"
new="monthIndex>=0?yearRows.filter(r=>!r.periodSummary?String(r.date||'').slice(0,7)===selectedMonth:(salePeriodBounds(r).start<=selectedMonth+'-31'&&salePeriodBounds(r).end>=selectedMonth+'-01')):[]"
if s.count(old)==1:s=s.replace(old,new,1)
elif "salePeriodBounds(r)" not in s[s.find("const size=",sales_start):s.find("const dailyCards=",sales_start)]:raise SystemExit("Could not include overlapping period sales in month detail.")
oldtxt="m.count?`${m.count} fichas`: 'Sin ventas registradas'"
newtxt="m.count||m.reportCount?`${m.count?`${m.count} ventas`:''}${m.reportCount?`${m.count?' · ':''}${m.reportCount} reportes de rango`:''}`:'Sin ventas registradas'"
oldtxt=oldtxt.replace("__BT__",chr(96)).replace("__DOL__","$");newtxt=newtxt.replace("__BT__",chr(96)).replace("__DOL__","$")
if s.count(oldtxt)!=1: raise SystemExit("Could not update month card count.")
s=s.replace(oldtxt,newtxt,1)
oldamt="m.count?money(m.net):'—'"
if s.count(oldamt)!=1: raise SystemExit("Could not update month card total.")
s=s.replace(oldamt,"m.count||m.reportCount?money(m.net):'—'",1)
oldhint="Selecciona un mes para ver sus ventas diarias y totales"
if s.count(oldhint)!=1: raise SystemExit("Could not update monthly explanation.")
s=s.replace(oldhint,"Incluye ventas fechadas y una estimación de los reportes que abarcan varios meses.",1)
oldhead="`${monthRows.length} fichas diarias · Neto ${money(monthlyTotals[monthIndex]?.net||0)}`"
newhead="`${monthRows.length} ventas y reportes relacionados · Neto ${money(monthlyTotals[monthIndex]?.net||0)}${monthlyTotals[monthIndex]?.estimated?' · incluye estimación de rangos':''}`"
oldhead=oldhead.replace("__BT__",chr(96)).replace("__DOL__","$");newhead=newhead.replace("__BT__",chr(96)).replace("__DOL__","$")
if s.count(oldhead)==1:s=s.replace(oldhead,newhead,1)
p.write_text(s)
print("Grouped period imports and surfaced them in monthly sales summaries.")
PY

# Keep full-range product detail accessible while avoiding false month-level product attribution.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text()
anchor=" if(!s)return toast('Venta no encontrada');"
if s.count(anchor)!=1:raise SystemExit("Could not locate sale detail modal fallback.")
fallback=""" const rangeParts=String(id||'').startsWith('RANGE-')?String(id).slice(6).split('|'):[];if(!s&&rangeParts.length>=4){const [source,batch,start,end]=rangeParts,rows=(state.sales||[]).filter(x=>x.importSource===source&&(x.importBatch||x.importFile||x.id)===batch&&String(x.periodStart||x.date||'').slice(0,10)===start&&String(x.periodEnd||x.periodStart||x.date||'').slice(0,10)===end);if(rows.length){const ds=rows.map(x=>saleDetail(x)),items=rows.flatMap(x=>Array.isArray(x.items)?x.items:(x.product?[{product:x.product,qty:x.qty,price:x.price}]:[]));s={id,date:start,periodStart:start,periodEnd:end,periodSummary:true,product:'Reporte '+String(rows[0].channel||source)+' · '+items.length+' líneas',channel:rows[0].channel||source,status:'COMPLETADA',qty:items.reduce((n,x)=>n+Number(x.qty||0),0),items,salesGrossOverride:ds.reduce((n,x)=>n+x.gross,0),salesDiscountOverride:ds.reduce((n,x)=>n+x.discountAmt,0),salesNetOverride:ds.reduce((n,x)=>n+x.net,0),cost:ds.reduce((n,x)=>n+x.cost,0),sourceIds:rows.map(x=>x.id)}}}
"""
s=s.replace(anchor,fallback+anchor,1)
old="if(sale.ownerDaySummary||sale.importSource==='OWNER_ORDERS_CSV')continue;"
if s.count(old)!=1:raise SystemExit("Could not isolate month product totals.")
s=s.replace(old,"if(sale.periodSummary||sale.ownerDaySummary||sale.importSource==='OWNER_ORDERS_CSV')continue;",1)
oldmsg="Los registros de este mes no incluyen líneas de productos. Aquí no se inventan artículos a partir del monto total."
newmsg="Los reportes de rango tienen sus artículos dentro del detalle del reporte; el archivo no indica cuánto corresponde a cada mes."
if s.count(oldmsg)!=1:raise SystemExit("Could not update month product explanation.")
s=s.replace(oldmsg,newmsg,1)
p.write_text(s)
print("Connected grouped range report buttons to their underlying item rows.")
PY
python3 - <<'PY'
from pathlib import Path
old="2026-11-22-sales-month-products-v2";new="2026-11-22-sales-month-products-v3"
for name in ("dist/index.html","dist/sw.js"):
 p=Path(name);s=p.read_text()
 if old not in s:raise SystemExit("Missing prior sales cache tag in "+name)
 p.write_text(s.replace(old,new))
PY

# Remove estimated allocation of range totals; show only date-backed monthly revenue.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text();sales_start=s.find("function sales(){")
a=s.find("monthlyTotals=Array.from",sales_start);b=s.find(";\n const size=",a)
if sales_start<0 or a<0 or b<0:raise SystemExit("Could not isolate monthly totals calculation.")
block="""monthlyTotals=Array.from({length:12},(_,i)=>{const key=__BT____DOL__{year}-__DOL__{String(i+1).padStart(2,'0')}__BT__,monthStart=key+'-01',next=new Date(Number(year),i+1,1),monthEnd=new Date(next.getTime()-86400000).toISOString().slice(0,10),rows=yearRows.filter(r=>!r.periodSummary&&String(r.date||'').slice(0,7)===key),ranges=yearRows.filter(r=>r.periodSummary&&salePeriodBounds(r).start<=monthEnd&&salePeriodBounds(r).end>=monthStart);return {key,count:rows.length,reportCount:ranges.length,net:rows.reduce((total,r)=>total+Number(r.net||0),0)}})"""
block=block.replace("__BT__",chr(96)).replace("__DOL__","$")
s=s[:a]+block+s[b:]
old="m.count||m.reportCount?money(m.net):'—'"
new="m.count?money(m.net):m.reportCount?'Ver total del rango':'—'"
if s.count(old)!=1:raise SystemExit("Could not remove estimated amount from month cards.")
s=s.replace(old,new,1)
oldhint="Incluye ventas fechadas y una estimación de los reportes que abarcan varios meses."
newhint="Solo suma ventas fechadas dentro del mes. Los reportes de varios meses aparecen al abrir cada mes, con su total original."
if s.count(oldhint)!=1:raise SystemExit("Could not clarify monthly totals.")
s=s.replace(oldhint,newhint,1)
oldhead="__BT____DOL__{monthRows.length} ventas y reportes relacionados · Neto __DOL__{money(monthlyTotals[monthIndex]?.net||0)}__DOL__{monthlyTotals[monthIndex]?.estimated?' · incluye estimación de rangos':''}__BT__"
newhead="__BT____DOL__{monthlyTotals[monthIndex]?.count||0} ventas con fecha en el mes · Neto __DOL__{money(monthlyTotals[monthIndex]?.net||0)}__DOL__{monthlyTotals[monthIndex]?.reportCount?__BT__ · __DOL__{monthlyTotals[monthIndex].reportCount} reportes de rango conservan su total original__BT__:''}__BT__"
oldhead=oldhead.replace("__BT__",chr(96)).replace("__DOL__","$")
newhead=newhead.replace("__BT__",chr(96)).replace("__DOL__","$")
if s.count(oldhead)==1:s=s.replace(oldhead,newhead,1)
p.write_text(s)
print("Removed estimated month allocations; preserved original range totals.")
PY
python3 - <<'PY'
from pathlib import Path
old="2026-11-22-sales-month-products-v3";new="2026-11-24-tax-sale-report-v6"
for name in ("dist/index.html","dist/sw.js"):
 p=Path(name);s=p.read_text()
 if old not in s:raise SystemExit("Missing prior sales cache tag in "+name)
 p.write_text(s.replace(old,new))
PY

# Group multi-period reports by platform and provide platform filters inside each month.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text();sales_start=s.find("function sales(){")
if sales_start<0:raise SystemExit("Could not locate sales renderer.")
a=s.find("const periodSummaryPanel=",sales_start);b=s.find("\n const monthlyOverview=",a)
if a<0 or b<0:raise SystemExit("Could not locate period summary panel.")
panel="""const periodGroups=new Map();for(const r of periodSummaries){const name=canonicalSalesChannelName(r.channel||r.importSource||'Otros');if(!periodGroups.has(name))periodGroups.set(name,[]);periodGroups.get(name).push(r)}const rangeChannels=[...new Set([...channelCards.map(x=>canonicalSalesChannelName(x.name)),...periodGroups.keys()])];const periodSummaryPanel=periodSummaries.length?__BT__<details class="card sales-period-summary" style="margin-top:14px"><summary>Reportes de varios meses · __DOL__{periodSummaries.length} · __DOL__{money(periodSummaries.reduce((n,r)=>n+Number(r.net||0),0))}</summary><p class="muted">Cada canal queda agrupado. El importe es el total del rango del reporte, no un total mensual.</p><div class="sales-period-channels">__DOL__{rangeChannels.map(name=>{const reports=periodGroups.get(name)||[];return __BT__<details class="sales-period-channel"><summary>__DOL__{esc(name)} · __DOL__{reports.length} reportes__DOL__{reports.length?' · '+money(reports.reduce((n,r)=>n+Number(r.net||0),0)):''}</summary>__DOL__{reports.length?__BT__<div class="catalog-results">__DOL__{reports.map(r=>{const products=(r.items||[]).filter(x=>!isSyntheticSalesProduct(x.product||x.name));return __BT__<article class="catalog-card"><div class="catalog-title"><span class="status">__DOL__{esc(name)} · PERÍODO</span><h3>__DOL__{esc(salePeriodLabel(r))}</h3></div><div class="catalog-grid"><div><small>Productos</small><b>__DOL__{products.length?products.length+' artículos':'Sin detalle de artículos'}</b></div><div><small>Venta neta del período</small><b>__DOL__{money(r.net)}</b></div></div><div class="catalog-actions"><button class="btn primary" data-action="view-sale" data-id="__DOL__{esc(r.id)}">__DOL__{products.length?'Ver productos':'Ver detalle del total'}</button></div></article>__BT__}).join('')}</div>__BT__:__BT__<p class="muted">No hay reportes que abarquen varios meses en este canal. Sus ventas aparecen al abrir un mes.</p>__BT__}</details>__BT__}).join('')}</div></details>__BT__:'';"""
panel=panel.replace("__BT__",chr(96)).replace("__DOL__","$")
s=s[:a]+" "+panel+s[b:]
a=s.find("const size=",sales_start);b=s.find("\n const dailyCards=",a)
if a<0 or b<0:raise SystemExit("Could not locate selected-month rows.")
month="""const size=Math.max(10,Number(state._salesSize||25)),monthRows=monthIndex>=0?yearRows.filter(r=>{const {start,end}=salePeriodBounds(r),monthStart=selectedMonth+'-01',monthEnd=new Date(Number(selectedMonth.slice(0,4)),Number(selectedMonth.slice(5,7)),0).toISOString().slice(0,10);return r.periodSummary||isSalesPeriodSummary(r)?start<=monthEnd&&end>=monthStart:String(r.date||'').slice(0,7)===selectedMonth}):[],selectedChannel=String(state._salesChannel||'all'),channelKeyForView=v=>String(v||'').normalize('NFD').replace(/[\\u0300-\\u036f]/g,'').trim().toLowerCase(),channelRows=selectedChannel==='all'?monthRows:monthRows.filter(r=>channelKeyForView(r.channel)===channelKeyForView(selectedChannel)),channelActualNet=channelRows.filter(r=>!r.periodSummary&&!isSalesPeriodSummary(r)).reduce((n,r)=>n+Number(r.net||0),0),pages=Math.max(1,Math.ceil(channelRows.length/size));state._salesPage=Math.min(Math.max(0,Number(state._salesPage||0)),pages-1);const page=state._salesPage,visible=channelRows.slice(page*size,(page+1)*size).reverse();"""
s=s[:a]+month+s[b:]
needle=" const dailyMonthView="
insert=""" const salesChannelNames=[...new Set([...channelCards.map(x=>canonicalSalesChannelName(x.name)),...monthRows.map(x=>canonicalSalesChannelName(x.channel)).filter(Boolean)])],channelTabs=monthIndex<0?'':__BT__<nav class="sales-channel-tabs" aria-label="Filtrar ventas por canal"><button type="button" class="btn __DOL__{selectedChannel==='all'?'primary':''}" data-action="sales-channel-tab" data-id="all">Todos</button>__DOL__{salesChannelNames.map(name=>__BT__<button type="button" class="btn __DOL__{channelKeyForView(selectedChannel)===channelKeyForView(name)?'primary':''}" data-action="sales-channel-tab" data-id="__DOL__{esc(name)}">__DOL__{esc(name)}</button>__BT__).join('')}</nav>`;"""
insert=insert.replace("__BT__",chr(96)).replace("__DOL__","$")
if s.count(needle)!=1:raise SystemExit("Could not insert channel tabs.")
s=s.replace(needle,insert+needle,1)
d=chr(36);marker=d+'{monthlyProductsPanel}<div class="toolbar"><input id="salesQ"'
if s.count(marker)!=1:raise SystemExit("Could not place monthly channel tabs.")
s=s.replace(marker,d+'{monthlyProductsPanel}'+d+'{channelTabs}<div class="toolbar"><input id="salesQ"',1)
oldhead=d+"{monthRows.length} ventas y reportes relacionados · Neto "+d+"{money(monthlyTotals[monthIndex]?.net||0)}"+d+"{monthlyTotals[monthIndex]?.estimated?' · incluye estimación de rangos':''}"
newhead=d+"{channelRows.length} registros · "+d+"{selectedChannel==='all'?'todos los canales':esc(selectedChannel)} · Neto fechado "+d+"{money(channelActualNet)}"
if s.count(oldhead)==1:s=s.replace(oldhead,newhead,1)
anchor="if(a==='sales-month-open'){state._salesMonth=String(id||'');"
if s.count(anchor)!=1:raise SystemExit("Could not locate month-open handler.")
s=s.replace(anchor,"if(a==='sales-channel-tab'){state._salesChannel=String(id||'all');state._salesPage=0;return render()}if(a==='sales-month-open'){state._salesChannel='all';state._salesMonth=String(id||'');",1)
back="if(a==='sales-month-back'){state._salesMonth='';"
if s.count(back)!=1:raise SystemExit("Could not locate month-back handler.")
s=s.replace(back,"if(a==='sales-month-back'){state._salesChannel='all';state._salesMonth='';",1)
p.write_text(s)
print("Grouped range reports by platform and added monthly channel filters.")
PY

# Refresh a stale prior-year full-year UI selection to the current year.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text()
old="state.settings.dateRange=savedRange}catch(e){console.warn('LRX UI preferences unavailable',e)}"
new=old+";const currentCalendarYear=new Date().getFullYear(),previousCalendarYear=currentCalendarYear-1,activeDateRange=state.settings?.dateRange||{};if(activeDateRange.from===String(previousCalendarYear)+'-01-01'&&activeDateRange.to===String(previousCalendarYear)+'-12-31'){state.settings.dateRange={from:String(currentCalendarYear)+'-01-01',to:String(currentCalendarYear)+'-12-31'};try{localStorage.setItem('lrx_ui_date_range_preference',JSON.stringify(state.settings.dateRange))}catch(e){console.warn('Could not update prior-year date preference',e)}}"
if s.count(old)!=1:raise SystemExit("Could not locate date preference initialization")
p.write_text(s.replace(old,new,1))
print("Moved a stale previous-year full-year view to the current year.")
PY

# Make the dashboard KPIs direct, keyboard-accessible links; reduce repeated full-state cloning when saving.
python3 - <<'PY'
from pathlib import Path
d=chr(36)
app=Path("dist/app.js");s=app.read_text()
old='<article class="approved-kpi-card '+d+'{k[4]}">'
target=d+'{k[1].includes("Ventas")?"ventas":k[1].includes("Compras")||k[1]==="Cuentas por Pagar"?"compras":k[1]==="Food Cost"||k[1]==="Margen Bruto"?"rentabilidad":k[1]==="Resultado Operativo"?"dre":k[1]==="Inventario"?"inventario":k[1]==="Empleados"?"empleados":"reportes"}'
new='<article class="approved-kpi-card '+d+'{k[4]}" data-jump="'+target+'" role="link" tabindex="0" aria-label="Abrir módulo '+d+'{esc(k[1])}">'
if s.count(old)!=1:raise SystemExit("Could not locate dashboard KPI cards")
s=s.replace(old,new,1)
old="const previous=JSON.parse(previousText||'{}'),collections="
new="const previous=previousText&&previousText===syncDeletionBaselineText&&syncDeletionBaseline?syncDeletionBaseline:JSON.parse(previousText||'{}'),collections="
if s.count(old)!=1:raise SystemExit("Could not locate deletion snapshot parse")
s=s.replace(old,new,1)
needle='function recordSyncDeletions(previousText){'
if s.count(needle)!=1:raise SystemExit("Could not locate deletion helper")
s=s.replace(needle,'let syncDeletionBaselineText=null,syncDeletionBaseline=null;\n'+needle,1)
old="const snapshot=window.LRXGetSharedState?.()||state;try{window.LRXCloudSync?.onLocalSave(snapshot)}"
new="const snapshot=JSON.parse(serialized);for(const key of Object.keys(snapshot))if(key.startsWith('_'))delete snapshot[key];if(snapshot.settings&&typeof snapshot.settings==='object'){delete snapshot.settings.language;delete snapshot.settings.dateRange}syncDeletionBaselineText=serialized;syncDeletionBaseline=snapshot;try{window.LRXCloudSync?.onLocalSave(snapshot,true)}"
if s.count(old)!=1:raise SystemExit("Could not locate save snapshot clone")
s=s.replace(old,new,1)
keydown="document.addEventListener('keydown',e=>{const card=e.target.closest?.('.menu-decision-card');"
if s.count(keydown)!=1:raise SystemExit("Could not locate keyboard handler")
s=s.replace(keydown,"document.addEventListener('keydown',e=>{const card=e.target.closest?.('[data-jump][role=link]');if(card&&(e.key==='Enter'||e.key===' ')){e.preventDefault();go(card.dataset.jump)}});\n"+keydown,1)
app.write_text(s)
sync=Path("dist/cloudflare-sync.js");s=sync.read_text()
old="function onLocalSave(value){\n  localMutationSeq++;\n  queuedSnapshot=JSON.parse(JSON.stringify(value));"
new="function onLocalSave(value,immutable=false){\n  localMutationSeq++;\n  queuedSnapshot=immutable?value:JSON.parse(JSON.stringify(value));"
if s.count(old)!=1:raise SystemExit("Could not locate cloud snapshot clone")
sync.write_text(s.replace(old,new,1))
styles=Path("dist/styles.css");styles.write_text(styles.read_text()+"\n.approved-kpi-card[data-jump]{cursor:pointer;transition:transform .15s ease,box-shadow .15s ease}.approved-kpi-card[data-jump]:hover{transform:translateY(-2px);box-shadow:0 7px 18px rgba(16,24,40,.1)}.approved-kpi-card[data-jump]:focus-visible{outline:3px solid #c42f61;outline-offset:2px}\n")
print("Linked dashboard KPI cards and removed redundant full-state cloning on saves.")
PY

# Clarify that POS costing is incomplete on existing sales records, rather than sales being missing.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text();d=chr(36)
replacements=[
(d+"{costIncompleteSales.length} ventas",d+"{costIncompleteSales.length} ventas sin costo completo"),
("Costeo incompleto · "+d+"{money(grossProfit)} parcial",d+"{costIncompleteSales.length} ventas sin receta o costo · parcial "+d+"{money(grossProfit)}"),
("Costea "+d+"{costIncompleteSales.length} ventas","Completa receta/costo en "+d+"{costIncompleteSales.length} ventas"),
("Falta costear "+d+"{costIncompleteSales.length} ventas","Completa receta/costo en "+d+"{costIncompleteSales.length} ventas"),
("Falta costo en "+d+"{costIncompleteSales.length} ventas","Sin receta o costo en "+d+"{costIncompleteSales.length} ventas"),
]
total=0
for old,new in replacements:
 n=s.count(old)
 if n:s=s.replace(old,new);total+=n
if not total:raise SystemExit("No pending-cost labels were found")
p.write_text(s)
print("Clarified POS cost incompleteness in "+str(total)+" labels.")
PY


# Manual ticket taxes and charges, employee report, and channel fixed-fee mode.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text()
old='<div class="field"><label>Cargo fijo por orden</label><input id="chFixed"'
new='<div class="field"><label>Cálculo del cargo por orden</label><select id="chFixedMode"><option value="amount" ${r?.fixedFeeMode!==\'percent\'?\'selected\':\'\'}>Monto fijo ($)</option><option value="percent" ${r?.fixedFeeMode===\'percent\'?\'selected\':\'\'}>Porcentaje (%)</option></select></div><div class="field"><label>Cargo por orden</label><input id="chFixed"'
if s.count(old)!=1: raise SystemExit("Channel fixed fee field changed.")
s=s.replace(old,new,1)
needle="function deleteChannel(name){"
wrapper="""const __lrxSaveChannelBase=saveChannel;saveChannel=function(oldName=''){const mode=document.getElementById('chFixedMode')?.value||'amount',old=(state.settings.channels||[]).find(c=>String(c.name)===String(oldName)),used=(state.sales||[]).some(x=>String(x.channel||'').toLowerCase()===String(oldName).toLowerCase());if(used&&old&&String(old.fixedFeeMode||'amount')!==mode)return toast('No cambies el tipo de cargo de un canal con ventas históricas. Crea un canal nuevo para órdenes futuras.');const name=document.getElementById('chName')?.value?.trim()||oldName;__lrxSaveChannelBase(oldName);const c=(state.settings.channels||[]).find(x=>String(x.name)===String(name));if(c){c.fixedFeeMode=mode;save()}};"""
if s.count(needle)!=1: raise SystemExit("Channel save wrapper anchor changed.")
s=s.replace(needle,wrapper+needle,1)
helpers="""function saleExtraChargeRow(row={}){const em=state.employees||[];return '<div class="formgrid sale-extra-charge" style="padding:10px;border:1px solid var(--line);border-radius:10px;margin:8px 0"><div class="field"><label>Concepto</label><input data-charge-label value="'+esc(row.label||'')+'" placeholder="Ej. To-go y contenedores"></div><div class="field"><label>Tipo</label><select data-charge-kind><option value="surcharge" '+(row.kind==='surcharge'?'selected':'')+'>Cargo adicional</option><option value="tip" '+(row.kind==='tip'?'selected':'')+'>Tip</option><option value="gratuity" '+(row.kind==='gratuity'?'selected':'')+'>Gratuity</option></select></div><div class="field"><label>Cálculo</label><select data-charge-mode><option value="amount" '+(row.mode!=='percent'?'selected':'')+'>Monto ($)</option><option value="percent" '+(row.mode==='percent'?'selected':'')+'>Porcentaje (%)</option></select></div><div class="field"><label>Monto / porcentaje</label><input data-charge-value type="number" min="0" step=".01" value="'+Number(row.value||0)+'"></div><div class="field"><label>Empleado (opcional)</label><select data-charge-employee><option value="">— Sin asignar —</option>'+em.map(e=>'<option value="'+esc(e.id||e.name)+'" '+(String(row.employeeId||'')===String(e.id||e.name)?'selected':'')+'>'+esc(e.name||e.fullName||e.id)+'</option>').join('')+'</select></div><div class="field"><label>&nbsp;</label><button type="button" class="btn danger" data-action="sale-charge-remove">Quitar</button></div></div>'}
function readSaleExtraCharges(){return [...document.querySelectorAll('.sale-extra-charge')].map(r=>({label:r.querySelector('[data-charge-label]')?.value.trim()||'',kind:r.querySelector('[data-charge-kind]')?.value||'surcharge',mode:r.querySelector('[data-charge-mode]')?.value||'amount',value:Number(r.querySelector('[data-charge-value]')?.value||0),employeeId:r.querySelector('[data-charge-employee]')?.value||''})).filter(x=>x.label&&x.value>0)}
function saleChargeAmount(x,base){return Math.round((x.mode==='percent'?base*Number(x.value||0)/100:Number(x.value||0))*100)/100}
const __lrxSaleModalBase=saleModal;saleModal=function(existing=null){__lrxSaleModalBase(existing);const box=document.getElementById('salePreview');if(!box)return;const cs=Array.isArray(existing?.additionalCharges)?existing.additionalCharges:[];box.insertAdjacentHTML('beforebegin','<div class="field full card" style="margin:10px 0"><h4>Impuesto y cargos del ticket</h4><div class="formgrid"><div class="field"><label>Impuesto</label><select id="saleTaxMode"><option value="amount" '+(existing?.customerTaxMode!=='percent'?'selected':'')+'>Monto exacto ($)</option><option value="percent" '+(existing?.customerTaxMode==='percent'?'selected':'')+'>Porcentaje (%)</option></select></div><div class="field"><label>Monto / porcentaje de impuesto</label><input id="saleTaxValue" type="number" min="0" step=".01" value="'+Number(existing?.customerTaxValue??existing?.customerTaxAmount??0)+'"></div></div><p class="muted">Calculado sobre comida después del descuento. El impuesto queda separado de ventas netas.</p><label>Cargos adicionales: tips, gratuity, to-go, contenedores, etc.</label><div id="saleExtraCharges">'+(cs.length?cs.map(saleExtraChargeRow).join(''):saleExtraChargeRow())+'</div><button type="button" class="btn" id="addSaleExtraCharge">＋ Agregar renglón de cargo</button><p class="muted">Cada renglón puede ser monto o porcentaje y asignarse a un empleado.</p></div>');document.getElementById('addSaleExtraCharge')?.addEventListener('click',()=>{document.getElementById('saleExtraCharges')?.insertAdjacentHTML('beforeend',saleExtraChargeRow());previewSale()});document.getElementById('saleExtraCharges')?.addEventListener('click',e=>{if(e.target.closest('[data-action="sale-charge-remove"]')){e.target.closest('.sale-extra-charge')?.remove();previewSale()}});document.querySelectorAll('#saleTaxMode,#saleTaxValue,.sale-extra-charge input,.sale-extra-charge select').forEach(x=>x.addEventListener('input',previewSale));document.querySelectorAll('#saleTaxMode').forEach(x=>x.addEventListener('change',previewSale));previewSale()};
const __lrxPreviewSaleBase=previewSale;previewSale=function(){__lrxPreviewSaleBase();const box=document.getElementById('salePreview');if(!box)return;const items=readSaleItems(),gross=items.reduce((n,x)=>n+x.price*x.qty,0),disc=Math.min(100,Number(document.getElementById('saleDiscount')?.value||0)),base=gross*(1-disc/100),tax=saleChargeAmount({mode:document.getElementById('saleTaxMode')?.value||'amount',value:Number(document.getElementById('saleTaxValue')?.value||0)},base),add=readSaleExtraCharges().reduce((n,x)=>n+saleChargeAmount(x,base),0);box.insertAdjacentHTML('beforeend','<div>Impuesto <b>'+money(tax)+'</b> · Cargos <b>'+money(add)+'</b> · Total ticket <b>'+money(base+tax+add)+'</b></div>')};
const __lrxSaveSaleBase=saveSale;saveSale=function(existingId=''){const tm=document.getElementById('saleTaxMode')?.value||'amount',tv=Number(document.getElementById('saleTaxValue')?.value||0),charges=readSaleExtraCharges(),items=readSaleItems(),gross=items.reduce((n,x)=>n+x.price*x.qty,0),discount=Math.min(100,Number(document.getElementById('saleDiscount')?.value||0)),base=gross*(1-discount/100);if(!Number.isFinite(tv)||tv<0||charges.some(x=>!Number.isFinite(x.value)||x.value<0))return toast('Revisa impuesto y cargos adicionales');const ids=new Set((state.sales||[]).map(x=>String(x.id)));__lrxSaveSaleBase(existingId);const sale=existingId?(state.sales||[]).find(x=>String(x.id)===String(existingId)):(state.sales||[]).find(x=>!ids.has(String(x.id)));if(!sale)return;const ch=(state.settings.channels||[]).find(c=>String(c.name)===String(sale.channel||'')),fee=Number(ch?.fixedFee||0);sale.fixedFee=ch?.fixedFeeMode==='percent'?Math.round(base*fee)/100:fee;const tax=saleChargeAmount({mode:tm,value:tv},base);sale.customerTaxMode=tm;sale.customerTaxValue=tv;sale.customerTaxAmount=tax;sale.additionalCharges=charges.map(x=>{const e=(state.employees||[]).find(y=>String(y.id||y.name)===String(x.employeeId));return {...x,amount:saleChargeAmount(x,base),employeeName:e?.name||e?.fullName||''}});sale.ticketTotal=Math.round((base+tax+sale.additionalCharges.reduce((n,x)=>n+Number(x.amount||0),0))*100)/100;sale.updatedAt=now();if(!save())return toast('No se pudieron guardar impuesto y cargos.');render()};
const __lrxSaleDetailBase=saleDetail;saleDetail=function(x,recipes){const z=__lrxSaleDetailBase(x,recipes),charges=Array.isArray(x?.additionalCharges)?x.additionalCharges:[],tax=Number(x?.customerTaxAmount||0),add=charges.reduce((n,c)=>n+Number(c.amount||0),0),ticketTotal=Number(x?.ticketTotal||Math.max(0,Number(z.gross||0)-Number(z.discountAmt||0))+tax+add),out={...z,tax,additionalCharges:charges,chargeTotal:add,ticketTotal};if(x?.salesNetOverride==null){const ch=(state.settings.channels||[]).find(c=>String(c.name||'').toLowerCase()===String(x?.channel||'').toLowerCase());if(ch?.fixedFeeMode==='percent'&&x?.fixedFee==null){const f=Math.round((Number(z.gross||0)-Number(z.discountAmt||0))*Number(ch.fixedFee||0))/100;out.fixedFee=f;out.net=Number(z.net||0)+Number(ch.fixedFee||0)-f;out.profit=out.net-Number(z.cost||0)}}return out};
function employeeSalesChargeReport(){const from=state._hrChargeFrom||new Date().toISOString().slice(0,8)+'01',to=state._hrChargeTo||new Date().toISOString().slice(0,10),rows=(state.sales||[]).filter(x=>String(x.date||'')>=from&&String(x.date||'')<=to&&!['CANCELADA','DEVUELTA'].includes(String(x.status||'').toUpperCase())).flatMap(x=>(x.additionalCharges||[]).filter(c=>c.employeeId).map(c=>({employeeId:c.employeeId,employee:c.employeeName||c.employeeId,kind:c.kind,amount:Number(c.amount||0)}))),g=new Map();rows.forEach(x=>{if(!g.has(x.employeeId))g.set(x.employeeId,{employee:x.employee,tips:0,gratuity:0,charges:0,total:0,count:0});const y=g.get(x.employeeId);if(x.kind==='tip')y.tips+=x.amount;else if(x.kind==='gratuity')y.gratuity+=x.amount;else y.charges+=x.amount;y.total+=x.amount;y.count++});return '<div class="card" style="margin-top:14px"><h3>Tips, gratuity y cargos asignados por empleado</h3><p class="muted">Ventas manuales dentro del período; el impuesto no se suma a pagos al personal.</p><div class="toolbar"><label>Desde <input type="date" id="hrChargeFrom" value="'+esc(from)+'"></label><label>Hasta <input type="date" id="hrChargeTo" value="'+esc(to)+'"></label><button class="btn" data-action="employee-sales-charges-export">Exportar reporte</button></div><div class="tablewrap"><table><thead><tr><th>Empleado</th><th>Tips</th><th>Gratuity</th><th>Otros cargos</th><th>Total asignado</th><th>Registros</th></tr></thead><tbody>'+[...g.values()].sort((a,b)=>a.employee.localeCompare(b.employee)).map(x=>'<tr><td>'+esc(x.employee)+'</td><td>'+money(x.tips)+'</td><td>'+money(x.gratuity)+'</td><td>'+money(x.charges)+'</td><td><b>'+money(x.total)+'</b></td><td>'+x.count+'</td></tr>').join('')+(g.size?'':'<tr><td colspan="6" class="empty">Sin cargos asignados en este período.</td></tr>')+'</tbody></table></div></div>'}
function employeeSalesChargesExport(){const from=state._hrChargeFrom||new Date().toISOString().slice(0,8)+'01',to=state._hrChargeTo||new Date().toISOString().slice(0,10),rows=(state.sales||[]).filter(x=>String(x.date||'')>=from&&String(x.date||'')<=to).flatMap(x=>(x.additionalCharges||[]).filter(c=>c.employeeId).map(c=>({fecha:x.date,venta:x.id,empleado:c.employeeName||c.employeeId,tipo:c.kind,concepto:c.label,monto:c.amount})));if(!rows.length)return toast('No hay cargos asignados para exportar.');exportExcel(rows,'tips_gratuity_cargos_empleados')}
"""
needle="function saleModal(existing=null){"
if s.count(needle)!=1: raise SystemExit("Sales modal definition anchor missing.")
s=s.replace(needle,helpers+"\n"+needle,1)
anchor="+employeeLaborReport()+employeeTimecardHistory()+"
if s.count(anchor)!=1: raise SystemExit("Employee report insertion point changed.")
s=s.replace(anchor,"+employeeLaborReport()+employeeSalesChargeReport()+employeeTimecardHistory()+",1)
anchor="if(a==='employee-timecards-import')return employeeTimecardChooseFile();"
if s.count(anchor)!=1: raise SystemExit("Employee action dispatcher changed.")
s=s.replace(anchor,"if(a==='employee-sales-charges-export')return employeeSalesChargesExport();"+anchor,1)
anchor="function wireActionButtons(){"
if s.count(anchor)!=1: raise SystemExit("Action binding insertion point changed.")
s=s.replace(anchor,"""document.addEventListener('change',e=>{if(e.target?.id==='hrChargeFrom'){state._hrChargeFrom=e.target.value;render()}if(e.target?.id==='hrChargeTo'){state._hrChargeTo=e.target.value;render()}});
"""+anchor,1)
viewpatch="const __lrxSaleViewBase=saleViewModal;saleViewModal=function(id){__lrxSaleViewBase(id);const x=(state.sales||[]).find(r=>String(r.id)===String(id));if(!x||(!x.customerTaxAmount&&!x.additionalCharges?.length))return;const b=document.getElementById('modalBox');if(!b)return;const el=document.createElement('div');el.className='resultbox manual-ticket-breakdown';el.innerHTML='Impuesto <b>'+money(x.customerTaxAmount)+'</b> · Cargos adicionales <b>'+money((x.additionalCharges||[]).reduce((n,c)=>n+Number(c.amount||0),0))+'</b> · Total del ticket <b>'+money(x.ticketTotal)+'</b>'+(x.additionalCharges||[]).map(c=>'<br>'+esc(c.label)+' ('+esc(c.kind)+') '+money(c.amount)+(c.employeeName?' · '+esc(c.employeeName):'')).join('');b.appendChild(el)};"
anchor="const __lrxSaleDetailBase=saleDetail;"
if s.count(anchor)!=1:raise SystemExit("Could not insert ticket detail display")
s=s.replace(anchor,viewpatch+anchor,1)
p.write_text(s)
print("Added ticket charge fields, employee HR totals, and percentage-based channel fees.")
PY


# Tax Sale liability report: taxable POS/To-go/Owner sales, excluding third-party delivery apps.
python3 - <<'PY'
from pathlib import Path
p=Path("dist/app.js");s=p.read_text()
code="""function taxSaleIsExempt(s){const c=String(s?.channel||'').normalize('NFD').replace(/[\\u0300-\\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]/g,'');return ['doordash','grubhub','ubereats'].some(x=>c.includes(x))}
function taxSaleBase(s){const d=saleDetail(s),items=Array.isArray(s?.items)&&s.items.length?s.items:[{product:s?.product||'',qty:s?.qty,price:s?.price}],taxLine=items.filter(x=>/^(tax|sales tax|tax sale|impuesto)$/i.test(String(x.product||x.name||'').trim())).reduce((n,x)=>n+Number(x.price||0)*Number(x.qty||1),0),gross=Math.max(0,Number(d.gross||0)-taxLine),discount=Math.max(0,Number(d.discountAmt||0)*(Number(d.gross||0)?gross/Number(d.gross||0):1));return Math.max(0,gross-discount)}
function taxSaleFor(s){if(taxSaleIsExempt(s))return {amount:0,base:taxSaleBase(s),rate:0,source:'Exenta · app de delivery'};const base=taxSaleBase(s);let actual=0,source='Estimado 7%';if(Number(s?.customerTaxAmount)>0){actual=Number(s.customerTaxAmount);source='Impuesto del ticket'}else if(Number(s?.ownerTax)>0){actual=Number(s.ownerTax);source='Impuesto reportado por Owner'}else if(Number(s?.shift4Tax)>0){actual=Number(s.shift4Tax);source='Impuesto reportado por Product Mix'}else actual=Math.round(base*7)/100;return {amount:actual,base,rate:7,source}}
function taxSaleRows(from='',to=''){const eligible=s=>{const start=String(s.periodStart||s.date||s.createdAt||'').slice(0,10),end=String(s.periodEnd||start).slice(0,10),status=String(s.status||'COMPLETADA').toUpperCase();if(!start||!end||['CANCELADA','DEVUELTA'].includes(status))return false;if(from&&end<from||to&&start>to)return false;return (!from||start>=from)&&(!to||end<=to)};const sales=(state.sales||[]).filter(eligible),keys=new Set(sales.filter(s=>s.periodStart||s.periodEnd||s.importSource).map(s=>[canonicalSalesChannelName(s.channel||''),String(s.periodStart||s.date||'').slice(0,10),String(s.periodEnd||s.periodStart||s.date||'').slice(0,10)].join('|'))),baseRows=sales.map(s=>{const t=taxSaleFor(s);return {...s,taxBase:t.base,taxSaleAmount:t.amount,taxSaleSource:t.source}}),mixes=(state.productMixReports||[]).filter(r=>eligible({date:r.periodStart,periodStart:r.periodStart,periodEnd:r.periodEnd,status:'COMPLETADA'})).filter(r=>!keys.has([canonicalSalesChannelName(r.channel||''),String(r.periodStart||'').slice(0,10),String(r.periodEnd||r.periodStart||'').slice(0,10)].join('|'))).map(r=>{const products=Array.isArray(r.products)?r.products:[],gross=products.reduce((n,x)=>n+Number(x.gross||0),0),discount=products.reduce((n,x)=>n+Number(x.discount||0),0),net=products.reduce((n,x)=>n+Number(x.net??(Number(x.gross||0)-Number(x.discount||0))),0),s={id:r.id,date:r.periodStart,periodStart:r.periodStart,periodEnd:r.periodEnd,channel:r.channel,product:'Product Mix · '+products.length+' artículos',items:products.map(x=>({product:x.product,qty:Number(x.qty||0),price:Number(x.qty)?Number(x.gross||0)/Number(x.qty):Number(x.gross||0)})),salesGrossOverride:gross,salesDiscountOverride:discount||Math.max(0,gross-net),salesNetOverride:net,status:'COMPLETADA',importSource:'PRODUCT_MIX_REPORT'};const t=taxSaleFor(s);return {...s,taxBase:t.base,taxSaleAmount:t.amount,taxSaleSource:'Product Mix · '+(taxSaleIsExempt(s)?'exento':'estimado 7%')}});return baseRows.concat(mixes)}
function taxSaleReport(){const from=String(state._dreFrom||''),to=String(state._dreTo||''),rows=taxSaleRows(from,to),taxable=rows.filter(x=>x.taxSaleAmount>0),gross=taxable.reduce((n,x)=>n+x.taxBase,0),accrued=taxable.reduce((n,x)=>n+x.taxSaleAmount,0),exempt=rows.filter(x=>taxSaleIsExempt(x)).reduce((n,x)=>n+x.taxBase,0),payments=(state.taxSalePayments||[]).filter(x=>(!from||String(x.periodFrom||x.date||'')>=from)&&(!to||String(x.periodTo||x.date||'')<=to)),paid=payments.reduce((n,x)=>n+Number(x.amount||0),0),balance=Math.max(0,accrued-paid),byChannel=new Map();rows.forEach(x=>{const name=String(x.channel||'Sin canal'),g=byChannel.get(name)||{base:0,tax:0,count:0,source:taxSaleIsExempt(x)?'Exenta · app de delivery':x.taxSaleSource};g.base+=Number(x.taxBase||0);g.tax+=Number(x.taxSaleAmount||0);g.count++;if(g.source!==x.taxSaleSource)g.source='Mixto';byChannel.set(name,g)});const fmt=(x)=>money(x),period=(from||'Inicio')+' a '+(to||'hoy');return '<section class="card tax-sale-account" style="margin-top:14px"><div class="rowhead"><div><h3>Cuenta contable · Tax Sale por pagar</h3><p class="muted">Impuesto causado en ventas POS, To-go y Owner al 7%. DoorDash, Grubhub y Uber Eats quedan exentos según la regla indicada. Se usa el impuesto reportado por el ticket o la importación cuando está disponible; si falta, se estima al 7% del subtotal neto de descuentos.</p></div><div class="catalog-actions"><button class="btn primary" data-action="tax-sale-payment">Registrar pago al IRS</button><button class="btn" data-action="tax-sale-pdf">PDF</button><button class="btn" data-action="tax-sale-excel">Excel</button></div></div><p><b>Período:</b> '+esc(period)+'</p><div class="grid"><div class="card kpi"><small>Base gravable</small><strong>'+fmt(gross)+'</strong></div><div class="card kpi"><small>Tax Sale causado</small><strong>'+fmt(accrued)+'</strong></div><div class="card kpi"><small>Pagos registrados</small><strong>'+fmt(paid)+'</strong></div><div class="card kpi"><small>Saldo por pagar</small><strong>'+fmt(balance)+'</strong></div><div class="card kpi"><small>Ventas exentas de apps</small><strong>'+fmt(exempt)+'</strong></div></div><div class="tablewrap" style="margin-top:12px"><table><thead><tr><th>Canal</th><th>Registros</th><th>Base gravable</th><th>Tax Sale</th><th>Origen</th></tr></thead><tbody>'+[...byChannel.entries()].sort((a,b)=>a[0].localeCompare(b[0])).map(([name,x])=>'<tr><td>'+esc(name)+'</td><td>'+x.count+'</td><td>'+fmt(x.base)+'</td><td>'+fmt(x.tax)+'</td><td>'+esc(x.source)+'</td></tr>').join('')+(byChannel.size?'':'<tr><td colspan="5" class="empty">No hay ventas registradas en este período.</td></tr>')+'</tbody></table></div><div class="tablewrap" style="margin-top:12px"><table><thead><tr><th>Pagos al IRS</th><th>Fecha</th><th>Período liquidado</th><th>Monto</th><th>Referencia</th></tr></thead><tbody>'+payments.map(x=>'<tr><td>Tax Sale</td><td>'+esc(x.date||'')+'</td><td>'+esc((x.periodFrom||'')+' a '+(x.periodTo||''))+'</td><td>'+fmt(x.amount)+'</td><td>'+esc(x.reference||'—')+'</td></tr>').join('')+(payments.length?'':'<tr><td colspan="5" class="empty">No hay pagos registrados para este período.</td></tr>')+'</tbody></table></div></section>'}
function taxSalePaymentModal(){const from=String(state._dreFrom||new Date().toISOString().slice(0,8)+'01'),to=String(state._dreTo||new Date().toISOString().slice(0,10)),rows=taxSaleRows(from,to),accrued=rows.reduce((n,x)=>n+Number(x.taxSaleAmount||0),0),paid=(state.taxSalePayments||[]).filter(x=>String(x.periodFrom||'')===from&&String(x.periodTo||'')===to).reduce((n,x)=>n+Number(x.amount||0),0),balance=Math.max(0,accrued-paid);modal('<h3>Registrar pago · Tax Sale al IRS</h3><p>Saldo del período '+esc(from)+' a '+esc(to)+': <b>'+money(balance)+'</b></p><div class="formgrid"><div class="field"><label>Monto pagado</label><input id="taxSalePayAmount" type="number" min="0.01" step=".01" max="'+balance.toFixed(2)+'" value="'+balance.toFixed(2)+'"></div><div class="field"><label>Fecha del pago</label><input id="taxSalePayDate" type="date" value="'+new Date().toISOString().slice(0,10)+'"></div><div class="field"><label>Período desde</label><input id="taxSalePayFrom" type="date" value="'+esc(from)+'"></div><div class="field"><label>Período hasta</label><input id="taxSalePayTo" type="date" value="'+esc(to)+'"></div><div class="field full"><label>Referencia / confirmación de pago</label><input id="taxSalePayRef" placeholder="Opcional"></div></div><div class="actions"><button class="btn" data-action="close">Cancelar</button><button class="btn primary" data-action="tax-sale-payment-save">Guardar pago</button></div>')}
function taxSalePaymentSave(){const amount=Number(document.getElementById('taxSalePayAmount')?.value||0),date=document.getElementById('taxSalePayDate')?.value||'',from=document.getElementById('taxSalePayFrom')?.value||'',to=document.getElementById('taxSalePayTo')?.value||'',reference=document.getElementById('taxSalePayRef')?.value.trim()||'';if(!(amount>0)||!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)||!/^\\d{4}-\\d{2}-\\d{2}$/.test(from)||!/^\\d{4}-\\d{2}-\\d{2}$/.test(to)||from>to)return toast('Revisa el monto, fecha y período del pago.');const accrued=taxSaleRows(from,to).reduce((n,x)=>n+Number(x.taxSaleAmount||0),0),alreadyPaid=(state.taxSalePayments||[]).filter(x=>String(x.periodFrom||'')===from&&String(x.periodTo||'')===to).reduce((n,x)=>n+Number(x.amount||0),0);if(amount>Math.max(0,accrued-alreadyPaid)+.005)return toast('El pago supera el saldo Tax Sale pendiente del período.');const snapshot=JSON.stringify(state);state.taxSalePayments=Array.isArray(state.taxSalePayments)?state.taxSalePayments:[];state.taxSalePayments.push({id:'TAXPAY-'+Date.now(),account:'Tax Sale',date,periodFrom:from,periodTo:to,amount,reference,createdAt:now(),createdBy:currentUser().name});audit('TAX_SALE_PAYMENT',money(amount)+' · IRS · '+from+' a '+to);if(!save()){restoreStateSnapshot(snapshot);return}close();render();toast('Pago de Tax Sale registrado.')}
function taxSaleExport(){const from=String(state._dreFrom||''),to=String(state._dreTo||''),rows=taxSaleRows(from,to).map(x=>({tipo:'Tax Sale causado',fecha:String(x.date||'').slice(0,10),id:x.id,canal:x.channel,baseGravable:x.taxBase,tasaAplicada:x.taxSaleSource==='Estimado 7%'?7:'Reportada',taxSale:x.taxSaleAmount,origen:x.taxSaleSource}));(state.taxSalePayments||[]).filter(x=>(!from||String(x.periodFrom||x.date||'')>=from)&&(!to||String(x.periodTo||x.date||'')<=to)).forEach(x=>rows.push({tipo:'Pago al IRS',fecha:x.date,id:x.id,canal:'Tax Sale',baseGravable:'',tasaAplicada:'',taxSale:-Number(x.amount||0),origen:x.reference||'Pago registrado'}));if(!rows.length)return toast('No hay movimientos Tax Sale en este período.');return exportExcel(rows,'Tax_Sale_por_pagar')}
function taxSalePrint(){const from=String(state._dreFrom||''),to=String(state._dreTo||''),rows=taxSaleRows(from,to),body=taxSaleReport().replace(/<button[\\s\\S]*?<\\/button>/g,'');return printHtml('Tax Sale por pagar · '+(from||'Inicio')+' a '+(to||'hoy'),body)}
const __lrxDreBase=dre;dre=function(){let html=__lrxDreBase(),i=html.indexOf('<div class="grid"><div class="card kpi"><small>Ventas brutas</small>');if(i>=0)html=html.slice(0,i)+taxSaleReport()+html.slice(i);return html};V.dre=dre;
document.addEventListener('click',e=>{const a=e.target?.closest?.('[data-action]')?.dataset?.action;if(a==='tax-sale-payment')taxSalePaymentModal();if(a==='tax-sale-payment-save')taxSalePaymentSave();if(a==='tax-sale-pdf')taxSalePrint();if(a==='tax-sale-excel')taxSaleExport()});
"""
if "function dre(){" not in s or "function taxSaleFor(" in s:raise SystemExit("Could not safely append Tax Sale report helpers.")
# Set the manual ticket default to 7% on taxable channels and zero on exempt marketplace channels.
old="document.getElementById('saleExtraCharges')?.addEventListener('click',e=>"
new="""const taxModeEl=document.getElementById('saleTaxMode'),taxValueEl=document.getElementById('saleTaxValue'),taxSync=()=>{const channel=String(document.getElementById('saleChannel')?.value||''),exempt=/doordash|grubhub|uber\\s*eats|ubereats/i.test(channel);if(exempt){taxModeEl.value='amount';taxValueEl.value='0';taxValueEl.disabled=true}else{taxValueEl.disabled=false;if(!existing&&Number(taxValueEl.value||0)===0){taxModeEl.value='percent';taxValueEl.value='7'}}};taxSync();document.getElementById('saleChannel')?.addEventListener('change',()=>{taxSync();previewSale()});document.getElementById('saleExtraCharges')?.addEventListener('click',e=>"""
if s.count(old)!=1:raise SystemExit("Manual tax default insertion point changed.")
s=s.replace(old,new,1)
# Tax-source logic and report functions load after the previously added charge features.
render_anchor="const body=(V[current]||generic)(m);content.innerHTML="
if s.count(render_anchor)!=1:raise SystemExit("Could not anchor the DRE report to module rendering.")
s=s.replace(render_anchor,"let body=(V[current]||generic)(m);if(current==='dre'&&typeof taxSaleReport==='function'&&!body.includes('tax-sale-account'))body=taxSaleReport()+body;content.innerHTML=",1)
anchor="window.LRXGetSharedState=getSharedState;"
if s.count(anchor)!=1:raise SystemExit("Could not place Tax Sale functions inside the application state scope.")
s=s.replace(anchor,code+"\n"+anchor,1)
p.write_text(s)
print("Added Tax Sale payable account, sales-import tax aggregation, payment tracking, PDF, and Excel.")
PY


# Keep DRE safe when the selected range has zero net sales: margin is null then.
python3 - <<'PY2'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
old = "${costComplete?margin.toFixed(1)+'%':'Pendiente'}"
new = "${costComplete?(margin==null?'—':margin.toFixed(1)+'%'):'Pendiente'}"
if s.count(old) != 1:
    raise SystemExit(f"Expected one DRE null-margin formatting site, found {s.count(old)}")
s = s.replace(old, new, 1)
p.write_text(s)
print("Prevented DRE crash when margin is null for a zero-sales period.")
PY2
