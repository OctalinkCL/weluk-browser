# weluk-browser — Contexto de Claude Code

> Este repo es parte de **Weluk** (Octalink SpA), plataforma de digital signage. El contexto
> compartido del producto vive en `../weluk-docs` (symlinkeado acá como `docs/`). **Leer
> `docs/03-contratos.md` antes de tocar pairing, caché, Realtime, Schedule o el modelo de
> datos:** son reglas que ya se pagaron en sangre en otros repos del mismo producto.
>
> ⚠️ Al momento de centralizar los docs (2 agosto 2026), este repo tenía una copia de
> `weluk-schema.sql` **desactualizada** (le faltaban `slug`, `is_active`, `thumbnail_path`,
> `auth_active_company_id()` y las policies nuevas de `company_admin`). Se eliminó — la
> fuente única ahora es `docs/weluk-schema.sql`. Si algo en este repo asumía la versión
> vieja del schema, revisar contra la real.

Última lectura de `docs/DECISIONES.md`: 2026-08-02

## Setup del symlink (una vez por máquina)

Ya está creado en este checkout. Si clonás el repo en una máquina nueva:

```bash
cd weluk-browser
ln -s ../weluk-docs docs   # requiere weluk-docs clonado como hermano de este repo
```

## Contexto compartido (@docs)

- @docs/00-producto.md — qué es Weluk, modelo comercial, scope del MVP
- @docs/01-arquitectura.md — repos, stack, matriz de hardware real (**leer antes de tocar
  el player o el caché** — tres dispositivos reales fallan de formas no obvias)
- @docs/02-datos.md — Supabase, modelo de datos, RLS, storage
- @docs/03-contratos.md — **reglas obligatorias** (caché, pairing, presence, escrituras, Schedule)
- @docs/04-incidentes.md — postmortems, el "por qué" de cada regla
- @docs/weluk-schema.sql — fuente autoritativa del esquema

---

## Qué está implementado en este repo

- **Pairing**: código corto + claim vía panel, canal Realtime abierto desde antes de que
  se reclame. Ver `docs/03-contratos.md § 4` para el flujo completo y los parámetros
  (5 caracteres, alfabeto, expiración).
- **Caché local**: Cache API (`caches.open()`, `src/lib/mediaCache.js`) con la cascada de
  3 niveles memoria → disco → red. Ver `docs/03-contratos.md § 2` para las 7 reglas
  innegociables y `docs/04-incidentes.md § Incidente de egress` para el postmortem que las
  originó — **no relajar ninguna sin releer eso primero**.
- **`device.js`**: `device_uuid` persistente en `localStorage`, con fallback manual de
  generación de UUID cuando `crypto.randomUUID` no existe (ver `docs/01-arquitectura.md`).
- **`pairingCode.js`**: código pendiente persistido junto a `expires_at` — un refresh
  mientras sigue vigente lo reusa; al expirar, un timer genera uno nuevo solo.
- **Watchdog de reproducción**: si a los 10 s no llegó `playing`, fuerza `advance()`. Ver
  `docs/03-contratos.md § 3` — hay hardware real donde `blob:` en `<video>` falla mudo.
- **Presence**: `channel.track(...)` una sola vez por suscripción sobre el canal
  `screen-${device_uuid}` existente, re-emitido tras cada reconexión. Ver
  `docs/03-contratos.md § 5`.
- **Disconnect/delete**: escucha `event: '*'` (no solo `'UPDATE'`) y trata `DELETE` igual
  que un disconnect; `loadScreen()` usa `.maybeSingle()`; "Disconnect" del overlay llama a
  la RPC `disconnect_own_screen`, no un `UPDATE` directo. Ver
  `docs/04-incidentes.md § Fix de seguridad` y `§ Eliminar pantalla en un solo paso`.
- **Overlay de diagnóstico** (`Overlay.vue`): identidad de pantalla + playlist actual,
  `device_uuid`, versión del build (`APP_VERSION` en `src/lib/version.js`, incrementada a
  mano en cada cambio relevante desplegado — no atada a `package.json`, permite confirmar
  en una TV real, sin devtools, que corre el build esperado), resolución, memoria (heap
  usado/total — **no confiable en TVs**, ver `docs/01-arquitectura.md`), user agent,
  refresh manual, fullscreen, listar/vaciar caché, disconnect real, y estado del caché
  (contexto seguro, API disponible, bytes descargados en la sesión, hits, cuota).
- **`duration_seconds` para video**: el avance ya no depende solo del evento nativo
  `@ended` — respeta la duración configurada desde el panel si está seteada.

## Qué falta en este repo

- **Schedule** — diseño acordado en `docs/03-contratos.md § 7`, nada implementado. El
  cambio de playlist por hora lo ejecuta la pantalla (timer local ~30s sobre reglas y
  contenido ya precacheados), no el servidor — leer esa sección completa antes de
  empezar, especialmente el ajuste obligatorio a la limpieza de huérfanos en disco y el
  manejo del offset de reloj.
- **`screens.last_seen_at`** — Presence resuelve "ahora mismo" pero nadie escribe esta
  columna todavía. Ver `docs/PENDIENTES.md`.
- Repetir la validación de `@vitejs/plugin-legacy` en el box Onn — nunca se probó (su
  relevancia bajó con la decisión de usar box/stick + APK, ver `docs/01-arquitectura.md`).

---

## Gotchas específicos de este repo

### `Player.vue` — asignación reactiva de `src` no llega al DOM de inmediato

`displaySrc.value = ...` es reactivo en Vue, no se aplica al DOM en el mismo tick. Llamar
`videoEl.value.play()` en la misma función corre contra un `<video>` que todavía tiene el
`src` anterior. Fix: `await nextTick()` antes de tocar el elemento, más `el.load()`
explícito cuando el `src` cambió (algunos navegadores de TV no recargan solos al cambiar
el `src` de un elemento ya montado). Ver postmortem completo en
`docs/04-incidentes.md § Bug de reproducción tras quitar el fallback remoto`.

### Playlist de un solo ítem

El índice `(0 + 1) % 1 = 0` no cambia de valor, así que nada disparaba el reinicio del loop.
Cuando el índice no cambia, se fuerza el reinicio a mano (reset de `currentTime` + `.play()`
para video, re-agendar el timer para imagen). Es un caso válido y soportado, no un estado raro.

### `evictStaleDisk()` en `mediaCache.js`

Se llama **solo** cuando cambia qué debería estar cacheado (playlist republicada), **nunca**
al desconectar o desmontar el player — una reconexión rápida con la misma playlist debe poder
reusar lo que ya hay en disco. Ver `docs/04-incidentes.md § Huérfanos en disco`.

> **Cuando se implemente Schedule, esta función necesita recibir el conjunto completo de
> archivos alcanzables (playlist por defecto + todas las de las reglas), no los de una sola
> playlist** — si no, cada cambio de turno vuelve a descargar la playlist que acaba de salir.
> Ver `docs/03-contratos.md § 7 — Ajuste obligatorio del caché` antes de tocar esta función.
