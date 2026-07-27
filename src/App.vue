<script setup>
import { onMounted, ref } from 'vue'
import { supabase } from './lib/supabase'
import { getDeviceUuid } from './lib/device'
import Player from './components/Player.vue'
import Pairing from './components/Pairing.vue'

const deviceUuid = getDeviceUuid()
const screenState = ref('checking') // 'checking' | 'paired' | 'pairing'

onMounted(async () => {
  const { data: screen } = await supabase
    .from('screens')
    .select('status')
    .eq('device_uuid', deviceUuid)
    .maybeSingle()

  screenState.value = screen?.status === 'paired' ? 'paired' : 'pairing'
})
</script>

<template>
  <Player
    v-if="screenState === 'paired'"
    :device-uuid="deviceUuid"
    @disconnected="screenState = 'pairing'"
  />
  <Pairing v-else-if="screenState === 'pairing'" :device-uuid="deviceUuid" @paired="screenState = 'paired'" />
</template>
