<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { supabase } from '../lib/supabase'
import { pruneBlobUrls, releaseAllBlobUrls, resolveMedia } from '../lib/mediaCache'
import Overlay from './Overlay.vue'

const props = defineProps({
  deviceUuid: { type: String, required: true },
})

const emit = defineEmits(['disconnected'])

const items = ref([])
const currentIndex = ref(0)
const error = ref(null)
const fullscreenPrimed = ref(false)
const displaySrc = ref(null)
// url remota -> { url, source } devuelto por resolveMedia
let resolved = new Map()
let resolveGeneration = 0
const screenName = ref(null)
const playlistName = ref(null)
const overlayVisible = ref(false)

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
  const item = currentItem.value
  if (!item) return

  if (item.type === 'image') {
    imageTimer = setTimeout(advance, item.duration * 1000)
  }
  // Para video, el avance lo dispara el evento @ended del <video>.
}

function playCurrentItem() {
  scheduleCurrentItem()
  const item = currentItem.value
  displaySrc.value = item ? (resolved.get(item.url)?.url ?? null) : null

  if (item?.type === 'video' && videoEl.value) {
    videoEl.value.currentTime = 0
    videoEl.value.play()
  }
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
  const { data: screen, error: screenError } = await supabase
    .from('screens')
    .select('name, current_playlist_id')
    .eq('device_uuid', props.deviceUuid)
    .single()

  if (screenError) {
    error.value = `No se pudo leer la pantalla: ${screenError.message}`
    return
  }

  screenName.value = screen.name

  if (!screen?.current_playlist_id) {
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
      { event: 'UPDATE', schema: 'public', table: 'screens', filter: `device_uuid=eq.${props.deviceUuid}` },
      async (payload) => {
        if (payload.new.status !== 'paired') {
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
    .subscribe()
}

function activateFullscreen() {
  document.documentElement.requestFullscreen?.().catch(() => {})
  fullscreenPrimed.value = true
}

function toggleOverlay() {
  overlayVisible.value = !overlayVisible.value
}

onMounted(async () => {
  await loadScreen()
  subscribeToScreen()
})

onUnmounted(() => {
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
    />
    <p v-else-if="error" class="message">{{ error }}</p>

    <button v-if="!fullscreenPrimed" class="fullscreen-button" @click.stop="activateFullscreen">
      Pantalla completa
    </button>

    <Overlay
      v-if="overlayVisible"
      :device-uuid="props.deviceUuid"
      :screen-name="screenName"
      :playlist-name="playlistName"
      @close="overlayVisible = false"
      @disconnected="emit('disconnected')"
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

.message {
  color: #fff;
  font-family: sans-serif;
  font-size: 1.5rem;
  text-align: center;
  padding: 2rem;
}

.fullscreen-button {
  position: fixed;
  top: 1rem;
  right: 1rem;
  padding: 0.5rem 1rem;
  background: #fff;
  color: #000;
  border: none;
  border-radius: 4px;
  font-family: sans-serif;
  font-size: 1rem;
  cursor: pointer;
}
</style>
