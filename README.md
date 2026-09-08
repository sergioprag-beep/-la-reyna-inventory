# La Reyna Xpress Management PRO v57.10 — FIX 10

Build de despliegue limpio.

- Versión visible actualizada a V57.10.
- Service Worker nuevo `lrx-v57.10-clean`.
- Eliminación de cachés anteriores al activar el nuevo Service Worker.
- Registro del Service Worker con cache-busting `?v=57.10` y `updateViaCache:none`.
- Mantiene las correcciones de Compras + entrada de FIX 6/7.
- Mantiene Producto: Editar, Guardar cambios y Eliminar.
- Mantiene Inventario avanzado: Adjust y Count.

## IMPORTANTE PARA GITHUB PAGES
Sube/reemplaza **los archivos que están dentro de este ZIP directamente en la raíz del repositorio**, no la carpeta contenedora.

La raíz debe contener:
- `index.html`
- `sw.js`
- `offline.html`
- `README.md`
- `CLOUD_SETUP.md`

Después de publicar, abre el sitio y haz una recarga completa. La pantalla debe mostrar **PRO v57.10**.
