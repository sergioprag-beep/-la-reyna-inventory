#!/usr/bin/env bash
set -euo pipefail

rm -rf dist
mkdir -p dist
cp index.html styles.css app.js purchase-engine.js catalog-controls.js cloudflare-sync.js sw.js master.json manifest.webmanifest hero-food.jpg hero-bar.jpg LRX-LOGO-PLANTILLAS.png LRX-LOGO-IMPRESION-TRANSPARENTE.png dist/
mkdir -p dist/assets
cp -R assets/utensils dist/assets/
