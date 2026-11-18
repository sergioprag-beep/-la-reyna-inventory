Warning: truncated output (original token count: 3606)
Total output lines: 62

#!/usr/bin/env bash
set -euo pipefail

rm -rf dist
mkdir -p dist
cp index.html styles.css app.js purchase-engine.js catalog-controls.js cloudflare-sync.js ui-translation-extra.js recipe-price-mobile.js sw.js master.json manifest.webmanifest hero-food.jpg hero-bar.jpg LRX-LOGO-PLANTILLAS.png LRX-LOGO-IMPRESION-TRANSPARENTE.png dist/

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
bridge = "const __lrxBaseApplyEnglishUI=applyEnglishUI;const __lrxRawText=new WeakMap();const __lrxRenderedText=new WeakMap();const __lrxRawAttrs=new WeakMap();const __lrxRenderedAttrs=new WeakMap();let __lrxTranslateLookup=new Map();let __lrxPhraseRegex=null;const __lrxBuildTranslationIndex=()=>{__lrxTranslateLookup=new Map(Object.entries(UI_EN).map(([k,v])=>[k.toLocaleLowerCase(),v]));const keys=Object.keys(UI_EN).filter(k=>k.length>=4&&/^[A-Za-zÀ-ÖØ-öø-ÿ0-9 ]+$/.test(k)).sort((a,b)=>b.length-a.length);__lrxPhraseRegex=keys.length?new RegExp('(^|[^A-Za-zÀ-ÖØ-öø-ÿ0-9])('+keys.join('|')+')(?=$|[^A-Za-zÀ-ÖØ-öø-ÿ0-9])','gi'):null};__lrxBuildTr…2606 tokens truncated…t=__lrxTranslateValue(raw[attr]);if(current!==next)el.setAttribute(attr,next);rendered[attr]=next}})};window.extendLRXEnglishDictionary=extra=>{Object.assign(UI_EN,extra||{});for(const [key,value] of Object.entries(extra||{})){try{const repaired=decodeURIComponent(escape(key));if(repaired!==key)UI_EN[repaired]=value}catch{}}__lrxBuildTranslationIndex();applyEnglishUI()};let __lrxTranslationTimer=0;const __lrxTranslationObserver=new MutationObserver(()=>{if(state.settings?.language!=='en')return;clearTimeout(__lrxTranslationTimer);__lrxTranslationTimer=setTimeout(()=>applyEnglishUI(),180)});__lrxTranslationObserver.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['aria-label','title','placeholder','data-label']});function updateLanguageChip(){"
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
    ("const APP_VERSION='v555';", "const APP_VERSION='v557';"),
    ("master.json?v=2026-11-13-persist-recovery-v4", "master.json?v=2026-11-18-shopping-sync-v1"),
    ("seedRecipeUtensils();await normalizeUserUtensilImages();", "seedRecipeUtensils();setTimeout(()=>{normalizeUserUtensilImages().catch(error=>console.warn('LRX utensil image normalization deferred',error))},0);"),
]
for old, new in changes:
    if s.count(old) != 1:
        raise SystemExit(f"Expected one occurrence in dist/app.js: {old}")
    s = s.replace(old, new, 1)
p.write_text(s)
PY
