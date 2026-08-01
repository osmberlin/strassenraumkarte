import { createReadStream, existsSync, readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

const bunCacheLinks = path.join(homedir(), '.bun', 'install', 'cache', 'links')
const rootDir = path.dirname(fileURLToPath(import.meta.url))
const styleRoot = path.resolve(rootDir, '../style')
const rasterTilesRoot = path.resolve(rootDir, '../render/tiles')
const tileRegressionRuns = path.resolve(rootDir, '../audit/tile-regression/runs')

const RASTER_TILE_RE = /^\/raster\/(\d+)\/(\d+)\/(\d+)\.(jpg|jpeg|png)$/i
const RUST_TILE_RE = /^\/raster-rust\/(\d+)\/(\d+)\/(\d+)\.(png|jpg|jpeg)$/i

// Prefer RUST_TILES_ROOT env, else newest full-approx-*/rust or bench-*/rust
// by mtime, else runs/latest-rust symlink from render-suite-full.sh.
function resolveRustTilesRoot(): string {
  const fromEnv = process.env.RUST_TILES_ROOT?.trim()
  if (fromEnv) return path.resolve(fromEnv)
  if (!existsSync(tileRegressionRuns)) {
    return path.resolve(tileRegressionRuns, 'bench-missing/rust')
  }
  const candidates = readdirSync(tileRegressionRuns)
    .filter(
      (name) =>
        name.startsWith('bench-large-fullapprox-') ||
        name.startsWith('full-approx-') ||
        name.startsWith('bench-'),
    )
    .map((name) => {
      const rustDir = path.join(tileRegressionRuns, name, 'rust')
      try {
        const st = statSync(rustDir)
        return st.isDirectory() ? { rustDir, mtime: st.mtimeMs } : null
      } catch {
        return null
      }
    })
    .filter((x): x is { rustDir: string; mtime: number } => x != null)
    .sort((a, b) => b.mtime - a.mtime)
  if (candidates[0]?.rustDir) return candidates[0].rustDir

  const latestLink = path.join(tileRegressionRuns, 'latest-rust')
  if (existsSync(latestLink)) {
    try {
      const st = statSync(latestLink)
      if (st.isDirectory()) return latestLink
    } catch {
      /* fall through */
    }
  }
  return path.resolve(tileRegressionRuns, 'bench-missing/rust')
}

const rustTilesRoot = resolveRustTilesRoot()

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

/**
 * Serve QGIS XYZ tiles from `render/tiles` at `/raster/{z}/{x}/{y}.{jpg|png}`.
 * Falls back across jpg/png like `render/preview_server.py` so compare works
 * without a second process on :8000.
 */
function rasterTilesPlugin(): Plugin {
  return {
    name: 'strassenraumkarte-raster-tiles',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const url = (req.url ?? '').split('?')[0] ?? ''
        const m = RASTER_TILE_RE.exec(url)
        if (!m) {
          next()
          return
        }
        const z = m[1]!
        const x = m[2]!
        const y = m[3]!
        const extRaw = m[4]!
        const ext = extRaw.toLowerCase() === 'jpeg' ? 'jpg' : extRaw.toLowerCase()
        const alt = ext === 'jpg' ? 'png' : 'jpg'
        for (const suffix of [ext, alt]) {
          const file = path.resolve(rasterTilesRoot, z, x, `${y}.${suffix}`)
          if (!file.startsWith(rasterTilesRoot) || !existsSync(file)) continue
          res.setHeader('Content-Type', suffix === 'png' ? 'image/png' : 'image/jpeg')
          res.setHeader('Cache-Control', 'no-store')
          createReadStream(file).pipe(res)
          return
        }
        res.statusCode = 404
        res.setHeader('Content-Type', 'text/plain')
        res.end(`tile not found: ${z}/${x}/${y}`)
      })
    },
  }
}

/**
 * Serve Rust XYZ tiles from a full-approx/bench run (or `RUST_TILES_ROOT`) at
 * `/raster-rust/{z}/{x}/{y}.png`. PNG-first with jpg fallback.
 */
function rustRasterTilesPlugin(): Plugin {
  return {
    name: 'strassenraumkarte-rust-raster-tiles',
    configureServer(server) {
      // eslint-disable-next-line no-console
      console.info(`[rust-tiles] serving ${rustTilesRoot} at /raster-rust/`)
      server.middlewares.use((req, res, next) => {
        const url = (req.url ?? '').split('?')[0] ?? ''
        const m = RUST_TILE_RE.exec(url)
        if (!m) {
          next()
          return
        }
        const z = m[1]!
        const x = m[2]!
        const y = m[3]!
        const extRaw = m[4]!
        const ext = extRaw.toLowerCase() === 'jpeg' ? 'jpg' : extRaw.toLowerCase()
        const alt = ext === 'png' ? 'jpg' : 'png'
        for (const suffix of [ext, alt]) {
          const file = path.resolve(rustTilesRoot, z, x, `${y}.${suffix}`)
          if (!file.startsWith(rustTilesRoot) || !existsSync(file)) continue
          res.setHeader('Content-Type', suffix === 'png' ? 'image/png' : 'image/jpeg')
          res.setHeader('Cache-Control', 'no-store')
          createReadStream(file).pipe(res)
          return
        }
        res.statusCode = 404
        res.setHeader('Content-Type', 'text/plain')
        res.end(`rust tile not found: ${z}/${x}/${y}`)
      })
    },
  }
}

export default defineConfig({
  build: {
    target: 'es2022',
  },
  plugins: [styleAssetsPlugin(), rasterTilesPlugin(), rustRasterTilesPlugin()],
  server: {
    port: 5177,
    host: '127.0.0.1',
    fs: {
      allow: ['.', bunCacheLinks, styleRoot, rasterTilesRoot, rustTilesRoot, tileRegressionRuns],
    },
  },
})
