import { homedir } from 'node:os'
import path from 'node:path'
import { defineConfig } from 'vite'

const bunCacheLinks = path.join(homedir(), '.bun', 'install', 'cache', 'links')

export default defineConfig({
  build: {
    target: 'es2022',
  },
  server: {
    port: 5177,
    host: '127.0.0.1',
    fs: {
      allow: ['.', bunCacheLinks],
    },
  },
})
