import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import legacy from '@vitejs/plugin-legacy'

export default defineConfig({
  plugins: [
    vue(),
    // Necesario para Smart TVs viejas sin soporte de ES modules nativo (ver CLAUDE.md
    // sección 3). @vitejs/plugin-legacy debe fijarse a la misma serie mayor que Vite
    // (5.x aquí) — la última versión del plugin pide Vite 8 como peer.
    legacy({
      targets: ['chrome >= 38', 'safari >= 9'],
    }),
  ],
})
