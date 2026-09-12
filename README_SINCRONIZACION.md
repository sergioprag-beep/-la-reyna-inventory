# La Reyna Xpress — Sincronización entre dispositivos

Esta versión mantiene el sistema local y agrega sincronización opcional con Supabase para usar la misma información en iPhone, iPad/tablet y computadora.

## 1. Crear la base de datos
1. Crea un proyecto en Supabase.
2. Abre **SQL Editor**.
3. Copia y ejecuta todo el contenido de `SUPABASE_SETUP.sql`.
4. En **Project Settings → API**, copia la **Project URL** y la clave **anon/public**.
5. No uses ni pegues una `service_role` key dentro de la aplicación.

## 2. Crear la cuenta
En la aplicación entra a **⚙️ Sistema → Configuración → Sincronización entre dispositivos**.

- Pega Project URL.
- Pega Anon/Public Key.
- Introduce correo y contraseña.
- Pulsa **Crear cuenta**.
- Si el proyecto exige confirmación por correo, confirma el correo y luego pulsa **Iniciar sesión**.

## 3. Pasar los datos actuales a la nube
En el dispositivo que contiene los datos correctos:

1. Haz primero un respaldo local desde Backup / Restore.
2. Inicia sesión.
3. Pulsa **☁️ Subir datos de este dispositivo**.

## 4. Configurar el iPad/tablet
1. Abre la misma aplicación en Safari/Chrome.
2. Entra en Sistema → Configuración → Sincronización.
3. Introduce la misma Project URL y Anon/Public Key.
4. Inicia sesión con la misma cuenta.
5. Pulsa **⬇️ Descargar datos de la nube**.
6. La aplicación se recargará con los datos centrales.

## Importante
La sincronización actual usa un **snapshot completo** de los datos de `localStorage`. Descargar la nube reemplaza los datos locales de ese dispositivo, por eso la aplicación pide confirmación.

El botón **Sincronizar ahora** compara la última sincronización conocida y evita reemplazar datos silenciosamente. Si dos dispositivos modifican datos sin sincronizar, no existe todavía un merge campo-por-campo; para esa etapa se recomienda sincronizar un dispositivo a la vez.
