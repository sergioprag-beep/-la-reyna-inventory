# Migración de LRX a Cloudflare sin costo

Esta preparación mantiene la aplicación estática y usa D1 para la copia compartida y los archivos, junto con Cloudflare Access para protegerla. No requiere activar R2 ni una suscripción de almacenamiento. GitHub Pages no puede ejecutar las funciones de `functions/`, por eso **no se debe publicar este cambio en GitHub Pages antes de preparar Cloudflare Pages y verificarlo**.

## Componentes preparados

- Cloudflare Pages sirve una compilación pequeña desde `dist/`; no publica las carpetas antiguas, archivos ZIP ni copias históricas del repositorio.
- Cloudflare Access protege la aplicación y sus API. La lista de correos autorizados se configura en Access.
- D1 conserva la revisión, los datos de LRX y los documentos privados. Los datos y archivos se dividen en fragmentos menores de 2 MB para ajustarse al límite de fila de D1.
- Las rutas `/api/state` y `/api/resources/*` solo responden después de verificar el JWT de Cloudflare Access.
- En el primer inicio, LRX descarga una copia local antes de ofrecer la carga de los datos actuales.

## Configuración pendiente en la cuenta Cloudflare

1. Crear un proyecto Pages conectado al repositorio `sergioprag-beep/-la-reyna-inventory`, dejar el directorio raíz en `/`, usar el comando de compilación `bash cloudflare/build.sh` y la salida `dist`.
2. La base D1 `lrx-meta` ya está creada en la cuenta Cloudflare de esta sesión; su ID está enlazado en `wrangler.jsonc`.
3. Ya están creadas en D1 las tablas de estado y archivos definidas en `cloudflare/migrations/0001_lrx_state.sql`.
4. En Pages, enlazar la base existente como `LRX_META`.
5. En Pages, configurar estas variables de entorno de producción:
   - `LRX_ACCESS_TEAM_DOMAIN`: dominio del equipo Access, sin `https://` (por ejemplo, `mi-equipo.cloudflareaccess.com`).
   - `LRX_ACCESS_AUD`: Audience Tag de la aplicación Access.
6. Configurar Cloudflare Access para proteger la dirección de Pages de producción, permitir solo los correos de LRX y mantener desactivados los despliegues de vista previa públicos.
7. Confirmar que el acceso protegido funciona y que `/api/state` requiere una sesión autorizada.
8. En GitHub Pages, abrir **Configuración → Descargar archivo de respaldo** y guardar el JSON. El almacenamiento del navegador está separado por sitio; la nueva dirección de Pages no puede leer automáticamente los datos locales de `github.io`.
9. Publicar el build. En Cloudflare Pages, entrar con Access, abrir **Configuración → Restaurar respaldo** y seleccionar el JSON descargado. Revisar los registros antes de aceptar la carga inicial a Cloudflare.

## Archivos adjuntos que ya estaban en Supabase

El respaldo JSON trae los datos y las fichas de los documentos, pero no incluye los archivos binarios guardados en Supabase Storage. La nueva app los identifica como adjuntos pendientes y explica por qué no puede abrirlos. No borres la cuenta ni los archivos de Supabase: cuando vuelva a habilitar descargas, habrá que transferir esos adjuntos por separado a D1. Los nuevos archivos que se suban después del cambio sí se guardarán en D1.

## Operación y respaldo

La app conserva datos primero en IndexedDB del navegador. El backend recibe la copia cuando hay conexión. No borrar los datos locales de GitHub Pages ni el archivo JSON hasta comprobar que la copia de Cloudflare abre correctamente y que se ven inventario, compras, recetas, producción y reportes.

Las cuotas gratuitas no son ilimitadas: D1 y Pages Functions pueden rechazar solicitudes al alcanzar límites diarios o de almacenamiento. Si ocurre, el modo local sigue conservando cambios en esa computadora, pero la copia compartida queda pendiente hasta reanudar el servicio. No se activó R2 ni un plan de pago.
