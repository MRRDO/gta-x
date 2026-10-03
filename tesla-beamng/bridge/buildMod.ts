// Zips beamng/mod/ into beamng/dist/tesla_bridge.zip (no external zip tool,
// so it works on Windows). Copy the zip into BeamNG's user folder `mods/`.

import { readdirSync, readFileSync, statSync, mkdirSync, writeFileSync } from 'node:fs'
import { join, relative, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { deflateRawSync } from 'node:zlib'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const src = join(root, 'beamng', 'mod')
const out = join(root, 'beamng', 'dist', 'tesla_bridge.zip')

const CRC_TABLE = (() => {
  const t = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c >>> 0
  }
  return t
})()

function crc32(buf: Buffer) {
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name)
    return statSync(p).isDirectory() ? walk(p) : [p]
  })
}

const files = walk(src).sort()
const locals: Buffer[] = []
const centrals: Buffer[] = []
let offset = 0
// DOS date/time: 2026-01-01 00:00 (fixed, so builds are reproducible)
const dosTime = 0
const dosDate = ((2026 - 1980) << 9) | (1 << 5) | 1

for (const file of files) {
  const name = Buffer.from(relative(src, file).split('\\').join('/'))
  const data = readFileSync(file)
  const comp = deflateRawSync(data, { level: 9 })
  const crc = crc32(data)
  const local = Buffer.alloc(30)
  local.writeUInt32LE(0x04034b50, 0)
  local.writeUInt16LE(20, 4)
  local.writeUInt16LE(0, 6)
  local.writeUInt16LE(8, 8)
  local.writeUInt16LE(dosTime, 10)
  local.writeUInt16LE(dosDate, 12)
  local.writeUInt32LE(crc, 14)
  local.writeUInt32LE(comp.length, 18)
  local.writeUInt32LE(data.length, 22)
  local.writeUInt16LE(name.length, 26)
  local.writeUInt16LE(0, 28)
  locals.push(local, name, comp)
  const central = Buffer.alloc(46)
  central.writeUInt32LE(0x02014b50, 0)
  central.writeUInt16LE(20, 4)
  central.writeUInt16LE(20, 6)
  central.writeUInt16LE(0, 8)
  central.writeUInt16LE(8, 10)
  central.writeUInt16LE(dosTime, 12)
  central.writeUInt16LE(dosDate, 14)
  central.writeUInt32LE(crc, 16)
  central.writeUInt32LE(comp.length, 20)
  central.writeUInt32LE(data.length, 24)
  central.writeUInt16LE(name.length, 28)
  central.writeUInt32LE(offset, 42)
  centrals.push(central, name)
  offset += local.length + name.length + comp.length
}

const cdSize = centrals.reduce((n, b) => n + b.length, 0)
const end = Buffer.alloc(22)
end.writeUInt32LE(0x06054b50, 0)
end.writeUInt16LE(files.length, 8)
end.writeUInt16LE(files.length, 10)
end.writeUInt32LE(cdSize, 12)
end.writeUInt32LE(offset, 16)

mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, Buffer.concat([...locals, ...centrals, end]))
console.log(`wrote ${relative(root, out)} (${files.length} files)`)
for (const f of files) console.log('  ' + relative(src, f).split('\\').join('/'))
