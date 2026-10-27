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
bridge = "window.extendLRXEnglishDictionary=(extra)=>{Object.assign(UI_EN,extra||{});applyEnglishUI()};\\nfunction updateLanguageChip(){"
if "window.extendLRXEnglishDictionary" not in s:
    if needle not in s:
        raise SystemExit("Could not find language UI insertion point")
    s = s.replace(needle, bridge, 1)
    p.write_text(s)
PY
