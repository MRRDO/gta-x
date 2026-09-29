// End-to-end check against the fake BeamNG (beamng/test/harness.lua):
// harness (real mod Lua) <-TCP-> relay <-WebSocket-> this script acting as the app.
//   npx tsx bridge/e2e.ts      (needs luajit + lua-socket + lua-dkjson)

import { spawn, type ChildProcess } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { WebSocket } from 'ws'
import type { State, MapInfo } from './protocol.ts'

const PORT = 18765
const GAME_PORT = 8766
const procs: ChildProcess[] = []
const results: [string, boolean, string][] = []
const check = (name: string, ok: boolean, info = '') => {
  results.push([name, ok, info])
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${info ? '  (' + info + ')' : ''}`)
}

function start(cmd: string, args: string[], env: Record<string, string> = {}, echo = false) {
  const p = spawn(cmd, args, { cwd: new URL('..', import.meta.url).pathname, env: { ...process.env, ...env } })
  p.stdout.on('data', (d) => echo && process.stdout.write(String(d).replace(/^/gm, '  | ')))
  p.stderr.on('data', (d) => process.stderr.write(String(d).replace(/^/gm, '  ! ')))
  procs.push(p)
  return p
}
const cleanup = () => procs.forEach((p) => p.kill())
process.on('exit', cleanup)

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

const ctrlFile = join(mkdtempSync(join(tmpdir(), 'tesla-ctrl-')), 'ctrl')
writeFileSync(ctrlFile, '')
const playerInput = (line: string) => writeFileSync(ctrlFile, line)
start('luajit', ['beamng/test/harness.lua'], { HARNESS_CTRL: ctrlFile, HARNESS_SPEED: '6', HARNESS_QUIET: process.env.VERBOSE ? '0' : '1' }, !!process.env.VERBOSE)
await sleep(500)
const feedbackDir = mkdtempSync(join(tmpdir(), 'tesla-notes-'))
const buttonsDir = mkdtempSync(join(tmpdir(), 'tesla-buttons-'))
// a stand-in for the app's dist-beamng build, served by the relay at /
const appDir = mkdtempSync(join(tmpdir(), 'tesla-app-'))
mkdirSync(join(appDir, 'assets'))
writeFileSync(join(appDir, 'index.html'), '<!doctype html><title>Tesla UI</title>app-index')
writeFileSync(join(appDir, 'assets', 'main.js'), 'console.log(1)')
const buttonsFile = join(buttonsDir, 'buttons.json')
start(process.execPath, ['--import', 'tsx', 'bridge/relay.ts', '--port', String(PORT), '--game-port', String(GAME_PORT), '--quiet', '--feedback-dir', feedbackDir, '--buttons-file', buttonsFile, '--app', appDir])

let state = null as State | null
let map = null as MapInfo | null
const states: State[] = []
const events: { kind: string; detail?: string }[] = []
let route: any = null
let debug: any = null
let buttonMap: any = null
const camFrames: any[] = []
let camerasMsg: any = null
let camWs: WebSocket | null = null
let camBinary = 0
let camOff = 0
const buttonPresses: number[] = []
let parkingSpots: any = null

async function connectApp(): Promise<WebSocket> {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}/`)
      await new Promise((res, rej) => { ws.once('open', res); ws.once('error', rej) })
      return ws
    } catch { await sleep(250) }
  }
  throw new Error('relay never came up')
}

const ws = await connectApp()
ws.on('message', (d) => {
  const m = JSON.parse(String(d))
  if (m.t === 'state') { state = m; states.push(m) }
  else if (m.t === 'map') map = m
  else if (m.t === 'event') { events.push(m); if (process.env.VERBOSE) console.log('  EVENT', m.kind, m.detail ?? '', JSON.stringify(m.data ?? {}).slice(0, 200)) }
  else if (m.t === 'route') route = m
  else if (m.t === 'debug') debug = m
  else if (m.t === 'buttonMap') buttonMap = m
  else if (m.t === 'cameras') camerasMsg = m
  else if (m.t === 'camera') { if (m.off) camOff++; else camFrames.push(m) }
  else if (m.t === 'wheelButton' && m.down) buttonPresses.push(m.button)
  else if (m.t === 'parkingSpots') parkingSpots = m
  else if (m.t === 'media') mediaMsgs.push(m.action)
  else if (m.t === 'dial') dialMsgs.push(`${m.mode}${m.dir ? ':' + m.dir : ''}`)
})
const mediaMsgs: string[] = []
const dialMsgs: string[] = []
const send = (m: unknown) => ws.send(JSON.stringify(m))
// the app's cabin camera reports the driver's attention a few times a second
let attn: 'ok' | 'phone' | 'eyesOff' | null = 'ok'
const attnTimer = setInterval(() => { if (attn && ws.readyState === ws.OPEN) send({ t: 'attention', state: attn }) }, 150)

async function until(what: string, fn: () => boolean, timeoutMs: number) {
  const t0 = Date.now()
  while (Date.now() - t0 < timeoutMs) {
    if (fn()) return true
    await sleep(50)
  }
  console.log(`  timed out waiting for: ${what}`)
  return false
}

try {
  check('map arrives', await until('map', () => !!map && map.nodes.length > 0, 15000), map ? `${map.nodes.length} nodes, ${map.signals.length} signals` : '')
  check('state streams', await until('state', () => states.length > 30, 10000))
  check('speed limit shown with FSD off', await until('limit', () => Math.abs((state?.speedLimit ?? 0) - 13.4) < 0.3, 3000), String(state?.speedLimit) + ' at ' + JSON.stringify(state?.pos))
  {
    const get = async (p: string) => { const r = await fetch(`http://127.0.0.1:${PORT}${p}`); return [r.status, await r.text()] as const }
    const [s1, b1] = await get('/'), [s2, b2] = await get('/navigate/somewhere'), [s3, b3] = await get('/assets/main.js')
    const [s4] = await get('/assets/missing.js'), [s5, b5] = await get('/test')
    check('relay serves the app at / (SPA fallback, assets, 404 for missing files)',
      s1 === 200 && b1.includes('app-index') && s2 === 200 && b2.includes('app-index') && s3 === 200 && b3.includes('console') && s4 === 404,
      `${s1} ${s2} ${s3} ${s4}`)
    check('test page moved to /test', s5 === 200 && b5.includes('BeamNG bridge test'))
    check('boot screen: the "Waiting for BeamNG" line is hidden (script injected into the app page)', b1.includes('waiting for beamng') && b2.includes('waiting for beamng'))
  }
  {
    const s = states.slice(-40)
    const span = s[s.length - 1].time - s[0].time
    const hz = (s.length - 1) / span
    check('state at ~20 Hz (game time)', hz > 17 && hz < 23, hz.toFixed(1) + ' Hz')
  }
  const st = () => state!
  check('state shape', !!st().vehicle && Array.isArray(st().pos) && typeof st().autopilot.engaged === 'boolean' && st().signal === null,
    JSON.stringify({ gear: st().gear, vehicle: st().vehicle, doors: st().doors }))

  send({ t: 'lights', low: true })
  check('lights low', await until('low beam', () => st().lights.low, 3000))
  send({ t: 'lights', high: true, fog: true })
  check('lights high + fog', await until('high beam', () => st().lights.high && st().lights.fog, 3000))
  send({ t: 'lights', low: false, fog: false })
  check('lights off', await until('lights off', () => !st().lights.low && !st().lights.high && !st().lights.fog, 3000))
  send({ t: 'signal', dir: 'left' })
  check('signal left', await until('left', () => st().signal === 'left', 3000))
  send({ t: 'signal', dir: 'hazard' })
  check('hazard', await until('hazard', () => st().signal === 'hazard', 3000))
  send({ t: 'signal', dir: null })
  check('signal off', await until('off', () => st().signal === null, 3000))
  send({ t: 'door', door: 'FL', open: true })
  check('door FL opens', await until('door', () => st().doors.FL === true, 3000), JSON.stringify(st().doors))
  send({ t: 'door', door: 'FL', open: false })
  check('door FL closes', await until('door', () => st().doors.FL === false, 3000))
  send({ t: 'gear', gear: 'D' })
  await until('D', () => st().gear === 'D', 3000)
  send({ t: 'door', door: 'FR', open: true })
  check('opening a door in D (stopped) shifts to P first', await until('P+door', () => st().gear === 'P' && st().doors.FR === true, 3000),
    `gear ${st().gear}, FR ${st().doors.FR}`)
  send({ t: 'door', door: 'FR', open: false })
  await until('FR closed', () => st().doors.FR === false, 3000)
  send({ t: 'door', door: 'sunroof', open: true })
  check('missing door reports error', await until('error', () => events.some((e) => e.kind === 'error' && /sunroof/.test(e.detail ?? '')), 3000))
  send({ t: 'gear', gear: 'D' })
  check('gear D', await until('D', () => st().gear === 'D', 3000))
  send({ t: 'gear', gear: 'P' })
  check('gear P', await until('P', () => st().gear === 'P', 3000))
  // the UI app's camera socket: one binary image per message
  camWs = new WebSocket(`ws://127.0.0.1:${PORT}/cam/rear`)
  camWs.on('message', (d, isBinary) => { if (isBinary) camBinary++ })
  send({ t: 'hello', app: 'e2e', version: 'test' })
  // --- backup camera (off by default since it flashes the screen on D3D11): nothing in R
  // until the app turns it on; then shift to R -> small off-screen frames; out of R -> off
  send({ t: 'gear', gear: 'R' })
  await sleep(1200)
  check('backup camera off by default (no frames in R)', camFrames.length === 0, `${camFrames.length} frames`)
  send({ t: 'gear', gear: 'N' })
  send({ t: 'settings', camera: { backup: true } })
  await sleep(300)
  send({ t: 'gear', gear: 'R' })
  check('backup camera streams in R', await until('cam', () => camFrames.length >= 3, 6000), `${camFrames.length} frames`)
  {
    const f = camFrames[camFrames.length - 1]
    const png = f ? Buffer.from(f.data, 'base64') : Buffer.alloc(0)
    const isJpeg = png[0] === 0xff && png[1] === 0xd8, isPng = png.length > 4 && png.readUInt32BE(0) === 0x89504e47
    const wantJpeg = process.env.HARNESS_NO_JPG !== '1'
    check(`camera frames are ${wantJpeg ? 'JPEG' : 'PNG (JPEG fallback)'}, mirrored, low-res`, (wantJpeg ? isJpeg : isPng) && f.mirrored === true && f.width === 320 && f.height === 180,
      f ? `${f.mime} ${png.length} B ${f.width}x${f.height}` : 'none')
    const r = await fetch(`http://127.0.0.1:${PORT}/cam/rear.jpg`)
    check('GET /cam/rear.jpg (UI protocol) with CORS', r.status === 200 && r.headers.get('access-control-allow-origin') === '*', String(r.status))
    check('cameras announced on connect', JSON.stringify(camerasMsg?.cams?.[0] ?? {}).includes('"rear"'), JSON.stringify(camerasMsg))
    check('ws /cam/rear streams binary frames', camBinary > 0, `${camBinary} frames`)
    const seqs = camFrames.map((x) => x.seq)
    check('camera frames keep coming (seq increases)', seqs.every((v, i) => i === 0 || v > seqs[i - 1]), seqs.join(','))
  }
  const cam0 = await fetch(`http://127.0.0.1:${PORT}/camera.png`).then((r) => r.status).catch(() => 0)
  check('latest frame at /camera.png (from this PC)', cam0 === 200, String(cam0))
  send({ t: 'gear', gear: 'P' })
  check('camera turns off after leaving R', await until('cam off', () => camOff > 0, 6000))
  const nFrames = camFrames.length
  await sleep(1500)
  check('no frames rendered while not in R', camFrames.length === nFrames, `${camFrames.length - nFrames} extra`)
  send({ t: 'camera', on: true })
  check('camera preview without R', await until('preview', () => camFrames.length > nFrames + 1, 5000))
  send({ t: 'camera', on: false })
  check('preview off', await until('cam off 2', () => camOff > 1, 5000))
  // front camera on request, tagged with its own view
  {
    const n0 = camFrames.length
    send({ t: 'camera', on: true, view: 'front' })
    check('front camera on request', await until('front', () => camFrames.slice(n0).some((f) => f.view === 'front'), 5000), camFrames.slice(n0).map((f) => f.view).join(','))
    check('...and it is not mirrored like the backup camera', camFrames.slice(n0).filter((f) => f.view === 'front').every((f) => f.mirrored === false))
    send({ t: 'camera', on: false, view: 'front' })
    await sleep(500)
    const rearBefore = camFrames.filter((f) => f.view === 'rear').length
    await sleep(1500)
    check('front camera stops when told (no more frames)', camFrames.filter((f) => f.view === 'front').length === camFrames.slice(n0).filter((f) => f.view === 'front').length && camFrames.filter((f) => f.view === 'rear').length === rearBefore)
  }

  send({ t: 'horn', on: true })
  await sleep(200)
  send({ t: 'horn', on: false })

  send({ t: 'debug' })
  check('diagnostics', await until('debug', () => !!debug?.vehicle, 5000), debug ? `ge keys ${Object.keys(debug.ge).length}` : '')

  // --- FSD to a destination: stop sign at x~146, light at x~296 (red 20 s of every 40), lead car at 6 m/s
  send({ t: 'navigate', to: [450, 300, 0], stops: [[430, 0, 0]], arrival: 'Curbside' })
  check('route planned', await until('route', () => route && route.points.length > 10, 5000), route ? `${route.length} m` : '')
  send({ t: 'autopilot', mode: 'fsd', profile: 'standard' })
  check('FSD engages', await until('engaged', () => st().autopilot.engaged && st().autopilot.mode === 'fsd', 4000))
  check('shifts into D', await until('D', () => st().gear === 'D', 4000))
  check('phase: driving', await until('driving', () => st().autopilot.phase === 'driving', 3000), String(st().autopilot.phase))

  let stoppedAtSign = false, stoppedAtLight = false, minGap = Infinity, maxOver = 0, sawSignal = false, sawTurn = false
  let wheelMoved = 0
  let wheelActive = false, wheelMaxErr = 0, wheelMaxPos = 0
  let lastSign = st().autopilot.steerSign, signChangedAt = -1e9 // a steering-sign flip jumps the target once
  const engagedAt = st().time
  const t0 = Date.now()
  while (Date.now() - t0 < 120000) {
    const s = st()
    const a = s.autopilot
    if (a.control?.kind === 'stop' && a.control.dist < 6 && s.speed < 0.3) stoppedAtSign = true
    if (a.control?.kind === 'signal' && a.control.red && a.control.dist < 8 && s.speed < 0.3) stoppedAtLight = true
    if (a.leadGap != null && s.speed > 1) minGap = Math.min(minGap, a.leadGap)
    if (a.speedLimit != null) maxOver = Math.max(maxOver, s.speed - (a.speedLimit + 2 * 0.44704))
    if (s.signal === 'left' || s.signal === 'right') sawSignal = true
    if (a.nextTurn) sawTurn = true
    wheelMoved = Math.max(wheelMoved, Math.abs(s.steeringWheelDeg))
    if (s.autopilot.steerSign !== lastSign) { lastSign = s.autopilot.steerSign; signChangedAt = s.time }
    if (s.wheel?.status === 'active') {
      wheelActive = true
      if (s.time - engagedAt > 1.5 && a.engaged && s.wheel.calibrated && s.time - signChangedAt > 2) wheelMaxErr = Math.max(wheelMaxErr, Math.abs(s.wheel.pos - s.wheel.target))
      wheelMaxPos = Math.max(wheelMaxPos, Math.abs(s.wheel.pos))
    }
    if (events.some((e) => e.kind === 'arrived')) break
    await sleep(40)
  }
  check('stops at the stop sign', stoppedAtSign)
  check('stops for the red light', stoppedAtLight)
  check('keeps distance to the lead car', minGap > 5, `min gap ${minGap.toFixed(1)} m`)
  check('never faster than limit + profile', maxOver < 1, `max over ${maxOver.toFixed(2)} m/s`)
  check('signals for turns', sawSignal)
  check('reports next turn', sawTurn)
  check('steering wheel turns (input path)', wheelMoved > 90, `${wheelMoved.toFixed(0)} deg`)
  const noWheel = process.env.HARNESS_NO_WHEEL === '1'
  if (noWheel) check('no FFB wheel: reports it and drives anyway', st().wheel?.status === 'no wheel', st().wheel?.status)
  else {
  check('FFB wheel spring active while driving', wheelActive, st().wheel ? JSON.stringify(st().wheel) : 'no wheel state')
  check('physical wheel turns with the car', wheelMaxPos > 0.15, `max ${(wheelMaxPos * 450).toFixed(0)} deg`)
  check('physical wheel tracks the target', wheelMaxErr < 0.12, `max error ${(wheelMaxErr * 450).toFixed(0)} deg`)
  }
  check('arrives', events.some((e) => e.kind === 'arrived'))
  check('parks in P and disengages', await until('P', () => st().gear === 'P' && !st().autopilot.engaged, 5000), `gear ${st().gear}`)
  check('phase: parked', await until('parked', () => st().autopilot.phase === 'parked', 3000), String(st().autopilot.phase))
  {
    const d = Math.hypot(st().pos[0] - 450, st().pos[1] - 300)
    check('ends near the destination', d < 12, `${d.toFixed(1)} m away`)
  }

  // --- FSD with no destination, then the player brakes (harness does it 4 s after engaging)
  send({ t: 'cancelRoute' })
  await sleep(300)
  events.length = 0
  send({ t: 'autopilot', mode: 'fsd', profile: 'hurry' })
  check('FSD engages without a destination (follow road)', await until('engaged', () => st().autopilot.engaged, 4000))
  check('player brake disengages', await until('disengage', () => events.some((e) => e.kind === 'disengage' && /brake/.test(e.detail ?? '')), 15000),
    events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
  check('state shows lastDisengage=brake', await until('lastDisengage', () => st().autopilot.lastDisengage?.reason === 'brake' && !st().autopilot.engaged, 3000))
  if (process.env.HARNESS_NO_WHEEL === '1') {
    // keyboard steering and gamepad triggers skip input.event in the game: still caught
    await sleep(500)
    events.length = 0
    send({ t: 'autopilot', mode: 'fsd' })
    check('FSD engages (keyboard player)', await until('engaged', () => st().autopilot.engaged, 4000))
    check('keyboard steering takes over', await until('kbd', () => events.some((e) => e.kind === 'disengage' && e.detail === 'steer'), 15000),
      events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    await sleep(1500)
    events.length = 0
    send({ t: 'autopilot', mode: 'fsd' })
    check('FSD engages (gamepad player)', await until('engaged', () => st().autopilot.engaged, 4000))
    check('gamepad brake trigger takes over', await until('pad', () => events.some((e) => e.kind === 'disengage' && e.detail === 'brake'), 15000),
      events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
  }
  if (process.env.HARNESS_NO_WHEEL !== '1') {
  check('wheel handed back to the game after disengage', await until('available', () => st().wheel?.status === 'available', 3000), st().wheel?.status)
  // 0.39 bug: after a takeover the game's own force feedback stayed off (device id -1)
  if (st().wheel?.gameId !== undefined) {
    check('game force feedback is back on after the takeover', await until('gameFFB', () => (st().wheel?.gameId ?? -1) >= 0, 3000), JSON.stringify(st().wheel))
  }

  // --- the driver grabs the wheel (harness does it 3 s into the third engagement)
  await sleep(500)
  events.length = 0
  send({ t: 'autopilot', mode: 'fsd' })
  check('FSD engages a third time', await until('engaged', () => st().autopilot.engaged, 4000))
  {
    // the harness floors the accelerator 1-3 s in: FSD stays on and goes faster than it would
    let sawOverride = false, fasterThanTarget = false
    const t1 = Date.now()
    while (Date.now() - t1 < 6000 && st().autopilot.engaged) {
      const s = st()
      if (s.autopilot.accelOverride) {
        sawOverride = true
        if (s.throttle >= 0.75) fasterThanTarget = true // the driver's 0.8 goes through, above FSD's own 0.7 cap
      }
      if (sawOverride && !s.autopilot.accelOverride) break
      await sleep(30)
    }
    check('accelerator overrides without disengaging', sawOverride && st().autopilot.engaged)
    check('accelerator pedal goes through (more throttle than FSD uses)', fasterThanTarget)
    check('no throttle disengage', !events.some((e) => e.kind === 'disengage'), events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
  }
  check('grabbing the wheel disengages', await until('grab', () => events.some((e) => e.kind === 'disengage' && /steer/.test(e.detail ?? '')), 15000),
    events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
  await sleep(1500)
  check('a real takeover (held 3 s) does not re-engage', !events.some((e) => e.kind === 'reengaged') && !st().autopilot.engaged,
    events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))

  // --- the harness leans on the wheel for 1 s once the car is over 24 mph: FSD should come back on by itself
  await until('wheel back', () => st().wheel?.status === 'available', 3000)
  events.length = 0
  send({ t: 'autopilot', mode: 'fsd', profile: 'hurry' })
  check('FSD engages a fourth time', await until('engaged', () => st().autopilot.engaged, 4000))
  check('knee bump disengages', await until('bump', () => events.some((e) => e.kind === 'disengage' && e.detail === 'steer'), 30000),
    events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
  check('...and FSD re-engages by itself (accidental, > 22.5 mph)', await until('reengaged', () => events.some((e) => e.kind === 'reengaged') && st().autopilot.engaged, 6000),
    events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))

  // --- the cabin camera sees the driver on their phone: nag, then clears when they look back up
  events.length = 0
  attn = 'phone'
  check('phone in hand -> nag', await until('nag', () => events.some((e) => e.kind === 'nag' && /phone/.test(e.detail ?? '')), 8000),
    events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
  attn = 'ok'
  check('eyes back on the road clears the nag', await until('nag clear', () => (st().autopilot.nag?.level ?? 0) === 0, 4000), JSON.stringify(st().autopilot.nag))
  check('no strike for a short glance', !events.some((e) => e.kind === 'strike'))
  }

  // --- traffic-aware cruise only: the car keeps speed, you steer (the wheel is yours)
  send({ t: 'autopilot', mode: 'off' })
  await until('off', () => !st().autopilot.engaged, 3000)
  send({ t: 'autopilot', mode: 'tacc' })
  check('TACC engages', await until('tacc', () => st().autopilot.engaged && st().autopilot.mode === 'tacc', 4000), st().autopilot.mode)
  await sleep(600)
  check('TACC leaves the wheel to the driver', st().wheel?.status !== 'active', st().wheel?.status)

  // --- settings round trip
  send({ t: 'settings', quirks: { phantomBraking: false }, speedOffsetMph: 3, followDistance: 4 })
  await sleep(300)
  check('settings accepted (no error)', !events.some((e) => e.kind === 'error' && /settings/.test(e.detail ?? '')))

  // --- Dumb Summon: park, then creep forward ~12 m and stop by itself
  send({ t: 'autopilot', mode: 'off' })
  await until('off', () => !st().autopilot.engaged, 3000)
  send({ t: 'gear', gear: 'P' })
  await until('P', () => st().gear === 'P' && st().speed < 0.1, 4000)
  {
    const p0 = [...st().pos]
    events.length = 0
    send({ t: 'summon', dir: 'forward' })
    check('summon starts', await until('summon', () => st().autopilot.engaged && st().autopilot.activity === 'summon', 4000), st().autopilot.activity)
    let maxV = 0
    const ok = await until('summon done', () => {
      if (process.env.VERBOSE && st().speed > maxV) console.log('  summon speed', st().speed.toFixed(2), st().gear, st().time.toFixed(1), st().autopilot.activity)
      maxV = Math.max(maxV, st().speed); return !st().autopilot.engaged
    }, 20000)
    const moved = Math.hypot(st().pos[0] - p0[0], st().pos[1] - p0[1])
    check('summon creeps forward and stops', ok && moved > 8 && moved < 16, `${moved.toFixed(1)} m`)
    check('summon stays at walking pace', maxV < 1.6, `${maxV.toFixed(2)} m/s`)
  }

  // --- voice note from the iPad mic: the relay saves it with the car's context
  // --- wheel buttons: Settings -> "Set" start FSD -> press a wheel button (read by the companion)
  {
    send({ t: 'autopilot', mode: 'off' })
    await until('off', () => !st().autopilot.engaged, 3000)
    send({ t: 'learnButton', action: 'toggleFSD' })
    check('settings: waiting for a button', await until('learning', () => buttonMap?.learning === 'toggleFSD', 3000))
    // the companion (fake wheel): button 4 at 1.5 s (learn), 4.5 s (FSD on), 8 s (FSD off)
    start('python3', ['bridge/wheel_helper.py', '--fake', '--buttons', '--quiet', '--seconds', '11', '--fake-press', '4@1.5,4@4.5,4@8',
      '--url', `ws://127.0.0.1:${PORT}/`])
    check('companion shows up in settings', await until('companion', () => !!buttonMap?.companion, 8000), JSON.stringify(buttonMap?.companion))
    check('pressed button gets the action', await until('learned', () => buttonMap?.map?.toggleFSD === 4 && !buttonMap.learning, 6000), JSON.stringify(buttonMap?.map))
    check('mapping saved to disk', (() => { try { return JSON.parse(readFileSync(buttonsFile, 'utf8')).toggleFSD === 4 } catch { return false } })())
    check('button starts FSD', await until('fsd on', () => st().autopilot.engaged && st().autopilot.mode === 'fsd', 6000))
    check('same button stops it', await until('fsd off', () => !st().autopilot.engaged, 6000))
    check('presses reach the app (for the settings screen)', buttonPresses.filter((b) => b === 4).length >= 3, buttonPresses.join(','))
    const before = st().autopilot.profile
    send({ t: 'action', name: 'profileNext' })
    check('action: next profile', await until('profile', () => st().autopilot.profile !== before, 3000), `${before} -> ${st().autopilot.profile}`)
    send({ t: 'setButton', action: 'volumeUp', button: 31 })
    await until('vol mapped', () => buttonMap?.map?.volumeUp === 31, 3000)
    send({ t: 'wheelButton', button: 31, down: true })
    check('G29 dial mapped to volumeUp reaches the app as media', await until('media', () => mediaMsgs.includes('volumeUp'), 3000), mediaMsgs.join(','))
    send({ t: 'setButton', action: 'volumeUp', button: null })
    // the dial: turn = volume until its button is clicked, then it controls follow distance
    send({ t: 'setButton', action: 'dialUp', button: 32 })
    send({ t: 'setButton', action: 'dialDown', button: 33 })
    send({ t: 'setButton', action: 'dialClick', button: 34 })
    await until('dial mapped', () => buttonMap?.map?.dialClick === 34, 3000)
    mediaMsgs.length = 0
    send({ t: 'wheelButton', button: 32, down: true })
    check('dial turn = volume by default', await until('dial vol', () => mediaMsgs.includes('volumeUp') && dialMsgs.includes('volume:up'), 3000), dialMsgs.join(','))
    send({ t: 'wheelButton', button: 34, down: true })
    check('dial click switches to follow distance', await until('dial mode', () => dialMsgs.includes('distance'), 3000), dialMsgs.join(','))
    events.length = 0
    send({ t: 'wheelButton', button: 33, down: true })
    check('dial turn now changes the follow distance (not the volume)', await until('dial dist', () => events.some((e: any) => e.kind === 'settings' && /follow distance/.test(e.detail ?? '')) && !mediaMsgs.includes('volumeDown'), 3000), dialMsgs.join(','))
    for (const a of ['dialUp', 'dialDown', 'dialClick']) send({ t: 'setButton', action: a, button: null })
    send({ t: 'setButton', action: 'toggleFSD', button: null })
    check('clear a button', await until('cleared', () => buttonMap?.map?.toggleFSD === undefined, 3000))
  }

  // --- Start Self-Driving from Park with Brake Confirm: the app sends fromPark while the driver
  // holds the game's brake; that held brake must not count as a takeover
  {
    send({ t: 'autopilot', mode: 'off' })
    await until('off', () => !st().autopilot.engaged, 3000)
    send({ t: 'gear', gear: 'P' })
    await until('P', () => st().gear === 'P', 3000)
    events.length = 0
    playerInput('brake 0.6')
    check('app sees the brake pedal (Brake Confirm)', await until('brake', () => st().brake > 0.3, 4000), String(st().brake))
    send({ t: 'autopilot', mode: 'fsd', profile: 'standard', fromPark: true })
    check('Start Self-Driving from Park engages', await until('fsd', () => st().autopilot.engaged, 4000))
    await sleep(800)
    check('held brake (the confirm) does not disengage', st().autopilot.engaged, events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    playerInput('brake 0')
    check('the car picks its own gear and moves off', await until('go', () => (st().gear === 'D' || st().gear === 'R') && st().speed > 0.3, 8000),
      `gear ${st().gear}, ${st().speed.toFixed(2)} m/s, phase ${st().autopilot.phase}`)
    await sleep(400) // let the release land first
    playerInput('brake 0.7')
    check('a new brake press still takes over', await until('brake takeover', () => events.some((e) => e.kind === 'disengage' && e.detail === 'brake'), 5000),
      events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    playerInput('brake 0')
  }

  // --- wheel paddles (bound to the turn signals) and the H-shifter while FSD drives
  {
    send({ t: 'autopilot', mode: 'fsd', profile: 'standard' })
    await until('fsd', () => st().autopilot.engaged, 4000)
    await until('moving', () => st().speed > 4, 10000)
    events.length = 0
    playerInput('paddle left')
    check('paddle (turn signal) asks FSD for a lane change or the next turn', await until('paddle', () => events.some((e) => (e.kind === 'laneChange' && /driver/.test(JSON.stringify(e))) || e.kind === 'turnRequest'), 5000),
      events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    {
      // the blinker may cancel after the turn (like a real one); it must not drop before it
      let droppedEarly = '', t0 = Date.now()
      while (Date.now() - t0 < 1500) {
        const s1 = st()
        if (s1.signal !== 'left' && (s1.autopilot.nextTurn?.dist ?? 0) > 10) droppedEarly = `${s1.signal} with the turn ${s1.autopilot.nextTurn?.dist} m away`
        await sleep(50)
      }
      check('your turn signal stays on while FSD acts on it', !droppedEarly, droppedEarly)
    }
    events.length = 0
    playerInput('shifter N')
    check('H-shifter moved under FSD: put back in D, FSD stays on', await until('gear back', () => st().gear === 'D' && events.some((e) => e.kind === 'notice'), 4000) && st().autopilot.engaged,
      `gear ${st().gear}, engaged ${st().autopilot.engaged}, ` + events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    // P while FSD drives: pull over (FSD stays on until it's parked; a takeover cancels)
    await until('moving again', () => st().speed > 3, 8000)
    events.length = 0
    send({ t: 'gear', gear: 'P' })
    check('P while FSD drives: pulls over instead of slamming into Park', await until('pullOver', () => events.some((e) => e.kind === 'pullOver'), 3000) && st().autopilot.engaged && st().gear !== 'P',
      `gear ${st().gear}, engaged ${st().autopilot.engaged}, ` + events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    playerInput('')
    send({ t: 'autopilot', mode: 'off' })
    await until('off', () => !st().autopilot.engaged, 3000)
  }

  // --- parking spots on the map + tap one to park there
  {
    parkingSpots = null
    send({ t: 'requestParkingSpots', near: [75, 150], radius: 60 })
    check('parking spots near a point come back for the map', await until('spots', () => Array.isArray(parkingSpots?.spots) && parkingSpots.spots.length > 0, 3000), JSON.stringify(parkingSpots))
    const spot = parkingSpots?.spots?.[0]
    events.length = 0
    route = null
    send({ t: 'autopark', spot: spot?.id })
    check('tapping a far spot makes it the destination (route to it)', await until('route to spot', () => events.some((e) => e.kind === 'autopark') && !!route && route.points.length > 1, 4000),
      events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    send({ t: 'cancelRoute' })
  }

  // --- Auto Shift out of Park: press the brake in P, the car picks D (nothing in front)
  {
    send({ t: 'autopilot', mode: 'off' })
    await until('off', () => !st().autopilot.engaged, 3000)
    await until('stopped', () => st().speed < 0.3, 15000)
    send({ t: 'gear', gear: 'P' })
    await until('P', () => st().gear === 'P', 3000)
    send({ t: 'settings', autoShift: true })
    await sleep(300)
    events.length = 0
    playerInput('brake 0.6')
    check('Auto Shift: brake in Park picks a gear by itself', await until('autoshift', () => events.some((e) => e.kind === 'autoShift') && st().gear === 'D', 4000),
      `gear ${st().gear} ` + events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    playerInput('brake 0')
    send({ t: 'settings', autoShift: false })
  }

  // --- a crash: damage jumps -> red alert "Pull over immediately", FSD lets go, hazards
  {
    send({ t: 'autopilot', mode: 'fsd', profile: 'standard' })
    await until('fsd', () => st().autopilot.engaged, 4000)
    await sleep(1500)
    events.length = 0
    playerInput('crash 3000')
    check('crash: red alert, FSD off, hazards on', await until('crash', () => st().autopilot.alert?.kind === 'crash' && !st().autopilot.engaged && st().signal === 'hazard', 4000),
      JSON.stringify(st().autopilot.alert) + ` engaged ${st().autopilot.engaged} signal ${st().signal}`)
    playerInput('repair')
    check('...and the alert clears once the car is repaired', await until('repaired', () => !st().autopilot.alert, 3000), JSON.stringify(st().autopilot.alert))
    send({ t: 'signal', dir: 'none' })
  }

  // --- Tesla driving aids: speed limit with FSD off, auto headlights, creep / Vehicle Hold
  {
    send({ t: 'autopilot', mode: 'off' })
    await until('off', () => !st().autopilot.engaged, 3000)
    playerInput('tod 0.5') // midnight
    check('auto headlights: on at night', await until('lights on', () => st().lights?.low === true, 4000), JSON.stringify(st().lights))
    playerInput('tod 0.02') // noon
    check('auto headlights: off in daylight', await until('lights off', () => st().lights?.low === false, 4000), JSON.stringify(st().lights))
    playerInput('brake 1')
    await until('stopped', () => st().speed < 0.3, 20000)
    send({ t: 'gear', gear: 'D' })
    send({ t: 'settings', stoppingMode: 'creep' })
    await sleep(300)
    playerInput('brake 0')
    check('stopping mode creep: moves off with no pedals', await until('creep', () => st().speed > 0.5, 6000), `speed ${st().speed.toFixed(2)} gear ${st().gear}`)
    send({ t: 'settings', stoppingMode: 'hold', regen: true })
    check('stopping mode hold: regen slows it and Vehicle Hold holds it', await until('hold', () => st().speed < 0.1 && st().hold === true, 10000),
      `speed ${st().speed.toFixed(2)} hold ${st().hold}`)
    await sleep(1500)
    check('...and it stays stopped with no brake pressed', st().speed < 0.1 && st().brake > 0.3, `speed ${st().speed.toFixed(2)} brake ${st().brake}`)
    send({ t: 'settings', stoppingMode: 'roll', regen: false })
  }

  // --- low confidence: FSD asks for a takeover, keeps driving, and the accelerator hands the car over
  {
    playerInput('place 300 -1.8 0') // the creep test above may have left the car in a field
    await sleep(600)
    send({ t: 'gear', gear: 'D' })
    send({ t: 'autopilot', mode: 'fsd', profile: 'standard' })
    await until('fsd', () => st().autopilot.engaged, 4000)
    await until('moving', () => st().speed > 3, 10000)
    send({ t: 'settings', confidenceFloor: 2 }) // "always unsure"
    check('low confidence: asks the driver to take over', await until('lowconf', () => st().autopilot.alert?.kind === 'lowConfidence', 6000), JSON.stringify(st().autopilot.alert))
    await sleep(1500)
    check('...and keeps driving if nobody touches anything', st().autopilot.engaged && st().speed > 1, `engaged ${st().autopilot.engaged} speed ${st().speed.toFixed(1)}`)
    events.length = 0
    playerInput('throttle 0.7')
    check('...the accelerator then hands the car over', await until('handover', () => events.some((e) => e.kind === 'disengage' && e.detail === 'throttle'), 4000),
      events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    playerInput('throttle 0')
    send({ t: 'settings', confidenceFloor: 0.55 })
    send({ t: 'autopilot', mode: 'off' })
    await until('off', () => !st().autopilot.engaged, 3000)
  }

  // --- Swerve Assist while the driver drives: yank the wheel back and forth at ~50 mph
  if (process.env.HARNESS_NO_WHEEL !== '1') {
    send({ t: 'autopilot', mode: 'off' })
    await until('off', () => !st().autopilot.engaged, 3000)
    send({ t: 'gear', gear: 'D' })
    playerInput('throttle 1')
    const fast = await until('50 mph', () => st().speed > 21.5, 30000)
    events.length = 0
    for (let k = 0; k < 8 && !events.some((e) => e.kind === 'swerveAssist'); k++) {
      playerInput(`steering ${k % 2 ? -0.6 : 0.6}`)
      await sleep(450)
    }
    check('Swerve Assist steps in when the driver swerves at speed', fast && await until('swerve', () => events.some((e) => e.kind === 'swerveAssist' && e.detail === 'stabilizing'), 3000),
      `speed ${st().speed.toFixed(1)} ` + events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    playerInput('steering 0')
    await sleep(300)
    playerInput('throttle 0')
    check('...and hands the car back once it settles', await until('swerve done', () => events.some((e) => e.kind === 'swerveAssist' && e.detail === 'done'), 8000),
      events.map((e) => e.kind + ':' + (e.detail ?? '')).join(', '))
    playerInput('brake 1')
    await until('stopped', () => st().speed < 0.5, 20000)
    playerInput('brake 0')
  }

  // --- PIN to Drive and Valet Mode
  {
    send({ t: 'autopilot', mode: 'off' })
    send({ t: 'gear', gear: 'P' })
    await until('P', () => st().gear === 'P' && st().speed < 0.3, 8000)
    send({ t: 'pinLock', on: true })
    events.length = 0
    send({ t: 'autopilot', mode: 'fsd', profile: 'standard' })
    check('PIN to Drive: FSD refuses while locked', await until('pin fsd', () => events.some((e) => e.kind === 'error' && /PIN/.test(e.detail ?? '')), 3000) && !st().autopilot.engaged)
    send({ t: 'gear', gear: 'D' })
    check('PIN to Drive: the car goes back to Park', await until('pin park', () => st().gear === 'P' && events.some((e) => e.kind === 'pinRequired'), 6000), `gear ${st().gear}`)
    send({ t: 'pinLock', on: false })
    events.length = 0
    send({ t: 'settings', valet: true })
    send({ t: 'autopilot', mode: 'fsd', profile: 'standard' })
    check('Valet Mode: FSD refuses', await until('valet fsd', () => events.some((e) => e.kind === 'error' && /Valet/.test(e.detail ?? '')), 3000) && !st().autopilot.engaged)
    send({ t: 'settings', valet: false })
  }

  // --- light shows (only while parked)
  {
    send({ t: 'autopilot', mode: 'off' })
    send({ t: 'gear', gear: 'P' })
    await until('P', () => st().gear === 'P' && st().speed < 0.3, 8000)
    events.length = 0
    send({ t: 'lightShow', name: 'welcome' })
    check('light show starts while parked', await until('show start', () => events.some((e) => e.kind === 'lightShow' && e.detail === 'welcome'), 3000))
    let sawHigh = false, sawFog = false
    const t0 = Date.now()
    while (Date.now() - t0 < 2600) { const l = st().lights; if (l?.high) sawHigh = true; if (l?.fog) sawFog = true; await sleep(60) }
    check('...and really flashes the lights (high beams and fog)', sawHigh && sawFog, `high ${sawHigh} fog ${sawFog}`)
    check('...then ends by itself', await until('show end', () => events.some((e) => e.kind === 'lightShow' && e.detail === 'end'), 3000))
  }

  {
    const audio = Buffer.from('RIFF....WAVEfmt fake audio').toString('base64')
    send({ t: 'voiceNote', audio, mime: 'audio/wav', durationSec: 2.5, text: 'it braked for a shadow' })
    check('voice note saved', await until('saved', () => events.some((e) => e.kind === 'voiceNoteSaved'), 3000))
    const files = readdirSync(feedbackDir)
    const meta = files.find((f) => f.endsWith('.json'))
    const ctx = meta ? JSON.parse(readFileSync(join(feedbackDir, meta), 'utf8')) : null
    check('voice note has audio + context', files.some((f) => f.endsWith('.wav')) && ctx?.text === 'it braked for a shadow' && !!ctx?.car?.pos && Array.isArray(ctx?.recentEvents),
      files.join(', '))
    const list = await fetch(`http://127.0.0.1:${PORT}/feedback`).then((r) => r.json()).catch(() => null)
    check('GET /feedback lists it', Array.isArray(list) ? list.length > 0 : !!list && JSON.stringify(list).includes('note-'), JSON.stringify(list)?.slice(0, 120))
  }
  {
  }
} catch (e) {
  check('no exceptions', false, String(e))
}

clearInterval(attnTimer)
try { camWs?.close() } catch { /* already closed */ }
rmSync(feedbackDir, { recursive: true, force: true })
rmSync(buttonsDir, { recursive: true, force: true })
rmSync(appDir, { recursive: true, force: true })
const failed = results.filter((r) => !r[1]).length
console.log(`\n${results.length - failed} passed, ${failed} failed`)
cleanup()
process.exit(failed ? 1 : 0)
