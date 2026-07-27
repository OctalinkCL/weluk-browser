const CACHE_NAME = 'weluk-media-v1'

// Descarga el archivo una sola vez y lo deja en el Cache Storage del navegador
// (persiste en disco entre recargas). Si el navegador no soporta Cache API
// (TVs muy viejas), degrada a servir la URL remota directo, sin romper nada.
export async function getCachedBlobUrl(remoteUrl) {
  if (typeof caches === 'undefined') return remoteUrl

  const cache = await caches.open(CACHE_NAME)
  let response = await cache.match(remoteUrl)

  if (!response) {
    const fetched = await fetch(remoteUrl)
    if (!fetched.ok) return remoteUrl
    await cache.put(remoteUrl, fetched.clone())
    response = fetched
  }

  return URL.createObjectURL(await response.blob())
}
