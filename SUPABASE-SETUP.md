# Activar sincronización compartida de LRX

La app guarda primero cada cambio en el dispositivo y después lo sincroniza con Supabase. Todos los socios autorizados comparten el mismo estado.

## Preparar Supabase

1. Reactiva el proyecto desde su panel si aparece como pausado.
2. Abre **SQL Editor**, pega y ejecuta `supabase/lrx-app-state.sql`.
3. En **Authentication → Providers / Sign In**, desactiva el registro público. Invita a cada socio desde **Authentication → Users → Add user → Send invitation**. Al abrir la invitación en la app, podrá crear su propia contraseña. No compartan contraseñas.
4. En **Authentication → URL Configuration**, establece como **Site URL** `https://sergioprag-beep.github.io/-la-reyna-inventory/` y agrega esa misma dirección a **Redirect URLs**.
5. Publica estos cambios en GitHub Pages.

La clave `sb_publishable_…` incluida en la app está diseñada para estar en el navegador. La seguridad depende de iniciar sesión y de las políticas RLS del SQL. Nunca pongas una clave `service_role` en la app.

## Conectar los dispositivos

Primero, en el dispositivo que tiene los registros correctos, abre la app publicada, toca **Solo en este dispositivo**, inicia sesión y confirma subir esos datos a la nube. Luego, en cada otro dispositivo, inicia sesión con la cuenta invitada y carga la copia de Supabase. La app conserva una copia local antes de reemplazar datos.

La sincronización se ejecuta al guardar y revisa cambios de otros dispositivos cada 12 segundos. Si dos dispositivos editan al mismo tiempo, la app avisa y permite elegir qué copia conservar.

## Instalar en teléfono o tableta

Abre la dirección publicada de GitHub Pages en Safari (iPhone/iPad) o Chrome (Android), inicia sesión y sincroniza. En iPhone/iPad toca **Compartir → Añadir a pantalla de inicio** y confirma **Añadir**. En Android abre el menú **⋮ → Instalar aplicación** o **Añadir a pantalla de inicio**. Repite la instalación y el inicio de sesión en cada dispositivo. La instalación solo crea un acceso directo; los datos compartidos vienen de Supabase.
