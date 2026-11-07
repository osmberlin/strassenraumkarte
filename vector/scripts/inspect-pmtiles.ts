import { open } from 'node:fs/promises'

import { PMTiles } from 'pmtiles'

class FileSource {
  constructor(private readonly path: string) {}

  async getBytes(offset: number, length: number) {
    const f = await open(this.path, 'r')
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
    return this.path
  }
}

const path = process.argv[2] ?? 'public/tiles/strassenraumkarte.pmtiles'
const p = new PMTiles(new FileSource(path))
const h = await p.getHeader()
const m = await p.getMetadata()
console.log(
  JSON.stringify(
    {
      minZoom: h.minZoom,
      maxZoom: h.maxZoom,
      tileType: h.tileType,
      bounds: [h.minLon, h.minLat, h.maxLon, h.maxLat],
      metadata: m,
    },
    null,
    2,
  ),
)
