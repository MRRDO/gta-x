// BeamNG <-> iPad relay.
//   game:  TCP client to the mod on 127.0.0.1:8766 (newline-delimited JSON), reconnects every 2 s
//   app:   WebSocket + HTTP on 0.0.0.0:8765 (test page at /, minimap at /minimap.png)
//
//   npm run bridge [-- --port 8765 --game-port 8766 --app ../dist --no-auth --feedback-dir ./notes]

import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { connect, type Socket } from 'node:net'
import { networkInterfaces } from 'node:os'
import { readFileSync, existsSync, writeFileSync, statSync, mkdirSync, readdirSync } from 'node:fs'
import { join, dirname, extname, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomBytes, createHash } from 'node:crypto'
import { WebSocketServer, WebSocket } from 'ws'
import qrcode from 'qrcode-terminal'
import { COMMAND_TYPES, type MapInfo, type Minimap } from './protocol.ts'

const here = dirname(fileURLToPath(import.meta.url))

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`)
  if (i < 0) return fallback
  const v = process.argv[i + 1]
  return v && !v.startsWith('--') ? v : 'true'
}

const PORT = Number(arg('port', process.env.BRIDGE_PORT ?? '8765'))
const GAME_HOST = arg('game-host', '127.0.0.1')!
const GAME_PORT = Number(arg('game-port', '8766'))
const APP_DIR = arg('app')
const NO_AUTH = arg('no-auth') === 'true'
const QUIET = arg('quiet') === 'true'

// A pairing token so nobody else on the Wi-Fi can drive the car. Kept across restarts.
const tokenFile = join(here, '.token')
let TOKEN = existsSync(tokenFile) ? readFileSync(tokenFile, 'utf8').trim() : ''
if (!TOKEN) {
  TOKEN = randomBytes(4).toString('hex')
  writeFileSync(tokenFile, TOKEN + '\n')
}

// ---------------------------------------------------------------------------
// game connection
// ---------------------------------------------------------------------------

let game: Socket | null = null
let gameConnected = false
let gameVersion: string | undefined
let lineBuf = ''
let lastMap: MapInfo | null = null
let lastMapKey = ''
let lastMinimap: { key: string; mime: string; data: Buffer; msg: Minimap } | null = null
let minimapRequestedFor = ''
let lastRoute: unknown = null
let lastState: unknown = null
const stats = { state: 0, traffic: 0, fromApp: 0, since: Date.now() }
const recentEvents: unknown[] = []
const feedbackDir = resolve(arg('feedback-dir') ?? join(here, 'feedback')) // voice notes land here

// A voice note from the wheel button / app: save the audio plus what the car was doing.
function saveVoiceNote(msg: any): string {
  mkdirSync(feedbackDir, { recursive: true })
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)
  const ext = /webm/.test(msg.mime) ? 'webm' : /mp4|m4a|aac/.test(msg.mime) ? 'm4a' : /wav/.test(msg.mime) ? 'wav' : /ogg/.test(msg.mime) ? 'ogg' : 'bin'
  const base = `note-${stamp}`
  writeFileSync(join(feedbackDir, `${base}.${ext}`), Buffer.from(String(msg.audio ?? ''), 'base64'))
  const s = lastState as any
  const context = {
    savedAt: new Date().toISOString(), durationSec: msg.durationSec ?? null, text: msg.text ?? null, audio: `${base}.${ext}`,
    level: lastMap?.level ?? null,
    car: s ? { vehicle: s.vehicle, pos: s.pos, speed: s.speed, gear: s.gear, autopilot: s.autopilot, safety: s.safety } : null,
    recentEvents: recentEvents.slice(-30),
  }
  writeFileSync(join(feedbackDir, `${base}.json`), JSON.stringify(context, null, 2))
  return base
}

function log(...a: unknown[]) {
  if (!QUIET) console.log(new Date().toISOString().slice(11, 19), ...a)
}

function connectGame() {
  const sock = connect({ host: GAME_HOST, port: GAME_PORT })
  sock.setNoDelay(true)
  sock.setEncoding('utf8')
  sock.on('connect', () => {
    game = sock
    gameConnected = true
    lineBuf = ''
    log(`game connected (${GAME_HOST}:${GAME_PORT})`)
    broadcast({ t: 'bridge', game: 'connected' })
    sendGame({ t: 'requestMap' })
  })
  sock.on('data', (chunk: string) => {
    lineBuf += chunk
    let nl: number
    while ((nl = lineBuf.indexOf('\n')) >= 0) {
      const line = lineBuf.slice(0, nl)
      lineBuf = lineBuf.slice(nl + 1)
      if (line.trim()) onGameLine(line)
    }
  })
  const retry = () => {
    if (game === sock) {
      game = null
      if (gameConnected) {
        gameConnected = false
        log('game disconnected')
        broadcast({ t: 'bridge', game: 'disconnected' })
      }
    }
    setTimeout(connectGame, 2000)
  }
  sock.on('error', () => {}) // "close" follows
  sock.on('close', retry)
}

function sendGame(msg: unknown): boolean {
  if (!game || !gameConnected) return false
  game.write(JSON.stringify(msg) + '\n')
  return true
}

// Lua can't tell an empty array from an empty object, and uses false where we want null.
function asArray<T>(v: unknown): T[] {
  if (Array.isArray(v)) return v as T[]
  if (v && typeof v === 'object') return Object.values(v as Record<string, T>)
  return []
}
const nullable = (v: unknown) => (v === false || v === undefined ? null : v)

function normalize_(msg: any): any {
  switch (msg.t) {
    case 'state': {
      msg.signal = nullable(msg.signal)
      msg.battery = nullable(msg.battery)
      msg.fuel = nullable(msg.fuel)
      if (!msg.doors || Array.isArray(msg.doors)) msg.doors = {}
      const a = msg.autopilot ?? {}
      for (const k of ['speedLimit', 'leadGap', 'control', 'nextTurn', 'remaining', 'lastDisengage']) a[k] = nullable(a[k])
      msg.autopilot = a
      return msg
    }
    case 'traffic':
      msg.cars = asArray(msg.cars)
      return msg
    case 'map':
      msg.nodes = asArray(msg.nodes)
      msg.links = asArray(msg.links).map((l: any) => ({ ...l, speedLimit: l.speedLimit ?? null }))
      msg.signals = asArray(msg.signals)
      msg.parking = asArray(msg.parking)
      return msg
    case 'route':
      msg.points = asArray(msg.points)
      return msg
    default:
      return msg
  }
}

function onGameLine(line: string) {
  let msg: any
  try {
    msg = JSON.parse(line)
  } catch {
    log('bad line from game:', line.slice(0, 120))
    return
  }
  msg = normalize_(msg)
  switch (msg.t) {
    case 'hello':
      gameVersion = msg.version
      log(`BeamNG ${msg.version}, protocol ${msg.protocol}`)
      broadcast({ t: 'bridge', game: 'connected', version: gameVersion })
      return
    case 'state':
      stats.state++
      lastState = msg
      broadcast(msg, true)
      return
    case 'traffic':
      stats.traffic++
      broadcast(msg, true)
      return
    case 'map': {
      const key = createHash('sha1').update(line).digest('hex')
      if (lastMinimap && lastMinimap.key === msg.level) msg.minimap = lastMinimap.msg.url
      const changed = key !== lastMapKey
      lastMap = msg
      lastMapKey = key
      if (changed) {
        log(`map ${msg.level}: ${msg.nodes.length} nodes, ${msg.links.length} links, ${msg.signals.length} signals, ${msg.parking.length} parking`)
        broadcast(msg)
      }
      if (msg.minimapInfo && minimapRequestedFor !== msg.level && lastMinimap?.key !== msg.level) {
        minimapRequestedFor = msg.level
        sendGame({ t: 'requestMinimap' })
      }
      return
    }
    case 'minimap': {
      const data = Buffer.from(msg.data ?? '', 'base64')
      const url = `/minimap.png?level=${encodeURIComponent(msg.level)}`
      const out: Minimap = { t: 'minimap', url, offset: msg.offset, size: msg.size }
      lastMinimap = { key: msg.level, mime: msg.mime ?? 'image/png', data, msg: out }
      if (lastMap && lastMap.level === msg.level) lastMap.minimap = url
      log(`minimap ${msg.level}: ${(data.length / 1024).toFixed(0)} KB`)
      broadcast(out)
      return
    }
    case 'route':
      lastRoute = msg
      broadcast(msg)
      return
    case 'event':
      log('event', msg.kind, msg.detail ?? '')
      recentEvents.push({ ...msg, at: new Date().toISOString() })
      if (recentEvents.length > 100) recentEvents.shift()
      broadcast(msg)
      return
    default:
      broadcast(msg)
  }
}

// ---------------------------------------------------------------------------
// app side
// ---------------------------------------------------------------------------

const clients = new Set<WebSocket>()

function broadcast(msg: unknown, droppable = false) {
  const s = JSON.stringify(msg)
  for (const ws of clients) {
    if (ws.readyState !== WebSocket.OPEN) continue
    if (droppable && ws.bufferedAmount > 1_000_000) continue // slow client: skip a frame
    ws.send(s)
  }
}

function isLoopback(req: IncomingMessage) {
  const a = req.socket.remoteAddress ?? ''
  return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1'
}

function authorized(req: IncomingMessage) {
  if (NO_AUTH || isLoopback(req)) return true
  const url = new URL(req.url ?? '/', 'http://x')
  return url.searchParams.get('token') === TOKEN
}

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml',
  '.webmanifest': 'application/manifest+json', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.wasm': 'application/wasm',
  '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.glb': 'model/gltf-binary',
}

function serveFile(res: ServerResponse, file: string) {
  res.writeHead(200, { 'content-type': MIME[extname(file).toLowerCase()] ?? 'application/octet-stream', 'cache-control': 'no-cache' })
  res.end(readFileSync(file))
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://x')
  const path = url.pathname
  if (path === '/' || path === '/test' || path === '/test.html') return serveFile(res, join(here, 'test.html'))
  if (path === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' })
    return res.end(JSON.stringify({ game: gameConnected, version: gameVersion, clients: clients.size, level: lastMap?.level ?? null }))
  }
  if (path === '/feedback') {
    const list = existsSync(feedbackDir) ? readdirSync(feedbackDir).filter((f) => f.endsWith('.json')).sort().reverse() : []
    res.writeHead(200, { 'content-type': 'application/json' })
    return res.end(JSON.stringify(list.map((f) => JSON.parse(readFileSync(join(feedbackDir, f), 'utf8')))))
  }
  if (path.startsWith('/feedback/')) {
    const f = normalize(join(feedbackDir, decodeURIComponent(path.slice(10))))
    if (!f.startsWith(feedbackDir) || !existsSync(f)) { res.writeHead(404); return res.end() }
    return serveFile(res, f)
  }
  if (path === '/minimap.png') {
    if (!lastMinimap) { res.writeHead(404); return res.end('no minimap yet') }
    res.writeHead(200, { 'content-type': lastMinimap.mime, 'cache-control': 'no-cache' })
    return res.end(lastMinimap.data)
  }
  // Optional: serve the built app over plain http on the LAN, so it can open ws:// (an https page can't).
  if (APP_DIR && (path === '/app' || path.startsWith('/app/'))) {
    const root = resolve(APP_DIR)
    let rel = decodeURIComponent(path.slice(4)) || '/'
    let file = normalize(join(root, rel))
    if (!file.startsWith(root)) { res.writeHead(403); return res.end() }
    if (!existsSync(file) || statSync(file).isDirectory()) file = join(root, 'index.html') // SPA fallback
    if (existsSync(file)) return serveFile(res, file)
  }
  res.writeHead(404)
  res.end('not found')
})

const wss = new WebSocketServer({ noServer: true, maxPayload: 24 << 20 }) // voice notes can be a few MB

server.on('upgrade', (req, socket, head) => {
  if (!authorized(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n')
    socket.destroy()
    return
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req))
})

wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
  clients.add(ws)
  log(`app connected from ${req.socket.remoteAddress} (${clients.size} total)`)
  ws.send(JSON.stringify({ t: 'bridge', game: gameConnected ? 'connected' : 'disconnected', version: gameVersion }))
  if (lastMap) ws.send(JSON.stringify(lastMap))
  if (lastMinimap && lastMap && lastMinimap.key === lastMap.level) ws.send(JSON.stringify(lastMinimap.msg))
  if (lastRoute) ws.send(JSON.stringify(lastRoute))
  if (lastState) ws.send(JSON.stringify(lastState))
  ws.on('message', (data) => {
    let msg: any
    try {
      msg = JSON.parse(String(data))
    } catch {
      return
    }
    if (!msg || typeof msg.t !== 'string' || !COMMAND_TYPES.has(msg.t)) {
      ws.send(JSON.stringify({ t: 'event', kind: 'error', detail: `unknown command ${msg?.t}` }))
      return
    }
    stats.fromApp++
    if (msg.t === 'requestMap' && lastMap) {
      ws.send(JSON.stringify(lastMap))
      if (lastMinimap && lastMinimap.key === lastMap.level) ws.send(JSON.stringify(lastMinimap.msg))
      return
    }
    if (msg.t === 'voiceNote') {
      try {
        const name = saveVoiceNote(msg)
        log('voice note saved:', name)
        broadcast({ t: 'event', kind: 'voiceNoteSaved', detail: name })
      } catch (e) {
        ws.send(JSON.stringify({ t: 'event', kind: 'error', detail: `voice note not saved: ${e}` }))
      }
      return
    }
    if (msg.t === 'ping' && !gameConnected) {
      ws.send(JSON.stringify({ t: 'pong', time: Date.now() / 1000 })) // keep-alive while the game is closed
      return
    }
    if (!sendGame(msg)) ws.send(JSON.stringify({ t: 'event', kind: 'error', detail: 'game not connected' }))
  })
  ws.on('close', () => {
    clients.delete(ws)
    log(`app disconnected (${clients.size} left)`)
  })
})

// ---------------------------------------------------------------------------
// start
// ---------------------------------------------------------------------------

function lanAddresses(): string[] {
  const out: string[] = []
  for (const list of Object.values(networkInterfaces())) {
    for (const a of list ?? []) if (a.family === 'IPv4' && !a.internal) out.push(a.address)
  }
  // likely home-LAN addresses first
  return out.sort((a, b) => Number(!a.startsWith('192.168.')) - Number(!b.startsWith('192.168.')))
}

server.listen(PORT, '0.0.0.0', () => {
  const ips = lanAddresses()
  const ip = ips[0] ?? 'localhost'
  const q = NO_AUTH ? '' : `?token=${TOKEN}`
  console.log('')
  console.log('  Tesla UI <-> BeamNG bridge')
  console.log(`  test page (this PC):  http://localhost:${PORT}/`)
  for (const a of ips) console.log(`  test page (iPad):     http://${a}:${PORT}/${q}`)
  console.log(`  app WebSocket:        ws://${ip}:${PORT}/${q}`)
  if (APP_DIR) console.log(`  app over http:        http://${ip}:${PORT}/app/${q}`)
  if (!NO_AUTH) console.log(`  pairing token:        ${TOKEN}`)
  console.log(`  waiting for BeamNG on ${GAME_HOST}:${GAME_PORT} ...`)
  console.log('')
  if (!QUIET) qrcode.generate(`http://${ip}:${PORT}/${q}`, { small: true })
  connectGame()
})

setInterval(() => {
  const secs = (Date.now() - stats.since) / 1000
  if (gameConnected && stats.state > 0 && !QUIET) {
    process.stdout.write(`\r  state ${(stats.state / secs).toFixed(1)} Hz, traffic ${(stats.traffic / secs).toFixed(1)} Hz, apps ${clients.size}   `)
  }
  stats.state = 0
  stats.traffic = 0
  stats.fromApp = 0
  stats.since = Date.now()
}, 5000)
