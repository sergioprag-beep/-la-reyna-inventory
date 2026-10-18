# Migración de LRX a Cloudflare sin costo

Esta preparación mantiene la aplicación estática y usa D1 para la copia compartida y los archivos, junto con una contraseña de acceso de LRX protegida por una cookie de sesión segura. No requiere activar R2, Cloudflare Access ni una suscripción de almacenamiento. GitHub Pages no puede ejecutar las funciones de `functions/`, por eso **no se debe publicar este cambio en GitHub Pages antes de preparar Cloudflare Pages y verificarlo**.

## Componentes preparados

- Cloudflare Pages sirve una compilación pequeña desde `dist/`; no publica las carpetas antiguas, archivos ZIP ni copias históricas del repositorio.
- La pantalla de acceso solicita una contraseña compartida. El backend firma una cookie `HttpOnly`, `Secure` y `SameSite=Strict`, con vencimiento a las 12 horas.
- D1 conserva la revisión, los datos de LRX y los documentos privados. Los datos y archivos se dividen en fragmentos menores de 2 MB para ajustarse al límite de fila de D1.
- Las rutas `/api/state` y `/api/resources/*` solo responden después de verificar la cookie de sesión. Sin secreto configurado, las funciones fallan cerradas.
- En el primer inicio, LRX descarga una copia local antes de ofrecer la carga de los datos actuales.

## Configuración pendiente en la cuenta Cloudflare

1. Crear un proyecto Pages conectado al repositorio `sergioprag-beep/-la-reyna-inventory`, dejar el directorio raíz en `/`, usar el comando de compilación `bash cloudflare/build.sh` y la salida `dist`.
2. La base D1 `lrx-meta` ya está creada en la cuenta Cloudflare de esta sesión; su ID está enlazado en `wrangler.jsonc`.
3. Ya están creadas en D1 las tablas de estado y archivos definidas en `cloudflare/migrations/0001_lrx_state.sql`.
4. En Pages, enlazar la base existente como `LRX_META`.
5. En Pages, guardar `LRX_APP_PASSWORD` como variable secreta de producción y vista previa. Usa una frase aleatoria larga; no la guardes en el repositorio ni la compartas en el chat.
6. Configurar el acceso a la vista previa de Pages según la política de privacidad del negocio. La contraseña de LRX protege la aplicación y sus API; las páginas estáticas de vista previa siguen siendo públicamente descargables.
7. Confirmar que una contraseña incorrecta no inicia sesión y que `/api/state` responde 401 sin una cookie válida.
8. En GitHub Pages, abrir **Configuración → Descargar archivo de respaldo** y guardar el JSON. El almacenamiento del navegador está separado por sitio; la nueva dirección de Pages no puede leer automáticamente los datos locales de `github.io`.
9. Publicar el build. En Cloudflare Pages, entrar con Access, abrir **Configuración → Restaurar respaldo** y seleccionar el JSON descargado. Revisar los registros antes de aceptar la carga inicial a Cloudflare.

## Archivos adjuntos que ya estaban en Supabase

El respaldo JSON trae los datos y las fichas de los documentos, pero no incluye los archivos binarios guardados en Supabase Storage. La nueva app los identifica como adjuntos pendientes y explica por qué no puede abrirlos. No borres la cuenta ni los archivos de Supabase: cuando vuelva a habilitar descargas, habrá que transferir esos adjuntos por separado a D1. Los nuevos archivos que se suban después del cambio sí se guardarán en D1.

## Operación y respaldo

La app conserva datos primero en IndexedDB del navegador. El backend recibe la copia cuando hay conexión. No borrar los datos locales de GitHub Pages ni el archivo JSON hasta comprobar que la copia de Cloudflare abre correctamente y que se ven inventario, compras, recetas, producción y reportes.

Las cuotas gratuitas no son ilimitadas: D1 y Pages Functions pueden rechazar solicitudes al alcanzar límites diarios o de almacenamiento. Si ocurre, el modo local sigue conservando cambios en esa computadora, pero la copia compartida queda pendiente hasta reanudar el servicio. No se activó R2 ni un plan de pago.
