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
bridge = "const __lrxApplyEnglishUI=applyEnglishUI;const __lrxOriginalAttrs=new WeakMap();const __lrxOriginalNodes=new WeakMap();const __lrxTranslateText=value=>{if(state.settings?.language!=='en')return value;let out=UI_EN[value]||value;for(const key of Object.keys(UI_EN).filter(k=>k.length>2).sort((a,b)=>b.length-a.length)){if(/^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ]+$/.test(key)){let at=0,pos;while((pos=out.indexOf(key,at))>=0){const before=pos?out[pos-1]:'',after=out[pos+key.length]||'';if(!/[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ]/.test(before)&&!/[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ]/.test(after)){out=out.slice(0,pos)+UI_EN[key]+out.slice(pos+key.length);at=pos+UI_EN[key].length}else at=pos+key.length}}else if(out.includes(key))out=out.split(key).join(UI_EN[key])}out=out.replace(/Showing (\\d+[–-]\\d+) de (\\d+) records · Page (\\d+) de (\\d+)/g,'Showing $1 of $2 records · Page $3 of $4');out=out.replace(/Showing (\\d+[–-]\\d+) de (\\d+) · Page (\\d+) de (\\d+)/g,'Showing $1 of $2 · Page $3 of $4');return out};applyEnglishUI=function(){const before=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n;while(n=before.nextNode())if(!__lrxOriginalNodes.has(n))__lrxOriginalNodes.set(n,lrxOriginalText?.get(n)||n.nodeValue||'');__lrxApplyEnglishUI();const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);while(n=w.nextNode()){const current=n.nodeValue||'',fromOriginal=__lrxOriginalNodes.get(n)||'',translatedCurrent=__lrxTranslateText(current),translatedOriginal=__lrxTranslateText(fromOriginal),next=translatedCurrent!==current?translatedCurrent:translatedOriginal;if(next!==current)n.nodeValue=next};document.querySelectorAll('[aria-label],[title]').forEach(el=>{let original=__lrxOriginalAttrs.get(el);if(!original){original={};__lrxOriginalAttrs.set(el,original)}for(const attr of ['aria-label','title']){const key=attr==='aria-label'?'aria':'title',current=el.getAttribute(attr);if(current===null)continue;if(!(key in original)||current!==original['last'+key])original[key]=current;const next=state.settings?.language==='en'?__lrxTranslateText(original[key]):original[key];if(current!==next)el.setAttribute(attr,next);original['last'+key]=next}})};window.extendLRXEnglishDictionary=extra=>{for(const [key,value] of Object.entries(extra||{})){UI_EN[key]=value;try{const repaired=decodeURIComponent(escape(key));if(repaired!==key)UI_EN[repaired]=value}catch{}}applyEnglishUI()};const __lrxTranslationObserver=new MutationObserver(()=>{if(state.settings?.language==='en')applyEnglishUI()});__lrxTranslationObserver.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['aria-label','title']});function updateLanguageChip(){"
if "window.extendLRXEnglishDictionary" not in s:
    if needle not in s:
        raise SystemExit("Could not find language UI insertion point")
    s = s.replace(needle, bridge, 1)
    p.write_text(s)
PY
