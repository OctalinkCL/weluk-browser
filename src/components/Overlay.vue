<script setup>
import { computed, onMounted, ref } from 'vue'
import { APP_VERSION } from '../lib/version'
import {
  cacheApiAvailable,
  cacheStats,
  clearMediaCache,
  estimateStorage,
  listCachedUrls,
} from '../lib/mediaCache'

const props = defineProps({
  deviceUuid: { type: String, required: true },
  screenName: { type: String, default: null },
  playlistName: { type: String, default: null },
  mediaStatus: { type: String, default: null },
})

const emit = defineEmits(['close'])

const cachedUrls = ref(null)

const screenResolution = `${window.screen.width}x${window.screen.height}`
const userAgent = navigator.userAgent
// performance.memory es no estándar (solo Chrome/Chromium), pero cubre la mayoría
// de Smart TVs — útil para detectar memory leaks en sesiones de 24h+ (sección 3
// del CLAUDE.md) sin necesitar devtools conectado a la TV.
const memoryInfo = performance.memory
  ? `${(performance.memory.usedJSHeapSize / 1048576).toFixed(1)} / ${(performance.memory.totalJSHeapSize / 1048576).toFixed(1)} MiB`
  : null

const storageEstimate = ref(null)

function formatBytes(bytes) {
  if (bytes == null) return '—'
  if (bytes < 1048576) return `${(bytes / 1024).toFixed(1)} KiB`
  if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(1)} MiB`
  return `${(bytes / 1073741824).toFixed(2)} GiB`
}

// Sin esto el visor puede estar streameando desde Supabase en cada vuelta del loop sin
// que nadie se entere hasta ver la factura de egress. La Cache API se cae en silencio
// fuera de un contexto seguro (HTTP por IP de LAN) o en navegadores previos a Chrome 40.
const cacheState = computed(() => {
  if (!window.isSecureContext) return 'DEGRADADO — contexto inseguro (usa HTTPS)'
  if (!cacheApiAvailable) return 'DEGRADADO — navegador sin Cache API'
  if (cacheStats.writeFailures > 0) return 'PARCIAL — solo en memoria (falla la escritura a disco)'
  return 'OK — persistente en disco'
})

const cacheHealthy = computed(() => cacheState.value.startsWith('OK'))

const persistentLabel = computed(() => {
  if (cacheStats.persistent === null) return 'No disponible en este navegador'
  return cacheStats.persistent ? 'Concedida' : 'Denegada (desalojable)'
})

const storageLabel = computed(() => {
  if (!storageEstimate.value) return '—'
  const { usage, quota } = storageEstimate.value
  return `${formatBytes(usage)} / ${formatBytes(quota)}`
})

function forceRefresh() {
  location.reload()
}

function activateFullscreen() {
  document.documentElement.requestFullscreen?.().catch(() => {})
}

async function refreshCacheList() {
  cachedUrls.value = (await listCachedUrls()) ?? []
  storageEstimate.value = await estimateStorage()
}

async function clearCache() {
  await clearMediaCache()
  cachedUrls.value = []
  storageEstimate.value = await estimateStorage()
}

onMounted(async () => {
  storageEstimate.value = await estimateStorage()
})

// Acá vivía "Disconnect this screen", que llamaba a la RPC disconnect_own_screen.
// Se eliminó por seguridad (2 agosto 2026): esa RPC era ejecutable por `anon` y su
// único parámetro es el device_uuid, que cualquiera puede leer porque el SELECT de
// `anon` sobre `screens` está abierto. Con la anon key (pública, va en este bundle)
// se podían enumerar y borrar las pantallas de todos los clientes sin login.
// Desvincular ahora se hace desde el panel ("Eliminar"), que sí valida ownership real
// vía RLS; el DELETE llega igual por Realtime y el visor vuelve a pairing solo.
// Ver docs/04-incidentes.md § Segundo análisis de seguridad.
</script>

<template>
  <div class="overlay" @click.stop>
    <div class="header">
      <div>
        <p class="label">Pantalla</p>
        <p class="value">{{ screenName ?? '—' }}</p>
      </div>
      <button class="close" @click="emit('close')">×</button>
    </div>

    <p class="label">Playlist actual</p>
    <p class="value">{{ playlistName ?? '—' }}</p>

    <p class="label">Versión</p>
    <p class="value">v{{ APP_VERSION }}</p>

    <p class="label">Device UUID</p>
    <p class="value small">{{ deviceUuid }}</p>

    <p class="label">Resolución</p>
    <p class="value">{{ screenResolution }}</p>

    <p class="label">Memoria (usada / total)</p>
    <p class="value">{{ memoryInfo ?? 'No disponible en este navegador' }}</p>

    <p class="label">Agente</p>
    <p class="value small">{{ userAgent }}</p>

    <template v-if="mediaStatus">
      <p class="label">Reproducción</p>
      <p class="value warn small">{{ mediaStatus }}</p>
    </template>

    <p class="label">Estado del caché</p>
    <p class="value" :class="cacheHealthy ? 'ok' : 'warn'">{{ cacheState }}</p>

    <template v-if="cacheStats.writeFailures > 0">
      <p class="label">Error de escritura ({{ cacheStats.writeFailures }})</p>
      <p class="value warn small">{{ cacheStats.writeError }}</p>
      <p class="value small">{{ cacheStats.writeErrorUrl }}</p>
    </template>

    <p class="label">Descargado en esta sesión</p>
    <p class="value">
      {{ formatBytes(cacheStats.bytesDownloaded) }}
      <span class="small">({{ cacheStats.networkFetches }} descargas de red)</span>
    </p>

    <p class="label">Servido sin red</p>
    <p class="value small">
      {{ cacheStats.diskHits }} desde disco · {{ cacheStats.memoryHits }} desde memoria
    </p>

    <p v-if="cacheStats.remoteFallbacks > 0" class="value warn small">
      {{ cacheStats.remoteFallbacks }} archivo(s) no se pudieron cachear y se sirven remotos.
    </p>

    <p class="label">Almacenamiento persistente</p>
    <p class="value small">{{ persistentLabel }}</p>

    <p class="label">Uso de disco</p>
    <p class="value small">{{ storageLabel }}</p>

    <div class="actions">
      <button @click="forceRefresh">Forzar refresh</button>
      <button @click="activateFullscreen">Pantalla completa</button>
      <button @click="refreshCacheList">Listar cache</button>
      <button @click="clearCache">Vaciar cache</button>
    </div>

    <ul v-if="cachedUrls" class="cache-list">
      <li v-if="cachedUrls.length === 0">Cache vacío.</li>
      <li v-for="url in cachedUrls" :key="url">{{ url }}</li>
    </ul>
  </div>
</template>

<style scoped>
.overlay {
  position: fixed;
  top: 1rem;
  left: 1rem;
  width: 22rem;
  max-height: calc(100vh - 2rem);
  overflow-y: auto;
  background: rgba(0, 0, 0, 0.9);
  color: #fff;
  font-family: sans-serif;
  padding: 1rem;
  border-radius: 8px;
}

.header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
}

.close {
  background: none;
  border: none;
  color: #fff;
  font-size: 1.5rem;
  line-height: 1;
  cursor: pointer;
}

.label {
  color: #999;
  font-size: 0.8rem;
  margin-top: 0.75rem;
}

.value {
  font-size: 1rem;
}

.value.small,
.value .small {
  font-size: 0.75rem;
  word-break: break-all;
}

.value.ok {
  color: #6c6;
}

.value.warn {
  color: #fa4;
}

.actions {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  margin-top: 1rem;
}

.actions button {
  background: #222;
  color: #fff;
  border: 1px solid #444;
  border-radius: 4px;
  padding: 0.4rem 0.6rem;
  font-size: 0.85rem;
  cursor: pointer;
}

.cache-list {
  margin-top: 0.75rem;
  padding-left: 1rem;
  font-size: 0.7rem;
  color: #ccc;
  word-break: break-all;
}

</style>
