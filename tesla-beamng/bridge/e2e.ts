// End-to-end check against the fake BeamNG (beamng/test/harness.lua):
// harness (real mod Lua) <-TCP-> relay <-WebSocket-> this script acting as the app.
//   npx tsx bridge/e2e.ts      (needs luajit + lua-socket + lua-dkjson)

import { spawn, type ChildProcess } from 'node:child_process'
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

start('luajit', ['beamng/test/harness.lua'], { HARNESS_SPEED: '6', HARNESS_QUIET: process.env.VERBOSE ? '0' : '1' }, !!process.env.VERBOSE)
await sleep(500)
start(process.execPath, ['--import', 'tsx', 'bridge/relay.ts', '--port', String(PORT), '--game-port', String(GAME_PORT), '--quiet'])

let state = null as State | null
let map = null as MapInfo | null
const states: State[] = []
const events: { kind: string; detail?: string }[] = []
let route: any = null
let debug: any = null

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
  else if (m.t === 'event') events.push(m)
  else if (m.t === 'route') route = m
  else if (m.t === 'debug') debug = m
})
const send = (m: unknown) => ws.send(JSON.stringify(m))

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
  send({ t: 'door', door: 'sunroof', open: true })
  check('missing door reports error', await until('error', () => events.some((e) => e.kind === 'error' && /sunroof/.test(e.detail ?? '')), 3000))
  send({ t: 'gear', gear: 'D' })
  check('gear D', await until('D', () => st().gear === 'D', 3000))
  send({ t: 'gear', gear: 'P' })
  check('gear P', await until('P', () => st().gear === 'P', 3000))
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

  let stoppedAtSign = false, stoppedAtLight = false, minGap = Infinity, maxOver = 0, sawSignal = false, sawTurn = false
  let wheelMoved = 0
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
  check('arrives', events.some((e) => e.kind === 'arrived'))
  check('parks in P and disengages', await until('P', () => st().gear === 'P' && !st().autopilot.engaged, 5000), `gear ${st().gear}`)
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
} catch (e) {
  check('no exceptions', false, String(e))
}

const failed = results.filter((r) => !r[1]).length
console.log(`\n${results.length - failed} passed, ${failed} failed`)
cleanup()
process.exit(failed ? 1 : 0)
