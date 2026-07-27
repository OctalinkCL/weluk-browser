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

onMounted(() => {
  // Suscribirse antes de mostrar el código: si alguien lo reclama muy rápido, no se
  // pierde el evento esperando a que termine de insertarse el código.
  subscribeToClaim()

  const stored = getStoredPendingCode()
  if (stored) {
    code.value = stored.code
    scheduleExpiryRefresh(stored.expiresAt)
  } else {
    insertPairingCode()
  }
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
