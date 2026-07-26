<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { supabase } from '../lib/supabase'
import { DEVICE_UUID } from '../config'

const items = ref([])
const currentIndex = ref(0)
const error = ref(null)
const fullscreenPrimed = ref(false)

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

async function loadPlaylist() {
  const { data: screen, error: screenError } = await supabase
    .from('screens')
    .select('current_playlist_id')
    .eq('device_uuid', DEVICE_UUID)
    .single()

  if (screenError) {
    error.value = `No se pudo leer la pantalla: ${screenError.message}`
    return
  }

  if (!screen?.current_playlist_id) {
    error.value = 'La pantalla no tiene una playlist asignada.'
    return
  }

  const { data: playlistItems, error: itemsError } = await supabase
    .from('playlist_items')
    .select('order_index, duration_seconds, media(type, storage_path, duration_seconds)')
    .eq('playlist_id', screen.current_playlist_id)
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

  if (items.value.length === 0) {
    error.value = 'La playlist no tiene contenido.'
  }
}

function activateFullscreen() {
  document.documentElement.requestFullscreen?.().catch(() => {})
  fullscreenPrimed.value = true
}

onMounted(async () => {
  await loadPlaylist()
})

watch(currentItem, () => {
  scheduleCurrentItem()
})
</script>

<template>
  <div class="player">
    <img v-if="currentItem?.type === 'image'" :key="currentItem.url" :src="currentItem.url" class="media" />
    <video
      v-else-if="currentItem?.type === 'video'"
      :key="currentItem.url"
      :src="currentItem.url"
      class="media"
      autoplay
      muted
      playsinline
      @ended="onVideoEnded"
    />
    <p v-else-if="error" class="message">{{ error }}</p>

    <button v-if="!fullscreenPrimed" class="fullscreen-button" @click="activateFullscreen">
      Pantalla completa
    </button>
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
