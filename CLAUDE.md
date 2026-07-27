# Weluk — Documento de Contexto del Proyecto

> **Nombre del producto: Weluk** (de "we look" — deformación ortográfica intencional,
> patrón de naming similar a Tumblr/Flickr). Nombre definitivo tras un proceso extenso
> de exploración con el directorio — se descartaron previamente Emivo (sonaba infantil,
> "amivoo", para un contexto de pitch de startup), Massiva (colisión directa con
> Massiva S.A., empresa chilena de OOH/DOOH de 30+ años), Wesee (colisión con al menos
> dos startups de tech activas del mismo nombre), Clevo (colisión con fabricante de
> laptops), y otras variaciones (Klento, Cleve, Plyed, Sygnal, Glance, Mírelo, etc.).
> Dominio y disponibilidad de marca verificados como libres.
>
> Proyecto desarrollado por Octalink SpA (Concepción, Chile) — Weluk es el nombre de
> marca del producto, no reemplaza a Octalink como empresa.
>
> **Pendiente:** definir tagline final (los explorados para Emivo ya no aplican
> directamente, se pueden adaptar al nuevo nombre más adelante).

> Este documento es la fuente de verdad compartida entre los 4 repositorios del producto
> (landing, panel, apk, visor-web). Ninguna decisión aquí está escrita en piedra — es la
> base de trabajo actual, sujeta a revisión a medida que avanza el desarrollo y el piloto.
>
> Cada repo debe incluir este archivo (o un link a él) para que cualquier sesión de
> Claude Code / IDE tenga contexto completo del producto, aunque solo esté trabajando
> en una parte específica.

---

## 1. Qué es esto

**Weluk** es la plataforma de digital signage (cartelería digital) desarrollada por
**Octalink SpA** (Concepción, Chile). Permite administrar listas de reproducción (imágenes/video) y
programarlas por horario en pantallas remotas (TVs con Android box, o Smart TVs vía
navegador).

**Motivación de negocio:** no es solo un SaaS self-serve. El modelo core es un
**servicio administrado + plataforma**, dirigido a clientes que no quieren tocar nada
("hazlo todo tú"), con un tier adicional self-serve para clientes que sí quieren
administrar su propio contenido. Ver sección 8 para el modelo comercial completo.

**Por qué se construye en vez de usar un competidor (Juuno, Yodeck, Anthias, etc.):**

1. Es parte de un producto más grande — se integra con el modelo de servicios
   administrados de Octalink (diseño de slides + administración + soporte), no solo
   licenciamiento de software.
2. Objetivo explícito de aprendizaje técnico del equipo — costo de oportunidad aceptado
   conscientemente, no oculto en el business case.

---

## 2. Arquitectura general — 4 repos separados

Repos **independientes**, no monorepo (salvo que en el futuro se detecte repetición real
de tipos/interfaces entre panel y visor-web, ahí evaluar pnpm workspaces — no antes).

| Repo        | Stack                              | Deploy                        | Responsabilidad                                          |
| ----------- | ---------------------------------- | ----------------------------- | -------------------------------------------------------- |
| `landing`   | Astro                              | Vercel                        | Marketing, SEO, estático                                 |
| `panel`     | Vue.js                             | Vercel                        | Admin: pantallas, playlists, schedules, pairing, publish |
| `apk`       | React Native                       | Play Store / sideload directo | Visor para Android TV box (ej. "onn")                    |
| `visor-web` | Vue.js (confirmado, ver sección 3) | Vercel                        | Visor para navegador de Smart TV                         |

**Futuro (no en v1):** apps nativas Tizen (Samsung) / LG webOS — el equipo ya tiene
experiencia previa en esto de proyectos para canales de TV. Se posterga hasta validar
tracción, porque implica pasar por revisión de store de cada fabricante.

---

## 3. Decisión de stack — visor web: Vue, no vanilla JS

**Decisión revisada durante el proceso.** La hipótesis inicial era usar JS puro para el
visor web, asumiendo que un framework reactivo sería demasiado pesado para el motor
Chromium/WebKit desactualizado de un Smart TV corriendo 24/7.

**Se descartó esa hipótesis** tras inspeccionar en producción el visor de Juuno
(`d.juuno.co`), un competidor validado a escala con cientos de Smart TVs en el mundo real.
Su network tab confirma stack Vue completo (`vue-runtime`, VeeValidate, arquitectura de
paquetes compartidos tipo monorepo, bundler Vite). Esto es evidencia de que **Vue sí
funciona bien en este contexto**, y valida usar el mismo framework que ya domina el
equipo (consistencia con el panel, reutilización de lógica).

**Precaución que se mantiene igual:** monitorear memoria en sesiones largas (24h+) al
probar en hardware real — no por Vue específicamente, sino por cualquier riesgo de
memory leak en un proceso que nunca se recarga.

**Paso previo obligatorio antes de comprometerse del todo:** probar en el navegador real
del Onn (u otro box Android genérico) y en el navegador integrado de al menos una Smart
TV real, qué versión de Chromium corre debajo, y si el `localStorage`/almacenamiento
persiste entre reinicios y actualizaciones de firmware.

**Hallazgo de la primera prueba en hardware real (26 julio 2026):** un Smart TV Samsung
más viejo mostraba pantalla en blanco con el build normal de Vite — el navegador es tan
antiguo que ni siquiera soporta `<script type="module">` nativo, así que el JS nunca
llegaba a correr (el navegador ignora el tag silenciosamente, sin error visible). Dato
de contexto útil: en ese mismo TV, `d.juuno.co` (el competidor validado) tampoco cargó
(quedó en negro) — confirma que es un techo real de hardware/navegador, no un bug propio.

**Fix aplicado:** se agregó `@vitejs/plugin-legacy` en `vite.config.js` del repo
`visor-web`, con `targets: ['chrome >= 38', 'safari >= 9']`. Esto genera un bundle
adicional transpilado a ES5 + polyfills + loader SystemJS, servido vía `<script
nomodule>` como fallback. Tras esto el visor cargó correctamente en el TV viejo.

- **Ojo con la versión del plugin:** la última versión de `@vitejs/plugin-legacy` (8.x)
  pide Vite 8 como peer — como el proyecto corre Vite 5.x, hay que fijar la versión del
  plugin a la misma serie mayor que Vite (`@vitejs/plugin-legacy@5.4.3` en este caso),
  no instalar "latest" a ciegas.
- **El fallback legacy solo existe en el build de producción** (`vite build`), nunca en
  el dev server (`vite dev`). Para probar en hardware real (TV/Onn) siempre hay que usar
  `pnpm build && pnpm preview --host`, o el deploy real en Vercel (que ya corre `vite
  build` automáticamente) — nunca el dev server directo.
- Pendiente: repetir esta misma validación en el box Onn.

**Segundo hallazgo, al implementar pairing (26 julio 2026):** pantalla en blanco al
probar el visor por IP de LAN en HTTP plano (ej. `http://192.168.1.x:5173`) — funcionaba
bien en `localhost` pero no por IP. Causa: `crypto.randomUUID()` (usado para generar el
`device_uuid` persistente) **solo existe en contextos seguros** (HTTPS, o el caso
especial de `localhost`); por HTTP plano en una IP simplemente no está disponible y la
app revenaba al montar, antes de renderizar nada. Muy probablemente la misma causa de
que el visor se cayera en el TV real (que accedía por IP, no por una URL HTTPS).

- **Fix aplicado:** `src/lib/device.js` ahora hace fallback a un generador de UUID
  manual (`Math.random()`, sin necesidad de Web Crypto) cuando `crypto.randomUUID` no
  existe. No cambia nada cuando sí está disponible.
- **No afecta producción:** el deploy real es vía Vercel, que sirve todo por HTTPS
  (contexto seguro) — este bug solo aparece probando por IP de LAN en HTTP plano durante
  desarrollo, o si alguna vez se prueba en el TV apuntando directo a una IP en vez de una
  URL HTTPS real.

---

## 4. Backend / Datos

- **Base de datos:** Supabase (Postgres). Elegido sobre Firebase porque el modelo es
  relacional (pantallas, playlists, schedules, clientes) y porque el equipo ya lo usa en
  otros proyectos (RHL, QForest, plataforma nutricional).
- **Storage:** Supabase Storage, para imágenes/video de las playlists.
- **Sync en tiempo real:** Supabase Realtime (websocket sobre Postgres WAL) — **no
  polling**. Ver sección 6.
- **Deploy:** Vercel para landing, panel, y visor-web.

### Plan Supabase — Free tier (verificado julio 2026)

| Recurso                          | Límite Free                        |
| -------------------------------- | ---------------------------------- |
| Base de datos                    | 500 MB                             |
| File storage                     | 1 GB total, 50 MB máx por archivo  |
| Egress                           | 5 GB/mes                           |
| Conexiones Realtime concurrentes | 200                                |
| Mensajes Realtime/mes            | 2,000,000 (máx 256 KB por mensaje) |
| Proyectos activos                | 2                                  |

**Riesgo real identificado para el piloto:** no es egress ni conexiones (ampliamente
suficiente para 1-5 pantallas con cambios ocasionales) — es el **límite de 1 GB de
storage total** y **50 MB máx por archivo**. Definir desde el día uno:

- Pipeline de compresión de video antes de subir (H.264 bien comprimido).
- Política de limpieza de contenido/versiones viejas no usadas.

**Riesgo operativo:** proyectos free se pausan tras 7 días sin actividad de API. No
debería ocurrir con Realtime corriendo 24/7 en las TVs, pero cuidado si las TVs de
prueba quedan desconectadas por un período largo entre pruebas del piloto.

---

## 5. Modelo de datos — esquema final consolidado

Decisión clave tomada tras revisar el flujo real de Juuno: **sin historial de versiones,
sin workspaces de agencia, sin tabla de sucursales**. El modelo se simplificó
deliberadamente para el MVP. Reglas de negocio ya resueltas:

- **Una pantalla = una sola playlist activa a la vez.** `screens.current_playlist_id`
  se sobrescribe directamente al asignar una nueva — no hay versiones ni historial.
- **Draft vs. publicado sin duplicar datos.** `playlist_items` es la única fuente de
  verdad del contenido. La tabla `playlists` tiene `updated_at` (cambia con cualquier
  edición normal) y `published_at` (SOLO cambia al apretar "Publicar"). El visor
  escucha únicamente cambios en `published_at`, nunca en `updated_at` — así una edición
  a medio hacer nunca llega a la pantalla en vivo.
- **Auth:** `auth.users` de Supabase solo para login/password. Toda la lógica de
  negocio (rol, empresa asociada) vive en la tabla `profiles`, no en metadata de Auth.
- **Roles:** `superadmin` (equipo Octalink, `company_id = null`, ve todas las
  companies — cubre el modelo full-managed) y `company_admin` (administra solo su
  propia company, tier self-serve).
- **Sin tabla de sucursales/locations.** Si se necesita en el futuro, empezar por un
  campo de texto libre en `screens`, no una tabla nueva — mismo enfoque simple que usa
  Juuno (que tampoco modela sucursales como entidad separada).

### Fuente de verdad del esquema

> **El archivo `weluk-schema.sql` (en la raíz de este repo / carpeta de infraestructura)
> es la única fuente autoritativa del esquema real** — tablas, columnas, índices, RLS,
> policies de `anon`, y configuración de Realtime. Este documento solo resume el
> propósito de cada tabla en alto nivel; ante cualquier duda de columnas exactas, tipos
> de dato, constraints o policies, **revisar el `.sql`, no este resumen.** Si el esquema
> cambia, se actualiza únicamente el `.sql` — este resumen se actualiza después, como
> reflejo, no como fuente.

Resumen de tablas (propósito, no estructura exacta — ver `.sql` para columnas reales):

```
companies       — cada cliente (RHL, Lomo Alemán, gym, etc.)
profiles        — id = auth.users.id, role, company_id
media           — archivos subidos (imagen/video)
playlists       — name, updated_at (draft), published_at (lo que ve el visor)
playlist_items  — orden y duración por ítem dentro de una playlist
screens         — device_uuid, current_playlist_id, last_seen_at
pairing_codes   — code, device_uuid, status, expires_at
```

**Configuración del proyecto Supabase aplicada (no solo el `.sql`):**

- "Automatically expose new tables" → activado (decisión consciente para simplificar
  el MVP; Supabase ya no lo deja activado por defecto en proyectos nuevos desde 2026,
  hay que seguir activándolo a mano). Revisar/ajustar en Project Settings → Data API.
- "Enable automatic RLS" → desactivado (el `.sql` ya controla RLS explícitamente).
- Región del proyecto: Americas.

### Storage (Supabase Storage)

- **Bucket:** `media` — público (`Public bucket = true`), ya que el visor lee sin
  sesión de usuario (rol `anon`).
- **Restricciones aplicadas al bucket:** tamaño máximo 50 MB por archivo (coincide con
  el límite global del plan free), MIME types permitidos: `image/jpeg, image/png,
image/webp, video/mp4`.
- **Estructura de carpetas:** `media/{company_id}/{nombre_archivo}` — un folder por
  company, evita mezclar contenido entre clientes. El campo `media.storage_path` en la
  BD guarda esta ruta relativa (no la URL completa).
- **Pendiente:** policies de Storage para limitar quién puede subir/borrar (hoy solo
  se sube manual desde el dashboard como owner del proyecto; falta definir el flujo de
  upload desde el panel una vez construido).

### Datos de prueba sembrados (ambiente de desarrollo)

Ya existen datos de prueba en el proyecto Supabase para desarrollar el visor sin
depender del panel ni del flujo real de pairing:

- `companies`: 1 fila, "Gym Test" (`id = 11111111-1111-1111-1111-111111111111`)
- `media`: 2 filas — `foto1.jpg` (image) y `video1.mp4` (video), ambos en
  `media/11111111-1111-1111-1111-111111111111/` en el bucket de Storage
- `playlists`: 1 fila, "Playlist Gym", ya con `published_at` seteado (publicada)
- `playlist_items`: 2 filas — foto en `order_index 0`, video en `order_index 1`
- `screens`: 1 fila, "TV_PRUEBA", con `device_uuid =
66666666-6666-6666-6666-666666666666`, ya "emparejada" (`status = 'paired'`) y con
  `current_playlist_id` apuntando a "Playlist Gym"

Este `device_uuid` (`66666666-...`) es el que debe usar `weluk-browser` hardcodeado
temporalmente durante el desarrollo inicial, para probar la lectura y reproducción
**sin implementar aún el flujo real de pairing** (eso viene después, ver sección 6).
pairing_codes — code, device_uuid, status, expires_at

```

### Detección de pantalla conectada/desconectada

Se usa **Supabase Realtime Presence**, no solo heartbeats manuales:
- El visor, al abrir su canal Realtime (el mismo que ya mantiene abierto 24/7 para
  pairing/sync), se "anuncia" (`channel.track(...)`). Supabase detecta automáticamente
  cuando esa conexión se cae, sin que el visor tenga que avisar explícitamente.
- El panel puede mostrar estado online/offline en tiempo real vía el evento
  `presence.sync` del canal.
- `screens.last_seen_at` se mantiene como respaldo histórico (para reportes tipo
  "esta pantalla lleva 3 días sin conectarse"), ya que Presence solo vive mientras el
  canal está activo, no guarda historial.
- Funciona igual en cualquier hardware (visor-web, APK) porque es una función del
  cliente JS de Supabase, no depende del tipo de dispositivo.

---

## 6. Flujo de pairing (vinculación de pantalla)

Inspirado en el patrón estándar de la industria (mismo concepto que OAuth 2.0 Device
Authorization Grant, RFC 8628 — código corto + claim desde otro dispositivo con teclado),
y confirmado en producción observando el flujo real de Juuno.

1. Visor arranca → genera/recupera su `device_uuid` interno persistente.
2. Visor solicita un código corto (4-6 caracteres, alfabeto sin ambigüedad visual:
   evitar 0/O, 1/I/L) → se verifica que no exista ya un código igual en estado
   `pending` → se inserta en `pairing_codes` con expiración (10-15 min).
3. Visor muestra pantalla de espera: código grande, una sola instrucción simple
   ("Desde un navegador, ve a [URL] para activar esta pantalla"), sin ruido técnico.
   Referencia visual: pantalla de espera de Juuno (fondo oscuro, código centrado,
   instrucción de una línea).
4. Visor abre y mantiene vivo un canal Supabase Realtime escuchando cambios sobre
   ese código/pantalla **desde este mismo momento** (no esperar a que se reclame para
   conectar el websocket — la percepción de "instantáneo" depende de esto).
5. Usuario entra al panel, escribe el código, asigna nombre a la pantalla y
   playlist/schedule inicial → confirma.
6. Backend valida código (pending, no expirado) → lo marca `claimed`, crea/actualiza
   el registro en `screens`.
7. El visor recibe el evento vía el websocket ya abierto (latencia esperada: cientos
   de milisegundos) → deja de mostrar el código, empieza a preparar/descargar el
   primer contenido, y pasa a modo reproducción.

**Códigos NO necesitan ser globalmente únicos para siempre** — solo únicos mientras
están en estado `pending`. Se pueden reutilizar libremente una vez expirados/reclamados.

**Función de "Disconnect this screen"**: debe existir (tanto en panel como posiblemente
en el propio visor) para desvincular una pantalla sin reinstalar la app — vuelve al
estado de pantalla de espera con código nuevo.

---

## 7. Reproducción y caché local (crítico, no opcional)

**Regla de oro: el contenido multimedia se descarga UNA sola vez por archivo, nunca en
cada ciclo de reproducción.**

Flujo:
1. Visor escucha evento de cambio (Realtime) sobre el schedule/playlist publicado de
   su pantalla.
2. Al recibir el evento, hace fetch solo de la **metadata** (qué archivos, orden,
   horario) — no del archivo pesado todavía.
3. Compara la metadata contra lo que ya tiene cacheado localmente (filesystem del
   dispositivo — en RN usar `react-native-fs` o similar; `localStorage` NO sirve para
   binarios/videos).
4. Descarga **solo** los archivos nuevos o modificados (diff), en background, sin
   interrumpir lo que se está reproduciendo actualmente.
5. Reproduce siempre desde el archivo local cacheado — nunca en streaming directo
   desde Supabase Storage en cada loop.

**Por qué esto es innegociable:** sin caché local, un video en loop 24/7 agotaría el
egress del plan gratuito en horas, y la pantalla dependería de tener internet estable
en todo momento (un corte de wifi dejaría la pantalla en negro).

**Websocket en idle es prácticamente gratis** (solo heartbeats) — el consumo real de
banda está 100% concentrado en la descarga de contenido nuevo, que según la operación
esperada (pocos cambios al mes) es mínimo.

**Backup de seguridad:** considerar un polling de baja frecuencia (ej. cada 5 min) como
red de seguridad adicional al Realtime, para el caso de que el websocket se caiga y no
reconecte silenciosamente. No reemplaza el mecanismo principal, es solo respaldo.

---

## 8. Modelo comercial (referencia, no bloqueante para el MVP técnico)

Dos tiers principales:

- **Self-serve:** cliente administra su propio contenido vía el panel. Precio de
  referencia: similar a Juuno (~$5 USD/pantalla/mes) + margen (~$1 USD más).
- **Full-managed:** Octalink diseña, sube y administra todo el contenido. Rango de
  precio conversado: ~$45 USD/mes para 1-5 pantallas, escalando hacia arriba; tier
  enterprise con precio conversado según cantidad. Incluye un máximo definido de
  contenido nuevo por semana (ej. un slide nuevo/semana) como parte del SLA.

Este modelo justifica por qué se construye plataforma propia en vez de usar un white
label de terceros: se necesita control total del flujo de trabajo interno de la agencia
(un dashboard donde Octalink administra múltiples clientes con distintos niveles de
acceso y SLA), algo que las herramientas self-serve de terceros no resuelven bien.

---

## 9. Scope del MVP (v1)

**Dentro de v1:**
1. Visor + pairing (código corto, ver sección 6)
2. CRUD de pantallas
3. Upload de contenido (imagen y video, sin editor de diseño online)
4. CRUD de playlists (orden, duración por ítem, loop simple)
5. Schedule (asignar playlist a pantalla por rango horario/fecha)
6. Sync al player (Realtime + draft/publish, ver secciones 5 y 6)
7. Overlay de diagnóstico en el visor: identidad de pantalla + playlist actual,
   botón de refresh manual, botón fullscreen, disconnect/reset

**Fuera de v1 (deliberado):**
- Integraciones externas (Instagram, Canva, YouTube, RSS, etc.)
- Editor de diseño online (el contenido llega ya diseñado externamente)
- Zonas / split-screen
- Multi-tenant público (sí se necesita a nivel interno de Octalink vía RLS, pero no
  como feature expuesta al cliente)
- Apps nativas Tizen/LG (etapa futura post-validación)

---

## 10. Referencias técnicas revisadas (no para copiar, sí para inspirar decisiones)

- **Juuno** (`juuno.co`) — competidor SaaS validado, referencia directa de UX de
  pairing (código corto + URL de activación), overlay de diagnóstico en el visor
  (identidad de pantalla, memoria, user agent, cache management, disconnect), y
  confirmación de que Vue funciona bien como stack de visor en Smart TVs reales.
- **Anthias** (ex-Screenly OSE, `github.com/Screenly/Anthias`) — proyecto open source
  de signage más popular en GitHub. Referencia de arquitectura: separación estricta
  servidor/viewer como procesos distintos, cola async (Celery) para tareas pesadas
  como descargas, WebSocket + Redis para push de eventos (no polling), y soporte
  multi-hardware con un solo backend/panel y múltiples "streams" de build según
  dispositivo.
- **FreeKiosk** (`github.com/muhametismailii/FreeKiosk` o similar) — app de modo
  kiosco Android open source en React Native + WebView, mismo stack que la APK
  propia — referencia directa para el manejo de pantalla completa, auto-arranque,
  y supervivencia a reinicios.

---

## 11. Plan de pruebas recomendado — por dónde empezar

**Cuestionamiento del equipo:** no construir el panel completo primero. El panel es la
parte con **menor incertidumbre técnica** (CRUD de Vue contra Supabase — ya se ha hecho
en otros proyectos como RHL y QForest). El riesgo real y lo que vale la pena validar
primero es: pairing + Realtime + caché local + comportamiento en hardware real.

**Orden recomendado:**

1. **Visor web mínimo (Vue) + Supabase Studio manual** — sin construir panel propio
   todavía. Crear las tablas (`screens`, `pairing_codes`, `content`, `playlists`,
   `schedules`) directo en Supabase Studio, y simular el "panel admin" editando filas
   a mano ahí mismo. Esto valida el pairing, el websocket de Realtime, y la lógica de
   caché con una fracción del esfuerzo de construir un panel completo.
2. **Probar en hardware real**: el Onn con el visor cargado, y el navegador nativo de
   al menos una Smart TV real. Confirmar versión de Chromium, persistencia de
   almacenamiento entre reinicios, y si el modo pantalla completa real es alcanzable.
3. **Recién con el visor y el pairing confirmados en hardware real**, construir el
   panel — en ese punto es trabajo mecánico de bajo riesgo, no exploratorio.

---

## 12. Preguntas abiertas / pendientes de definir

- Largo y alfabeto exacto del código de pairing (definido: 4-6 caracteres, sin
  ambigüedad visual — falta cerrar el número exacto).
- Qué pasa en el panel cuando alguien escribe un código inválido o expirado (UX de
  error).
- Detalle exacto del overlay de diagnóstico del visor (qué mostrar, qué botones,
  prioridad de implementación).
- Política formal de compresión/limpieza de contenido para no tocar el límite de
  1 GB de storage.
- Definir si el "Publicar cambios" es por pantalla individual o permite batch
  (varias pantallas de un mismo cliente a la vez).
- Validar en hardware real (Onn + al menos una Smart TV) antes de cerrar del todo
  la arquitectura del visor-web.

---

*Última actualización: reunión de directorio + equipo de desarrollo, julio 2026.
Este documento debe vivir en los 4 repos (o ser referenciado desde ellos) y
actualizarse a medida que se tomen nuevas decisiones.*
```
