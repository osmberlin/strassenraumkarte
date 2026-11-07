/**
 * Print per-group / final PMTiles sizes (prep helper; deeper per-zoom later).
 */

import { readdir, stat } from 'node:fs/promises'
import path from 'node:path'

const ROOT = path.resolve(import.meta.dir, '..')

async function report(file: string): Promise<void> {
  try {
    const info = await stat(file)
    console.log(`${(info.size / 1024 / 1024).toFixed(2).padStart(8)} MiB  ${file}`)
  } catch {
    console.log(`   (missing)  ${file}`)
  }
}

async function main() {
  const tmp = path.join(ROOT, 'out', '_tiles')
  try {
    const files = (await readdir(tmp)).filter((f) => f.endsWith('.pmtiles')).sort()
    for (const f of files) await report(path.join(tmp, f))
  } catch {
    console.log('(no out/_tiles yet)')
  }
  await report(path.join(ROOT, 'public', 'tiles', 'strassenraumkarte.pmtiles'))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
