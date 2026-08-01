import { createReadStream, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

const bunCacheLinks = path.join(homedir(), '.bun', 'install', 'cache', 'links')
const rootDir = path.dirname(fileURLToPath(import.meta.url))
const styleRoot = path.resolve(rootDir, '../style')

/** Serve `/symbols/*` and `/textures/*` from the QGIS `style/` folder (dev + preview). */
function styleAssetsPlugin(): Plugin {
  return {
    name: 'strassenraumkarte-style-assets',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const url = (req.url ?? '').split('?')[0] ?? ''
        if (!url.startsWith('/symbols/') && !url.startsWith('/textures/')) {
          next()
          return
        }
        const rel = decodeURIComponent(url.slice(1))
        const file = path.resolve(styleRoot, rel)
        if (!file.startsWith(styleRoot) || !existsSync(file)) {
          next()
          return
        }
        if (file.endsWith('.svg')) res.setHeader('Content-Type', 'image/svg+xml')
        else if (file.endsWith('.png')) res.setHeader('Content-Type', 'image/png')
        createReadStream(file).pipe(res)
      })
    },
  }
}

export default defineConfig({
  build: {
    target: 'es2022',
  },
  plugins: [styleAssetsPlugin()],
  server: {
    port: 5177,
    host: '127.0.0.1',
    fs: {
      allow: ['.', bunCacheLinks, styleRoot],
    },
  },
})
