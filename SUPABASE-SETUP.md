# Activar sincronización compartida de LRX

La app guarda primero cada cambio en el dispositivo y después lo sincroniza con Supabase. Todos los socios autorizados comparten el mismo estado.

## Preparar Supabase

1. Reactiva el proyecto desde su panel si aparece como pausado.
2. Abre **SQL Editor**, pega y ejecuta `supabase/lrx-app-state.sql`.
3. En **Authentication → Providers / Sign In**, desactiva el registro público. Crea una cuenta de correo y contraseña para ti y una para cada socio desde **Authentication → Users**. No compartas contraseñas entre socios.
4. Publica estos cambios en GitHub Pages.

La clave `sb_publishable_…` incluida en la app está diseñada para estar en el navegador. La seguridad depende de iniciar sesión y de las políticas RLS del SQL. Nunca pongas una clave `service_role` en la app.

## Conectar los dispositivos

En cada dispositivo abre la app publicada, toca **Solo en este dispositivo**, e inicia sesión con una cuenta autorizada. En el primer dispositivo que tenga los registros correctos, elige subir esos datos a la nube. En los demás, elige cargar los datos de Supabase. La app conserva una copia local antes de reemplazar datos.

La sincronización se ejecuta al guardar y revisa cambios de otros dispositivos cada 12 segundos. Si dos dispositivos editan al mismo tiempo, la app avisa y permite elegir qué copia conservar.

## Instalar en teléfono o tableta

Abre la dirección publicada de GitHub Pages en Safari (iPhone/iPad) o Chrome (Android), inicia sesión y sincroniza. En iPhone/iPad toca **Compartir → Añadir a pantalla de inicio** y confirma **Añadir**. En Android abre el menú **⋮ → Instalar aplicación** o **Añadir a pantalla de inicio**. Repite la instalación y el inicio de sesión en cada dispositivo. La instalación solo crea un acceso directo; los datos compartidos vienen de Supabase.
