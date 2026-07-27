import { createApp } from 'vue'
import App from './App.vue'
import { requestPersistentStorage } from './lib/mediaCache'
import './styles/reset.css'

// Se pide antes de montar para que el caché de medios no sea desalojable en una TV con
// poca RAM corriendo 24/7. Si el navegador la deniega o no la soporta, no pasa nada.
requestPersistentStorage()

createApp(App).mount('#app')
