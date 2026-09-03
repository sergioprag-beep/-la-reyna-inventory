# LA REYNA XPRESS INVENTORY CLOUD — FASE 2

Esta carpeta contiene:
- index.html: aplicación PWA actual.
- manifest.webmanifest: instalación.
- sw.js: caché/offline.
- icons/: iconos de la aplicación.
- config.example.js: plantilla de conexión cloud.
- supabase_schema.sql: estructura inicial de la base de datos cloud.

## Para convertirla en una aplicación realmente sincronizada
1. Crear un proyecto en Supabase.
2. Ejecutar `supabase_schema.sql` en SQL Editor.
3. Crear usuarios desde Authentication.
4. Copiar URL y Anon Key al archivo `config.js`.
5. Integrar las operaciones CRUD de la aplicación con las tablas cloud.
6. Activar políticas RLS por usuario/rol.
7. Publicar esta carpeta en un hosting HTTPS.

## Resultado
Una sola aplicación instalada en iPhone, iPad y computadora, con datos centralizados y sincronizados.
