import { open } from 'node:fs/promises'
import { homedir } from 'node:os'
import path from 'node:path'
import { PMTiles } from 'pmtiles'
import type { Connect, Plugin } from 'vite'
import { defineConfig } from 'vite'

const bunCacheLinks = path.join(homedir(), '.bun', 'install', 'cache', 'links')
const PMTILES_PATH = path.resolve(import.meta.dirname, 'public/tiles/strassenraumkarte.pmtiles')

class FileSource {
  constructor(private readonly filePath: string) {}

  async getBytes(offset: number, length: number) {
    const f = await open(this.filePath, 'r')
    try {
      const buf = Buffer.alloc(length)
      await f.read(buf, 0, length, offset)
      return {
        data: buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength),
      }
    } finally {
      await f.close()
    }
  }

  getKey() {
    return this.filePath
  }
}

/**
 * Serve Z/X/Y MVT from the local PMTiles archive.
 * MapLibre 6 fetches tiles in workers where `addProtocol('pmtiles')` does not run,
 * so HTTP tiles are the reliable Vite-dev path.
 */
function pmtilesXyzPlugin(): Plugin {
  let tiles: PMTiles | null = null

  const ensure = () => {
    tiles ??= new PMTiles(new FileSource(PMTILES_PATH))
    return tiles
  }

  const handler: Connect.NextHandleFunction = async (req, res, next) => {
    const url = req.url ?? ''
    const match = url.match(/^\/mvt\/(\d+)\/(\d+)\/(\d+)\.mvt(?:\?.*)?$/)
    if (!match) {
      next()
      return
    }

    const z = Number(match[1])
    const x = Number(match[2])
    const y = Number(match[3])

    try {
      const tile = await ensure().getZxy(z, x, y)
      if (!tile) {
        res.statusCode = 204
        res.end()
        return
      }
      res.setHeader('Content-Type', 'application/vnd.mapbox-vector-tile')
      res.setHeader('Cache-Control', 'no-cache')
      res.end(Buffer.from(tile.data))
    } catch (err) {
      console.error('[mvt]', z, x, y, err)
      res.statusCode = 500
      res.end(String(err))
    }
  }

  return {
    name: 'pmtiles-xyz',
    configureServer(server) {
      server.middlewares.use(handler)
    },
    configurePreviewServer(server) {
      server.middlewares.use(handler)
    },
  }
}

export default defineConfig({
  plugins: [pmtilesXyzPlugin()],
  build: {
    target: 'es2022',
  },
  optimizeDeps: {
    // Keep maplibre out of the dep optimizer so the packaged worker URL stays valid.
    exclude: ['maplibre-gl'],
    include: ['pmtiles'],
    esbuildOptions: {
      target: 'es2022',
    },
  },
  server: {
    port: 5177,
    host: '127.0.0.1',
    fs: {
      allow: ['.', bunCacheLinks],
    },
  },
})
