<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { supabase } from '../lib/supabase'
import { evictStaleDisk, pruneBlobUrls, releaseAllBlobUrls, resolveMedia } from '../lib/mediaCache'
import Overlay from './Overlay.vue'

const props = defineProps({
  deviceUuid: { type: String, required: true },
})

const emit = defineEmits(['disconnected'])

const items = ref([])
const currentIndex = ref(0)
const error = ref(null)
const displaySrc = ref(null)
// url remota -> { url, source } devuelto por resolveMedia
let resolved = new Map()
let resolveGeneration = 0
const screenName = ref(null)
const playlistName = ref(null)
const overlayVisible = ref(false)
// Diagnóstico de reproducción para el overlay: en una TV no hay devtools, así que este
// texto es la única pista de por qué la pantalla está en negro.
const mediaStatus = ref(null)
let playbackWatchdog = null
let videoDurationTimer = null

const currentPlaylistId = ref(null)
let lastPublishedAt = null
let screenChannel = null
let playlistChannel = null

const currentItem = computed(() => items.value[currentIndex.value] ?? null)
const videoEl = ref(null)

let imageTimer = null

function advance() {
  if (items.value.length === 0) return
  const nextIndex = (currentIndex.value + 1) % items.value.length
  if (nextIndex === currentIndex.value) {
    // Playlist de un solo ítem: el índice no cambia, así que nada dispara el watcher
    // de forma natural — forzamos el reinicio a mano para que igual loopee.
    showCurrentItem()
  } else {
    currentIndex.value = nextIndex
  }
}

function scheduleCurrentItem() {
  clearTimeout(imageTimer)
  clearTimeout(videoDurationTimer)
  const item = currentItem.value
  if (!item) return

  if (item.type === 'image') {
    imageTimer = setTimeout(advance, item.duration * 1000)
  }
  // Para video, el corte por duración se arma recién en el evento `playing` (ver
  // armVideoDurationTimer) — así el tiempo de buffering antes de arrancar no le resta
  // segundos a la duración configurada. Si no hay duración válida, manda el @ended nativo.
}

async function playCurrentItem() {
  scheduleCurrentItem()
  const item = currentItem.value
  const nextSrc = item ? (resolved.get(item.url)?.url ?? null) : null
  const srcChanged = displaySrc.value !== nextSrc
  displaySrc.value = nextSrc

  if (item?.type !== 'video' || !nextSrc) return

  // Vue aplica el src en su flush, no en la asignación de arriba. Sin esperar el tick,
  // .play() corre contra el <video> que todavía tiene el src anterior (vacío) y no
  // arranca nada; y como :key no cambia, el atributo autoplay tampoco vuelve a
  // dispararse. Eso dejaba la pantalla en negro para siempre.
  await nextTick()

  const el = videoEl.value
  if (!el) return

  // load() explícito: los navegadores viejos de Smart TV no siempre recargan solos al
  // cambiar el src de un elemento ya montado.
  if (srcChanged) el.load()

  try {
    el.currentTime = 0
  } catch {
    // Algunos navegadores lanzan si el media todavía no tiene metadata cargada.
  }

  armPlaybackWatchdog()

  const played = el.play()
  if (played && played.catch) played.catch((err) => {
    mediaStatus.value = `play() rechazado: ${err?.name ?? err}`
  })
}

// Una pantalla de signage no puede quedarse en negro indefinidamente si el video no
// arranca (códec no soportado, blob: no reproducible en esa TV, etc.). Si en 10 s no
// llegó el evento `playing`, se reporta y se avanza.
function armPlaybackWatchdog() {
  clearTimeout(playbackWatchdog)
  playbackWatchdog = setTimeout(() => {
    mediaStatus.value = 'El video no empezó a reproducirse en 10 s — se fuerza el avance.'
    advance()
  }, 10000)
}

// Corta el video antes si `duration_seconds` (configurado en el panel) es menor a su
// largo real. Si el video termina solo antes de que este timer dispare, onVideoEnded
// ya lo cancela — así nunca hay doble avance.
function armVideoDurationTimer(durationSeconds) {
  clearTimeout(videoDurationTimer)
  if (!Number.isFinite(durationSeconds)) return
  videoDurationTimer = setTimeout(advance, durationSeconds * 1000)
}

function onVideoPlaying() {
  clearTimeout(playbackWatchdog)
  mediaStatus.value = null
  armVideoDurationTimer(currentItem.value?.duration)
}

function onVideoError() {
  clearTimeout(playbackWatchdog)
  const code = videoEl.value?.error?.code
  mediaStatus.value = `El <video> falló (MediaError code ${code ?? '?'}). ¿La TV no reproduce blob: URLs?`
}

// Nunca mostramos `item.url` (la URL remota de Supabase) mientras esperamos: hacerlo
// era lo que provocaba que el elemento bajara el archivo por su cuenta, en paralelo al
// fetch del caché primero, y en cada vuelta del loop después. Preferimos negro un
// instante — la regla de oro de la sección 7 no se negocia.
async function showCurrentItem() {
  const item = currentItem.value

  if (!item) {
    clearTimeout(imageTimer)
    displaySrc.value = null
    return
  }

  if (!resolved.has(item.url)) {
    clearTimeout(imageTimer)
    displaySrc.value = null
    await resolveItem(item)
    if (currentItem.value !== item) return
  }

  playCurrentItem()
}

function onVideoEnded() {
  clearTimeout(playbackWatchdog)
  clearTimeout(videoDurationTimer)
  advance()
}

async function resolveItem(item) {
  if (!item || resolved.has(item.url)) return
  resolved.set(item.url, await resolveMedia(item.url))
}

// Precarga el resto de la playlist en background, sin interrumpir lo que se reproduce.
// La generación evita que una playlist vieja siga resolviendo tras un cambio.
async function resolveRemaining(generation) {
  for (const item of items.value) {
    if (generation !== resolveGeneration) return
    await resolveItem(item)
  }
}

// Descarta las entradas de archivos que ya no están en la playlist y revoca sus blob
// URLs, para que la memoria quede acotada al contenido vigente.
function pruneResolved(urls) {
  const keep = new Set(urls)
  const next = new Map()

  for (const [url, entry] of resolved) {
    if (keep.has(url)) next.set(url, entry)
  }

  resolved = next
  pruneBlobUrls(urls)
  evictStaleDisk(urls)
}

async function fetchAndSetItems(playlistId, { resetIndex }) {
  const { data: playlistItems, error: itemsError } = await supabase
    .from('playlist_items')
    .select('order_index, duration_seconds, media(type, storage_path, duration_seconds)')
    .eq('playlist_id', playlistId)
    .order('order_index', { ascending: true })

  if (itemsError) {
    error.value = `No se pudieron leer los items de la playlist: ${itemsError.message}`
    return
  }

  items.value = (playlistItems ?? []).map((item) => ({
    type: item.media.type,
    url: supabase.storage.from('media').getPublicUrl(item.media.storage_path).data.publicUrl,
    duration: item.duration_seconds ?? item.media.duration_seconds,
  }))

  if (resetIndex || currentIndex.value >= items.value.length) {
    currentIndex.value = 0
  }

  error.value = items.value.length === 0 ? 'La playlist no tiene contenido.' : null

  // Conservamos lo ya resuelto que siga en la playlist (una republicación que solo
  // reordena ítems no debe re-descargar nada) y soltamos el resto.
  resolveGeneration += 1
  pruneResolved(items.value.map((item) => item.url))
  resolveRemaining(resolveGeneration)
}

function teardownPlaylistChannel() {
  if (playlistChannel) {
    supabase.removeChannel(playlistChannel)
    playlistChannel = null
  }
}

function subscribeToPlaylist(playlistId) {
  teardownPlaylistChannel()

  playlistChannel = supabase
    .channel(`playlist-${playlistId}`)
    .on(
      'postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'playlists', filter: `id=eq.${playlistId}` },
      (payload) => {
        // Solo reaccionar cuando cambia published_at (contenido publicado), nunca con
        // updated_at (edición a medio hacer) — ver sección 5 del CLAUDE.md.
        if (payload.new.published_at === lastPublishedAt) return
        lastPublishedAt = payload.new.published_at
        fetchAndSetItems(playlistId, { resetIndex: false })
      },
    )
    .subscribe()
}

async function setPlaylist(playlistId, { resetIndex }) {
  currentPlaylistId.value = playlistId

  const { data: playlist, error: playlistError } = await supabase
    .from('playlists')
    .select('name, published_at')
    .eq('id', playlistId)
    .single()

  if (playlistError) {
    error.value = `No se pudo leer la playlist: ${playlistError.message}`
    return
  }

  playlistName.value = playlist.name
  lastPublishedAt = playlist.published_at
  await fetchAndSetItems(playlistId, { resetIndex })
  subscribeToPlaylist(playlistId)
}

async function loadScreen() {
  // maybeSingle, no single: la fila puede haber sido borrada (Disconnect propio o un
  // admin borrándola desde el panel) justo entre el chequeo inicial de App.vue y este
  // mount — 0 filas es un estado válido, no un error de red/config.
  const { data: screen, error: screenError } = await supabase
    .from('screens')
    .select('name, current_playlist_id')
    .eq('device_uuid', props.deviceUuid)
    .maybeSingle()

  if (screenError) {
    error.value = `No se pudo leer la pantalla: ${screenError.message}`
    return
  }

  if (!screen) {
    emit('disconnected')
    return
  }

  screenName.value = screen.name

  if (!screen.current_playlist_id) {
    error.value = 'La pantalla no tiene una playlist asignada.'
    return
  }

  await setPlaylist(screen.current_playlist_id, { resetIndex: true })
}

function subscribeToScreen() {
  screenChannel = supabase
    .channel(`screen-${props.deviceUuid}`)
    .on(
      'postgres_changes',
      // '*' en vez de solo 'UPDATE': "Disconnect" ahora borra la fila (DELETE) en vez
      // de marcarla 'disconnected' — un admin también puede borrarla directo desde el
      // panel mientras está paired. Requiere REPLICA IDENTITY FULL en screens (ver
      // weluk-schema.sql) para que el filtro por device_uuid matchee en un DELETE.
      { event: '*', schema: 'public', table: 'screens', filter: `device_uuid=eq.${props.deviceUuid}` },
      async (payload) => {
        if (payload.eventType === 'DELETE' || payload.new.status !== 'paired') {
          emit('disconnected')
          return
        }

        const newPlaylistId = payload.new.current_playlist_id
        if (newPlaylistId === currentPlaylistId.value) return

        if (!newPlaylistId) {
          teardownPlaylistChannel()
          currentPlaylistId.value = null
          items.value = []
          currentIndex.value = 0
          resolveGeneration += 1
          pruneResolved([])
          error.value = 'La pantalla no tiene una playlist asignada.'
          return
        }

        await setPlaylist(newPlaylistId, { resetIndex: true })
      },
    )
    .subscribe((status) => {
      // El panel escucha presence.sync sobre este mismo canal para mostrar
      // online/offline en tiempo real (sección 5 del CLAUDE.md). track() una vez por
      // conexión confirmada — no hace falta loop/timer, Supabase ya detecta sola la
      // caída del websocket. Puede repetirse tras una reconexión (SUBSCRIBED de
      // vuelta), y hay que re-anunciarse en ese caso: el servidor descarta el
      // presence viejo cuando el socket se cae.
      if (status === 'SUBSCRIBED') {
        screenChannel.track({ online_at: new Date().toISOString() })
      }
    })
}

// handleDisconnected() vivía acá: lo llamaba el botón "Disconnect" del overlay, que se
// eliminó por seguridad (ver Overlay.vue y docs/04-incidentes.md § Segundo análisis de
// seguridad). El visor ya no inicia desconexiones — solo reacciona a las que vienen del
// panel, por el canal de subscribeToScreen(), que sigue emitiendo 'disconnected' igual.

function toggleOverlay() {
  overlayVisible.value = !overlayVisible.value
}

onMounted(async () => {
  await loadScreen()
  subscribeToScreen()
})

onUnmounted(() => {
  clearTimeout(imageTimer)
  clearTimeout(playbackWatchdog)
  clearTimeout(videoDurationTimer)
  if (screenChannel) supabase.removeChannel(screenChannel)
  teardownPlaylistChannel()
  resolveGeneration += 1
  resolved = new Map()
  releaseAllBlobUrls()
})

watch(currentItem, () => {
  showCurrentItem()
})
</script>

<template>
  <div class="player" @click="toggleOverlay">
    <Transition name="fade" mode="out-in">
      <img v-if="currentItem?.type === 'image'" :key="currentItem.url" :src="displaySrc" class="media" />
      <video
        v-else-if="currentItem?.type === 'video'"
        :key="currentItem.url"
        ref="videoEl"
        :src="displaySrc"
        class="media"
        autoplay
        muted
        playsinline
        @ended="onVideoEnded"
        @playing="onVideoPlaying"
        @error="onVideoError"
      />
      <p v-else-if="error" class="message">{{ error }}</p>
    </Transition>

    <Overlay
      v-if="overlayVisible"
      :device-uuid="props.deviceUuid"
      :screen-name="screenName"
      :playlist-name="playlistName"
      :media-status="mediaStatus"
      @close="overlayVisible = false"
    />
  </div>
</template>

<style scoped>
.player {
  height: 100vh;
  width: 100vw;
  background: #000;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
}

.media {
  width: 100vw;
  height: 100vh;
  object-fit: cover;
}

.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.5s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

.message {
  color: #fff;
  font-family: sans-serif;
  font-size: 1.5rem;
  text-align: center;
  padding: 2rem;
}
</style>
