import { reactive } from 'vue'

export const MEDIA_CACHE_NAME = 'weluk-media-v1'

// La Cache API solo existe en contextos seguros (HTTPS o localhost) y recién desde
// Chrome 40 — mismo tipo de trampa que `crypto.randomUUID` (CLAUDE.md sección 3).
// Una Smart TV vieja, o cualquier dispositivo probado por IP de LAN en HTTP plano,
// queda fuera por una razón o por la otra.
export const cacheApiAvailable = typeof caches !== 'undefined'

// Nivel 2 de la cascada: blob URLs vivos en memoria, indexados por URL remota. Existe
// para que un dispositivo SIN Cache API igual descargue cada archivo una sola vez por
// sesión, en vez de una vez por vuelta del loop. Esta era la falla que quemó 8.58 GB
// de egress en un par de horas con 3 pantallas.
const blobUrls = new Map()

// Resoluciones en vuelo, para que dos llamadas concurrentes sobre el mismo archivo
// (el ítem que se va a reproducir + la precarga en background) compartan una sola
// descarga en vez de disparar dos.
const inFlight = new Map()

export const cacheStats = reactive({
  bytesDownloaded: 0,
  networkFetches: 0,
  diskHits: 0,
  memoryHits: 0,
  remoteFallbacks: 0,
  quotaExceeded: false,
  persistent: null,
})

// El Cache Storage es "best effort": el navegador lo puede desalojar bajo presión de
// memoria, justo lo que pasa en una TV de 1-2 GB corriendo 24/7. La persistencia no
// siempre se concede, pero cuando se concede evita re-descargar toda la playlist.
export async function requestPersistentStorage() {
  if (!navigator.storage?.persist) return null

  try {
    cacheStats.persistent =
      (await navigator.storage.persisted?.()) || (await navigator.storage.persist())
  } catch {
    cacheStats.persistent = null
  }

  return cacheStats.persistent
}

export async function estimateStorage() {
  if (!navigator.storage?.estimate) return null

  try {
    return await navigator.storage.estimate()
  } catch {
    return null
  }
}

async function openCache() {
  if (!cacheApiAvailable) return null

  try {
    return await caches.open(MEDIA_CACHE_NAME)
  } catch {
    return null
  }
}

// Devuelve { url, source } — source es 'memory' | 'disk' | 'network' | 'remote'.
// 'remote' es el único caso que puede volver a consumir egress en el loop, y solo
// ocurre si la descarga falló (sin red, 404): ahí no hay nada mejor que ofrecer.
export function resolveMedia(remoteUrl) {
  const pending = inFlight.get(remoteUrl)
  if (pending) return pending

  const promise = resolveUncached(remoteUrl).finally(() => inFlight.delete(remoteUrl))
  inFlight.set(remoteUrl, promise)
  return promise
}

async function resolveUncached(remoteUrl) {
  const memoized = blobUrls.get(remoteUrl)
  if (memoized) {
    cacheStats.memoryHits += 1
    return { url: memoized, source: 'memory' }
  }

  const cache = await openCache()

  if (cache) {
    // ignoreVary: Supabase Storage sirve por su CDN y devuelve headers `Vary`; sin
    // esto un match legítimo puede fallar y disparar una re-descarga fantasma.
    const hit = await cache.match(remoteUrl, { ignoreVary: true }).catch(() => null)

    if (hit) {
      const url = URL.createObjectURL(await hit.blob())
      blobUrls.set(remoteUrl, url)
      cacheStats.diskHits += 1
      return { url, source: 'disk' }
    }
  }

  let fetched
  try {
    fetched = await fetch(remoteUrl)
  } catch {
    cacheStats.remoteFallbacks += 1
    return { url: remoteUrl, source: 'remote' }
  }

  if (!fetched.ok) {
    cacheStats.remoteFallbacks += 1
    return { url: remoteUrl, source: 'remote' }
  }

  cacheStats.networkFetches += 1

  if (cache) {
    try {
      await cache.put(remoteUrl, fetched.clone())
    } catch {
      // QuotaExceededError. Seguimos igual con el blob en memoria: antes esta
      // excepción se propagaba y mataba la resolución del resto de la playlist,
      // dejando esos ítems streameando la URL remota en cada vuelta.
      cacheStats.quotaExceeded = true
    }
  }

  const blob = await fetched.blob()
  cacheStats.bytesDownloaded += blob.size

  const url = URL.createObjectURL(blob)
  blobUrls.set(remoteUrl, url)
  return { url, source: 'network' }
}

// Libera los blob URLs de archivos que ya no están en la playlist vigente. Sin esto la
// memoria crece sin techo con cada cambio o republicación de playlist.
export function pruneBlobUrls(keepRemoteUrls) {
  const keep = new Set(keepRemoteUrls)

  for (const [remoteUrl, blobUrl] of blobUrls) {
    if (keep.has(remoteUrl)) continue
    URL.revokeObjectURL(blobUrl)
    blobUrls.delete(remoteUrl)
  }
}

export function releaseAllBlobUrls() {
  pruneBlobUrls([])
}

export async function listCachedUrls() {
  const cache = await openCache()
  if (!cache) return null

  const requests = await cache.keys()
  return requests.map((request) => request.url)
}

export async function clearMediaCache() {
  if (cacheApiAvailable) {
    await caches.delete(MEDIA_CACHE_NAME).catch(() => {})
  }
  releaseAllBlobUrls()
}
