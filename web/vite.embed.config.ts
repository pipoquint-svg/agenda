import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { resolve } from 'node:path'

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist/embed',
    emptyOutDir: true,
    cssCodeSplit: false,
    lib: {
      entry: resolve(__dirname, 'src/embed.tsx'),
      name: 'BlackSheepAgendaEmbed',
      formats: ['iife'],
      fileName: () => 'agenda-embed.js',
    },
    rollupOptions: {
      output: {
        inlineDynamicImports: true,
        assetFileNames: (assetInfo) => assetInfo.name?.endsWith('.css') ? 'agenda-embed.css' : '[name][extname]',
      },
    },
  },
})
