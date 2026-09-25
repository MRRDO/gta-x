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
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto'
import { spawn, type ChildProcess } from 'node:child_process'
import { WebSocketServer, WebSocket } from 'ws'
import qrcode from 'qrcode-terminal'
import { ACTIONS, COMMAND_TYPES, type ActionName, type ButtonMap, type CameraFrame, type MapInfo, type Minimap } from './protocol.ts'
import { beamngModsDirs } from './beamngPaths.ts'

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
// --tunnel: a Cloudflare quick tunnel gives the relay an https address, so the live (https)
// app can connect with wss:// and the iPad's mic + camera work. Needs cloudflared installed.
const TUNNEL = arg('tunnel') === 'true'
const APP_URL = (arg('app-url') ?? 'https://tesla-ui-atv.tesla-ui-atv.workers.dev').replace(/\/+$/, '')
if (TUNNEL && NO_AUTH) {
  console.error('--tunnel puts the relay on the internet: it always needs the token (drop --no-auth)')
  process.exit(1)
}

// A pairing token so nobody else on the Wi-Fi (or the internet, with --tunnel) can drive
// the car. Kept across restarts. 16 hex chars; older short tokens are upgraded.
const tokenFile = join(here, '.token')
let TOKEN = existsSync(tokenFile) ? readFileSync(tokenFile, 'utf8').trim() : ''
if (TOKEN.length < 16) {
  TOKEN = randomBytes(8).toString('hex')
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

// ---------------------------------------------------------------------------
// backup camera: the game renders small PNGs into its user folder while in R and tells us
// where; we read them (same PC) and stream them to the app. If we can't find the files,
// we ask the game to send the image data inline instead.
// ---------------------------------------------------------------------------

let lastCam: { data: Buffer; mime: string; seq: number } | null = null
let camMisses = 0
let camInlineAsked = false
const userFolders = () => [arg('beamng-user'), ...beamngModsDirs().map((d) => dirname(d))].filter(Boolean) as string[]

function pngComplete(b: Buffer) {
  return b.length > 24 && b.readUInt32BE(0) === 0x89504e47 && b.subarray(b.length - 12).includes('IEND')
}

async function onCamFrame(msg: any) {
  if (msg.off) {
    lastCam = null
    broadcast({ t: 'camera', view: 'rear', off: true } satisfies CameraFrame)
    return
  }
  let data: Buffer | null = null
  if (msg.data) data = Buffer.from(msg.data, 'base64')
  else {
    const paths = [msg.path, ...userFolders().map((u) => join(u, String(msg.rel ?? '')))].filter(Boolean) as string[]
    for (const p of paths) {
      try { data = await readFile(p); break } catch { /* next */ }
    }
  }
  if (!data || !pngComplete(data)) {
    // not there (or still being written): after a few misses, have the game send the bytes
    if (!msg.data && ++camMisses >= 3 && !camInlineAsked) {
      camInlineAsked = true
      log('backup camera: frames not readable from disk, asking the game to send them inline')
      sendGame({ t: 'camera', inline: true })
    }
    return
  }
  camMisses = 0
  lastCam = { data, mime: 'image/png', seq: msg.seq ?? 0 }
  broadcast({
    t: 'camera', view: 'rear', seq: msg.seq, mime: 'image/png', data: data.toString('base64'),
    width: msg.width, height: msg.height, mirrored: msg.mirrored !== false,
  } satisfies CameraFrame, true)
}

// ---------------------------------------------------------------------------
// wheel buttons: the companion (wheel_helper.py) reports presses, the app's settings
// map them to actions, and a press sends the action to the game. Saved across restarts.
// ---------------------------------------------------------------------------

const buttonsFile = resolve(arg('buttons-file') ?? join(here, 'buttons.json'))
const ACTION_NAMES = new Set<string>(ACTIONS.map((a) => a.name))
let buttonMap: Partial<Record<ActionName, number>> = {}
try {
  const saved = JSON.parse(readFileSync(buttonsFile, 'utf8'))
  for (const [k, v] of Object.entries(saved)) if (ACTION_NAMES.has(k) && Number.isInteger(v)) buttonMap[k as ActionName] = v as number
} catch { /* first run */ }
let learning: ActionName | null = null
let companion: { ws: WebSocket; name: string; buttons: number } | null = null

function buttonMapMsg(): ButtonMap {
  return { t: 'buttonMap', map: buttonMap, learning, companion: companion ? { name: companion.name, buttons: companion.buttons } : null }
}
function saveButtons() {
  try { writeFileSync(buttonsFile, JSON.stringify(buttonMap, null, 2)) } catch (e) { log('could not save buttons:', e) }
}
function assignButton(action: ActionName, button: number | null) {
  // one action per button: a button taken by another action moves here
  if (button != null) for (const k of Object.keys(buttonMap) as ActionName[]) if (buttonMap[k] === button) delete buttonMap[k]
  if (button == null) delete buttonMap[action]
  else buttonMap[action] = button
  saveButtons()
}
/** Relay-side handling of button messages. Returns true when handled. */
function handleButtons(ws: WebSocket, msg: any): boolean {
  switch (msg.t) {
    case 'companionHello':
      companion = { ws, name: String(msg.name ?? 'wheel'), buttons: Number(msg.buttons) || 0 }
      log(`wheel companion: ${companion.name}, ${companion.buttons} buttons`)
      broadcast(buttonMapMsg())
      return true
    case 'requestButtonMap':
      ws.send(JSON.stringify(buttonMapMsg()))
      return true
    case 'learnButton':
      learning = msg.action && ACTION_NAMES.has(msg.action) ? msg.action : null
      broadcast(buttonMapMsg())
      return true
    case 'setButton':
      if (!ACTION_NAMES.has(msg.action)) return true
      assignButton(msg.action, Number.isInteger(msg.button) ? msg.button : null)
      broadcast(buttonMapMsg())
      return true
    case 'wheelButton': {
      const button = Number(msg.button)
      if (!Number.isInteger(button)) return true
      broadcast({ t: 'wheelButton', button, down: !!msg.down }, true)
      if (!msg.down) return true
      if (learning) {
        assignButton(learning, button)
        log(`button ${button} -> ${learning}`)
        learning = null
        broadcast(buttonMapMsg())
        return true
      }
      const action = (Object.keys(buttonMap) as ActionName[]).find((k) => buttonMap[k] === button)
      if (action) {
        if (!sendGame({ t: 'action', name: action })) broadcast({ t: 'event', kind: 'error', detail: 'game not connected' })
      }
      return true
    }
  }
  return false
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
    case 'camFrame':
      void onCamFrame(msg)
      return
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

// Requests from this PC skip the token. A tunnel (cloudflared) also connects from 127.0.0.1,
// so anything carrying proxy headers counts as remote and needs the token.
const PROXY_HEADERS = ['x-forwarded-for', 'forwarded', 'cf-connecting-ip', 'cf-ray', 'x-real-ip']
function isLoopback(req: IncomingMessage) {
  const a = req.socket.remoteAddress ?? ''
  if (!(a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1')) return false
  return !PROXY_HEADERS.some((h) => req.headers[h] != null)
}

// wrong tokens: after 10 in a minute from one address, that address is shut out for 5 minutes
const authFails = new Map<string, { n: number; since: number; blockedUntil: number }>()
function clientAddress(req: IncomingMessage) {
  const h = req.headers['cf-connecting-ip'] ?? req.headers['x-forwarded-for']
  return (Array.isArray(h) ? h[0] : h)?.split(',')[0].trim() || req.socket.remoteAddress || '?'
}
function tokenOk(given: string | null) {
  if (!given) return false
  const a = Buffer.from(given), b = Buffer.from(TOKEN)
  return a.length === b.length && timingSafeEqual(a, b)
}
function authorized(req: IncomingMessage) {
  if (NO_AUTH || isLoopback(req)) return true
  const who = clientAddress(req)
  const now = Date.now()
  const f = authFails.get(who)
  if (f && now < f.blockedUntil) return false
  const url = new URL(req.url ?? '/', 'http://x')
  if (tokenOk(url.searchParams.get('token'))) return true
  const rec = f && now - f.since < 60_000 ? f : { n: 0, since: now, blockedUntil: 0 }
  rec.n++
  if (rec.n >= 10) { rec.blockedUntil = now + 5 * 60_000; log(`blocked ${who} for 5 min (wrong tokens)`) }
  authFails.set(who, rec)
  return false
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
    const local = isLoopback(req)
    return res.end(JSON.stringify({ game: gameConnected, version: gameVersion, clients: clients.size, level: lastMap?.level ?? null,
      tunnel: local ? tunnelUrl : undefined, appLink: local && tunnelUrl ? appPairingLink(APP_URL, tunnelUrl, TOKEN) : undefined }))
  }
  // private: voice notes (with where the car was) and the backup camera need the token off this PC
  if ((path === '/feedback' || path.startsWith('/feedback/') || path.startsWith('/camera')) && !authorized(req)) {
    res.writeHead(401)
    return res.end('token required')
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
  if (path === '/camera.png') {
    if (!lastCam) { res.writeHead(404); return res.end('backup camera off') }
    res.writeHead(200, { 'content-type': lastCam.mime, 'cache-control': 'no-store' })
    return res.end(lastCam.data)
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
  ws.send(JSON.stringify(buttonMapMsg()))
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
    if (handleButtons(ws, msg)) return
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
    if (companion?.ws === ws) { companion = null; broadcast(buttonMapMsg()) }
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
  if (!QUIET && !TUNNEL) qrcode.generate(`http://${ip}:${PORT}/${q}`, { small: true })
  connectGame()
  if (TUNNEL) startTunnel()
})

// ---------------------------------------------------------------------------
// Cloudflare quick tunnel (--tunnel): https://<random>.trycloudflare.com -> this relay.
// The address changes every start, so scan the new QR code each time.
// ---------------------------------------------------------------------------

let tunnelUrl: string | null = null
let tunnelProc: ChildProcess | null = null
let tunnelRestarts = 0

function findCloudflared(): string | null {
  const own = arg('cloudflared')
  if (own) return own
  const names = process.platform === 'win32' ? ['cloudflared.exe'] : ['cloudflared']
  const dirs = [...(process.env.PATH ?? '').split(process.platform === 'win32' ? ';' : ':'),
    'C:\\Program Files (x86)\\cloudflared', 'C:\\Program Files\\cloudflared',
    join(process.env.LOCALAPPDATA ?? '', 'Microsoft', 'WinGet', 'Links')]
  for (const d of dirs) for (const n of names) if (d && existsSync(join(d, n))) return join(d, n)
  return null
}

/** The live app's address with the tunnel's wss URL (the app's bridgeUrl() reads ?bridge=). */
function appPairingLink(appUrl: string, tunnel: string, token: string) {
  const wss = tunnel.replace(/^https:/, 'wss:') + '/?token=' + token
  return `${appUrl}/?bridge=${encodeURIComponent(wss)}`
}

function startTunnel() {
  const exe = findCloudflared()
  if (!exe) {
    console.log('  --tunnel: cloudflared not found. Install it (winget install Cloudflare.cloudflared) or pass --cloudflared <path>.')
    console.log('  using the Wi-Fi address instead (no iPad mic/camera in Safari over plain http):')
    const ip = lanAddresses()[0] ?? 'localhost'
    if (!QUIET) qrcode.generate(`http://${ip}:${PORT}/?token=${TOKEN}`, { small: true })
    return
  }
  tunnelProc = spawn(exe, ['tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${PORT}`], { stdio: ['ignore', 'pipe', 'pipe'] })
  const onData = (d: Buffer) => {
    const m = String(d).match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/)
    if (m && m[0] !== tunnelUrl) {
      tunnelUrl = m[0]
      const link = appPairingLink(APP_URL, tunnelUrl, TOKEN)
      console.log('')
      console.log(`  tunnel (https):       ${tunnelUrl}`)
      console.log(`  test page (anywhere): ${tunnelUrl}/?token=${TOKEN}`)
      console.log(`  app on the iPad:      ${link}`)
      console.log('  scan this on the iPad (a new code every start):')
      qrcode.generate(link, { small: true })
    }
  }
  tunnelProc.stdout?.on('data', onData)
  tunnelProc.stderr?.on('data', onData)
  tunnelProc.on('exit', (code) => {
    tunnelProc = null
    tunnelUrl = null
    if (shuttingDown) return
    const wait = Math.min(30, 2 ** tunnelRestarts++) * 1000
    log(`tunnel stopped (${code}); restarting in ${wait / 1000} s`)
    setTimeout(startTunnel, wait)
  })
}

let shuttingDown = false
for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, () => { shuttingDown = true; tunnelProc?.kill(); process.exit(0) })
}
process.on('exit', () => tunnelProc?.kill())

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
