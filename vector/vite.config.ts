import { createReadStream, existsSync, readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Connect, type Plugin } from 'vite'

const bunCacheLinks = path.join(homedir(), '.bun', 'install', 'cache', 'links')
const rootDir = path.dirname(fileURLToPath(import.meta.url))
const styleRoot = path.resolve(rootDir, '../style')
// QGIS_TILES_ROOT points the compare at another QGIS tile folder (e.g. a one-off render).
const rasterTilesRoot = process.env.QGIS_TILES_ROOT?.trim()
  ? path.resolve(process.env.QGIS_TILES_ROOT.trim())
  : path.resolve(rootDir, '../render/tiles')
const tileRegressionRuns = path.resolve(rootDir, '../audit/tile-regression/runs')

const RASTER_TILE_RE = /^\/raster\/(\d+)\/(\d+)\/(\d+)\.(webp|jpg|jpeg|png)$/i
const RUST_TILE_RE = /^\/raster-rust\/(\d+)\/(\d+)\/(\d+)\.(webp|png|jpg|jpeg)$/i

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

/**
 * Serve `/symbols/*` and `/textures/*` from the QGIS `style/` folder — the runtime icon
 * resolver fetches traffic sign SVGs from there. Registered for `vite dev` and
 * `vite preview`; a static deployment has to copy `style/symbols/traffic_signs` itself.
 */
function styleAssetsPlugin(): Plugin {
  const middleware: Connect.NextHandleFunction = (req, res, next) => {
    const url = (req.url ?? '').split('?')[0] ?? ''
    if (!url.startsWith('/symbols/') && !url.startsWith('/textures/')) {
      next()
      return
    }
    let rel: string
    try {
      rel = decodeURIComponent(url.slice(1))
    } catch {
      next()
      return
    }
    const file = path.resolve(styleRoot, rel)
    if (!file.startsWith(styleRoot + path.sep) || !existsSync(file) || !statSync(file).isFile()) {
      next()
      return
    }
    if (file.endsWith('.svg')) res.setHeader('Content-Type', 'image/svg+xml')
    else if (file.endsWith('.png')) res.setHeader('Content-Type', 'image/png')
    createReadStream(file).pipe(res)
  }
  return {
    name: 'strassenraumkarte-style-assets',
    configureServer(server) {
      server.middlewares.use(middleware)
    },
    configurePreviewServer(server) {
      server.middlewares.use(middleware)
    },
  }
}

/**
 * Serve QGIS XYZ tiles from `render/tiles` (or `QGIS_TILES_ROOT`) at
 * `/raster/{z}/{x}/{y}.{jpg|png|webp}`. Falls back across jpg/png/webp
 * (render_tiles.sh writes webp by default) so compare works without a second
 * process on :8000.
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
        const suffixes = [ext, ...['jpg', 'png', 'webp'].filter((s) => s !== ext)]
        for (const suffix of suffixes) {
          const file = path.resolve(rasterTilesRoot, z, x, `${y}.${suffix}`)
          if (!file.startsWith(rasterTilesRoot) || !existsSync(file)) continue
          res.setHeader('Content-Type', rustTileContentType(suffix))
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

function rustTileContentType(suffix: string): string {
  if (suffix === 'webp') return 'image/webp'
  if (suffix === 'png') return 'image/png'
  return 'image/jpeg'
}

/**
 * Serve Rust XYZ tiles from a full-approx/bench run (or `RUST_TILES_ROOT`) at
 * `/raster-rust/{z}/{x}/{y}.webp` (default). Falls back across webp/png/jpg.
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
        const fallbacks =
          ext === 'webp'
            ? ['webp', 'png', 'jpg']
            : ext === 'png'
              ? ['png', 'webp', 'jpg']
              : ['jpg', 'webp', 'png']
        for (const suffix of fallbacks) {
          const file = path.resolve(rustTilesRoot, z, x, `${y}.${suffix}`)
          if (!file.startsWith(rustTilesRoot) || !existsSync(file)) continue
          res.setHeader('Content-Type', rustTileContentType(suffix))
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
