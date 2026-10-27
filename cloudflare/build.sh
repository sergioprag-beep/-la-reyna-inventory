#!/usr/bin/env bash
set -euo pipefail

rm -rf dist
mkdir -p dist
cp index.html styles.css app.js purchase-engine.js catalog-controls.js cloudflare-sync.js ui-translation-extra.js sw.js master.json manifest.webmanifest hero-food.jpg hero-bar.jpg LRX-LOGO-PLANTILLAS.png LRX-LOGO-IMPRESION-TRANSPARENTE.png dist/
mkdir -p dist/assets
cp -R assets/utensils dist/assets/

python3 - <<'PY'
from pathlib import Path
p = Path("dist/app.js")
s = p.read_text()
needle = "function updateLanguageChip(){"
bridge = "const __lrxApplyEnglishUI=applyEnglishUI;const __lrxOriginalAttrs=new WeakMap();const __lrxTranslateText=value=>{if(state.settings?.language!=='en')return value;let out=value;for(const key of Object.keys(UI_EN).filter(k=>k.length>2).sort((a,b)=>b.length-a.length))if(out.includes(key))out=out.split(key).join(UI_EN[key]);return out};applyEnglishUI=function(){__lrxApplyEnglishUI();const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;while(n=w.nextNode())n.nodeValue=__lrxTranslateText(n.nodeValue||'');document.querySelectorAll('[aria-label],[title]').forEach(el=>{let original=__lrxOriginalAttrs.get(el);if(!original){original={aria:el.getAttribute('aria-label'),title:el.getAttribute('title')};__lrxOriginalAttrs.set(el,original)}for(const [attr,value] of Object.entries(original))if(value!==null)el.setAttribute(attr,state.settings?.language==='en'?__lrxTranslateText(UI_EN[value]||value):value)})};window.extendLRXEnglishDictionary=extra=>{Object.assign(UI_EN,extra||{});applyEnglishUI()};function updateLanguageChip(){"
if "window.extendLRXEnglishDictionary" not in s:
    if needle not in s:
        raise SystemExit("Could not find language UI insertion point")
    s = s.replace(needle, bridge, 1)
    p.write_text(s)
PY
