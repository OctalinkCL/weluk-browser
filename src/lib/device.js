const STORAGE_KEY = 'weluk_device_uuid'

// crypto.randomUUID() solo existe en contextos seguros (HTTPS, o localhost). Probando
// por IP de LAN en HTTP plano (como accede un TV en la red local) no está disponible.
function generateUuid() {
  if (crypto.randomUUID) return crypto.randomUUID()

  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0
    const v = c === 'x' ? r : (r & 0x3) | 0x8
    return v.toString(16)
  })
}

export function getDeviceUuid() {
  let id = localStorage.getItem(STORAGE_KEY)
  if (!id) {
    id = generateUuid()
    localStorage.setItem(STORAGE_KEY, id)
  }
  return id
}
