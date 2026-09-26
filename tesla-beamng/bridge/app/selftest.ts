// Checks the app-side connector against the fake BeamNG: harness (real mod Lua) -> relay ->
// BeamNGClient/useBeamNG -> stand-in copies of the app's zustand stores via syncBeamNGToApp.
//   npx tsx bridge/app/selftest.ts      (needs luajit + lua-socket + lua-dkjson)

import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { create } from 'zustand'
import { connectBeamNG, useBeamNG, syncBeamNGToApp, lngLatToWorld, worldToLngLat, headingDeg, originFor, type StoreLike } from './index.ts'

const PORT = 18767
const procs: ChildProcess[] = []
const results: boolean[] = []
const check = (name: string, ok: boolean, info = '') => {
  results.push(ok)
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${info ? '  (' + info + ')' : ''}`)
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const cwd = new URL('../..', import.meta.url).pathname
const start = (cmd: string, args: string[], env: Record<string, string> = {}) => {
  const p = spawn(cmd, args, { cwd, env: { ...process.env, ...env } })
  p.stderr.on('data', (d) => process.stderr.write(String(d).replace(/^/gm, '  ! ')))
  if (process.env.VERBOSE) p.stdout.on('data', (d) => process.stdout.write(String(d).replace(/^/gm, '  | ')))
  procs.push(p)
}
process.on('exit', () => procs.forEach((p) => p.kill()))
async function until(fn: () => boolean, ms: number) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) { if (fn()) return true; await sleep(50) }
  return false
}

// geo round trip
{
  const [lon, lat] = worldToLngLat(1234.5, -678.9)
  const w = lngLatToWorld(lon, lat)
  check('geo round trip', Math.abs(w[0] - 1234.5) < 0.01 && Math.abs(w[1] + 678.9) < 0.01)
  check('heading: north 0, east 90', headingDeg([0, 1, 0]) === 0 && Math.abs(headingDeg([1, 0, 0]) - 90) < 1e-9)
}

start('luajit', ['beamng/test/harness.lua'], { HARNESS_SPEED: '4', HARNESS_QUIET: '1' })
await sleep(500)
const notes = mkdtempSync(join(tmpdir(), 'tesla-notes-'))
process.on('exit', () => rmSync(notes, { recursive: true, force: true }))
start(process.execPath, ['--import', 'tsx', 'bridge/relay.ts', '--port', String(PORT), '--feedback-dir', notes, ...(process.env.VERBOSE ? [] : ['--quiet'])])

// stand-ins for src/store.ts, src/sim/drive.ts, src/nav/store.ts (fields per the handoff)
const vehicle = create<any>(() => ({
  gear: 'P', speedMph: 0, locked: true, doors: { FL: false, FR: false, RL: false, RR: false }, frunkOpen: false, trunkOpen: false,
  chargePercent: 50, driverTempF: 70, toggles: { headlightsOn: false, fogLights: false, seatHeat: true },
}))
const sim = create<any>(() => ({ heading: 0, signal: null, control: null, lead: null, fsd: false, profile: 'Standard', arrivalPark: 'Curbside', streakMi: 3 }))
const nav = create<any>(() => ({ position: [0, 0], heading: 0, destination: null, stops: [], route: null }))
const stop = syncBeamNGToApp({ vehicle: vehicle as unknown as StoreLike, sim: sim as unknown as StoreLike, nav: nav as unknown as StoreLike })

connectBeamNG(`ws://127.0.0.1:${PORT}/`)
if (process.env.VERBOSE) useBeamNG.getState().client!.subscribe((m) => m.t === 'status' && console.log('client', m.status))
check('connects and streams state', await until(() => !!useBeamNG.getState().state, 15000), useBeamNG.getState().status)
check('map arrives in the store', await until(() => !!useBeamNG.getState().map, 5000))

check('vehicle store gets game gear + charge', await until(() => vehicle.getState().gear === 'P' && vehicle.getState().chargePercent === 80, 3000),
  JSON.stringify({ gear: vehicle.getState().gear, charge: vehicle.getState().chargePercent }))
check('nav store gets lat/lon position', await until(() => Math.abs(nav.getState().position[0] - 37.39) < 0.01, 3000), JSON.stringify(nav.getState().position))
check('unrelated fields untouched', vehicle.getState().toggles.seatHeat === true && vehicle.getState().driverTempF === 70 && sim.getState().streakMi === 3)

// UI -> game through the stores
vehicle.setState({ gear: 'D' })
check('UI gear change reaches the game', await until(() => useBeamNG.getState().state?.gear === 'D', 3000))
check('store keeps D (no flicker back)', vehicle.getState().gear === 'D')
vehicle.setState({ toggles: { ...vehicle.getState().toggles, headlightsOn: true } })
check('UI headlights reach the game', await until(() => !!useBeamNG.getState().state?.lights.low, 3000))
vehicle.setState({ doors: { ...vehicle.getState().doors, FL: true } })
check('UI door reaches the game', await until(() => useBeamNG.getState().state?.doors.FL === true, 3000))
vehicle.setState({ trunkOpen: true })
check('UI trunk reaches the game', await until(() => useBeamNG.getState().state?.doors.trunk === true, 3000))
await sleep(1500)
check('stores still agree with the game after the hold', vehicle.getState().doors.FL === true && vehicle.getState().trunkOpen === true && vehicle.getState().toggles.headlightsOn === true)
vehicle.setState({ doors: { ...vehicle.getState().doors, FL: false }, trunkOpen: false })

// the cabin camera says the driver is watching the road (else FSD nags, like the real thing)
const c = useBeamNG.getState().client!
const attn = setInterval(() => c.attention('ok'), 200)

// picking a destination on the app's map routes the game car (nav store -> navigate)
{
  const [lon, lat] = worldToLngLat(450, 0, originFor(useBeamNG.getState().map?.level))
  nav.setState({ destination: { name: 'Harness Ave', lat, lon } })
}
check('UI destination routes the game car', await until(() => (useBeamNG.getState().route?.points.length ?? 0) > 5, 5000))
check('route lands in the nav store as [lon, lat]', await until(() => (nav.getState().route?.coords?.length ?? 0) > 5, 5000))
{
  const r = useBeamNG.getState().route!
  const end = r.points[r.points.length - 1]
  check('route ends at the picked place', Math.hypot(end[0] - 450, end[1]) < 15, JSON.stringify(end))
}
// the app's FSD switch engages the game's FSD, with the app's profile
sim.setState({ profile: 'Hurry' })
sim.setState({ fsd: true })
check('UI FSD switch engages FSD in the game', await until(() => !!useBeamNG.getState().state?.autopilot.engaged, 5000))
check('...with the app\'s profile', useBeamNG.getState().state?.autopilot.profile === 'hurry', useBeamNG.getState().state?.autopilot.profile)
check('FSD state lands in the sim store', await until(() => sim.getState().fsd === true, 5000))
check('profile written back in the app\'s format', sim.getState().profile === 'Hurry', sim.getState().profile)
check('speed lands in the vehicle store', await until(() => vehicle.getState().speedMph > 5, 15000), vehicle.getState().speedMph.toFixed(1) + ' mph')
c.holdThrottle(0.9)
check('accelerator strip overrides FSD', await until(() => !!useBeamNG.getState().state?.autopilot.accelOverride, 3000))
c.releaseThrottle()
check('releasing it hands speed back to FSD', await until(() => useBeamNG.getState().state?.autopilot.accelOverride === false && !!useBeamNG.getState().state?.autopilot.engaged, 3000))
sim.setState({ fsd: false })
check('UI FSD switch off disengages in the game', await until(() => useBeamNG.getState().state?.autopilot.engaged === false, 3000))
await sleep(1500)
check('sim store agrees after the hold', sim.getState().fsd === false)
nav.setState({ destination: null })
check('clearing the destination cancels the route', await until(() => !useBeamNG.getState().route, 3000))

// a voice note from the iPad mic (a Blob, as MediaRecorder makes)
c.voiceNote(new Blob([new Uint8Array([82, 73, 70, 70, 1, 2, 3])], { type: 'audio/webm' }), { durationSec: 1 })
check('voice note upload acknowledged', await until(() => useBeamNG.getState().events.some((e) => e.kind === 'voiceNoteSaved'), 3000))
clearInterval(attn)

stop()
useBeamNG.getState().client?.close()
const failed = results.filter((r) => !r).length
console.log(`\n${results.length - failed} passed, ${failed} failed`)
procs.forEach((p) => p.kill())
process.exit(failed ? 1 : 0)
