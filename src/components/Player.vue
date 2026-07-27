<script setup>
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { supabase } from '../lib/supabase'
import { getCachedBlobUrl } from '../lib/mediaCache'
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
const resolvedUrls = new Map()
const screenName = ref(null)
const playlistName = ref(null)
const overlayVisible = ref(false)

const currentPlaylistId = ref(null)
let lastPublishedAt = null
let screenChannel = null
let playlistChannel = null

const currentItem = computed(() => items.value[currentIndex.value] ?? null)

let imageTimer = null

function advance() {
  if (items.value.length === 0) return
  currentIndex.value = (currentIndex.value + 1) % items.value.length
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

function onVideoEnded() {
  advance()
}

function clearResolvedUrls() {
  for (const blobUrl of resolvedUrls.values()) {
    URL.revokeObjectURL(blobUrl)
  }
  resolvedUrls.clear()
}

async function resolveItems(itemsToResolve) {
  for (const item of itemsToResolve) {
    resolvedUrls.set(item.url, await getCachedBlobUrl(item.url))
  }
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

  // La primera vez que se ve un archivo puede venir directo de la red (ver
  // displaySrc más abajo); desde la segunda vuelta en adelante ya sale del cache.
  clearResolvedUrls()
  resolveItems(items.value)
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
  clearResolvedUrls()
})

watch(currentItem, (item) => {
  scheduleCurrentItem()
  displaySrc.value = item ? (resolvedUrls.get(item.url) ?? item.url) : null
})
</script>

<template>
  <div class="player" @click="toggleOverlay">
    <img v-if="currentItem?.type === 'image'" :key="currentItem.url" :src="displaySrc" class="media" />
    <video
      v-else-if="currentItem?.type === 'video'"
      :key="currentItem.url"
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
