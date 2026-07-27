<script setup>
import { onMounted, onUnmounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import {
  clearStoredPendingCode,
  generatePairingCode,
  getStoredPendingCode,
  storePendingCode,
} from '../lib/pairingCode'

const props = defineProps({
  deviceUuid: { type: String, required: true },
})

const emit = defineEmits(['paired'])

const code = ref(null)
const error = ref(null)

let screenChannel = null
let expiryTimer = null

function scheduleExpiryRefresh(expiresAt) {
  clearTimeout(expiryTimer)
  const msUntilExpiry = new Date(expiresAt).getTime() - Date.now()
  // Cuando el código actual expira, se genera uno nuevo solo — nunca queda un
  // código muerto esperando a que alguien lo reclame sin saber que ya venció.
  expiryTimer = setTimeout(insertPairingCode, Math.max(msUntilExpiry, 0))
}

async function insertPairingCode() {
  const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString()

  for (let attempt = 0; attempt < 5; attempt++) {
    const candidate = generatePairingCode()

    const { error: insertError } = await supabase.from('pairing_codes').insert({
      code: candidate,
      device_uuid: props.deviceUuid,
      status: 'pending',
      expires_at: expiresAt,
    })

    if (!insertError) {
      code.value = candidate
      storePendingCode(candidate, expiresAt)
      scheduleExpiryRefresh(expiresAt)
      return
    }

    if (insertError.code !== '23505') {
      error.value = `No se pudo generar el código: ${insertError.message}`
      return
    }
    // Código ya en uso por otra pantalla pendiente — reintentar con uno nuevo.
  }

  error.value = 'No se pudo generar un código único. Recargá la página para reintentar.'
}

// El localStorage se desincroniza de la base con facilidad: limpieza manual de códigos
// vencidos, un futuro job de expiración, o un reset del proyecto. Mostrar un código que
// ya no existe deja la pantalla esperando un claim imposible — el SQL de reclamo afecta
// 0 filas y no falla, así que nadie se entera (mismo patrón que el gotcha de RLS).
async function pendingCodeExists(candidate) {
  const { data, error: selectError } = await supabase
    .from('pairing_codes')
    .select('code')
    .eq('code', candidate)
    .eq('device_uuid', props.deviceUuid)
    .eq('status', 'pending')
    .gt('expires_at', new Date().toISOString())
    .maybeSingle()

  if (selectError) return false
  return Boolean(data)
}

function subscribeToClaim() {
  screenChannel = supabase
    .channel(`pairing-${props.deviceUuid}`)
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'screens', filter: `device_uuid=eq.${props.deviceUuid}` },
      (payload) => {
        if (payload.new?.status === 'paired') {
          clearTimeout(expiryTimer)
          clearStoredPendingCode()
          emit('paired')
        }
      },
    )
    .subscribe()
}

onMounted(async () => {
  // Suscribirse antes de mostrar el código: si alguien lo reclama muy rápido, no se
  // pierde el evento esperando a que termine de insertarse el código.
  subscribeToClaim()

  const stored = getStoredPendingCode()
  if (stored && (await pendingCodeExists(stored.code))) {
    code.value = stored.code
    scheduleExpiryRefresh(stored.expiresAt)
    return
  }

  clearStoredPendingCode()
  insertPairingCode()
})

onUnmounted(() => {
  if (screenChannel) supabase.removeChannel(screenChannel)
  clearTimeout(expiryTimer)
})
</script>

<template>
  <div class="pairing">
    <p v-if="code" class="code">{{ code }}</p>
    <p v-if="code" class="instruction">Desde un navegador, ingresá este código para activar esta pantalla.</p>
    <p v-else-if="error" class="error">{{ error }}</p>
  </div>
</template>

<style scoped>
.pairing {
  height: 100vh;
  width: 100vw;
  background: #000;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 1.5rem;
}

.code {
  color: #fff;
  font-family: monospace;
  font-size: 6rem;
  font-weight: bold;
  letter-spacing: 0.5rem;
}

.instruction {
  color: #aaa;
  font-family: sans-serif;
  font-size: 1.25rem;
}

.error {
  color: #f66;
  font-family: sans-serif;
  font-size: 1.25rem;
  text-align: center;
  padding: 2rem;
}
</style>
