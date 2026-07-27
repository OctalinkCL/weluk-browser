// Sin 0/O ni 1/I/L — se prestan a confusión leyendo un código desde una TV a distancia.
const ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'
const CODE_LENGTH = 5

const STORAGE_KEY = 'weluk_pending_code'

export function generatePairingCode() {
  let code = ''
  for (let i = 0; i < CODE_LENGTH; i++) {
    code += ALPHABET[Math.floor(Math.random() * ALPHABET.length)]
  }
  return code
}

// Persistencia del código pendiente actual, para no generar uno nuevo (y una fila
// nueva en pairing_codes) en cada refresh mientras el actual siga vigente.
export function getStoredPendingCode() {
  const raw = localStorage.getItem(STORAGE_KEY)
  if (!raw) return null

  const stored = JSON.parse(raw)
  if (new Date(stored.expiresAt) <= new Date()) {
    localStorage.removeItem(STORAGE_KEY)
    return null
  }

  return stored
}

export function storePendingCode(code, expiresAt) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify({ code, expiresAt }))
}

export function clearStoredPendingCode() {
  localStorage.removeItem(STORAGE_KEY)
}
