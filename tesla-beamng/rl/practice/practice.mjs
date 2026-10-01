// Practice runner: keeps the car parking and driving on its own while nobody is playing.
//  - autopark episodes: random spot, random start pose around it -> scored (arrived, alignment, time)
//  - point-to-point episodes: random destination 150-400 m away -> arrived or not
//  - every few autopark episodes it tries a small change of the parking knobs (apTune) and keeps it only if it scored better
// Everything is logged to ~/.tesla-beamng/practice/. Stop it with Ctrl-C or by creating the file STOP in that folder.
import { createRequire } from 'node:module'
import { spawn, execSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const require = createRequire(join(homedir(), 'tesla-beamng', 'package.json'))
const WebSocket = require('ws')

const DIR = join(homedir(), '.tesla-beamng', 'practice')
mkdirSync(DIR, { recursive: true })
const STOP = join(DIR, 'STOP'), LOG = join(DIR, 'episodes.jsonl'), STATE = join(DIR, 'state.json')
const GAME = process.env.BEAMNG_EXE || 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\BeamNG.drive\\BeamNG.drive.exe'
const RELAY = process.env.RELAY || 'ws://127.0.0.1:8765/'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const log = (...a) => console.log(new Date().toLocaleTimeString(), ...a)
const rnd = (a, b) => a + Math.random() * (b - a)
const clamp = (v, a, b) => Math.max(a, Math.min(b, v))
const pick = (a) => a[Math.floor(Math.random() * a.length)]
if (existsSync(STOP)) unlinkSync(STOP)

// knobs the autopark reads (settings.apTune) and the range each may take
const RANGE = { rmin: [5, 8], fwdSpeed: [1.4, 3.2], revSpeed: [0.9, 1.9], tail: [3, 6] }
const state = { best: { rmin: 6, fwdSpeed: 2.2, revSpeed: 1.3, tail: 4.5 }, bestScore: null, episodes: 0, ...(existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : {}) }
const save = () => writeFileSync(STATE, JSON.stringify(state, null, 1))

let ws = null, st = null, map = null, spots = null, evs = []
const send = (o) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)) }

function connect() {
  return new Promise((res) => {
    const w = new WebSocket(RELAY)
    w.on('open', () => { ws = w; res(true) })
    w.on('error', () => res(false))
    w.on('close', () => { if (ws === w) { ws = null; st = null } })
    w.on('message', (d) => {
      let m
      try { m = JSON.parse(d) } catch { return }
      if (m.t === 'state') st = m
      else if (m.t === 'map') map = m
      else if (m.t === 'parkingSpots') spots = m.spots
      else if (m.t === 'event' && !/cameras/.test(m.detail || '')) {
        evs.push(m)
        if (m.kind === 'arriving') send({ t: 'arrivalChoice', choice: pick(['park', 'street']) })
      }
    })
  })
}

async function ensureGame() {
  for (;;) {
    if (existsSync(STOP)) return false
    if (!ws && !(await connect())) {
      let running = false
      try { running = /BeamNG/i.test(execSync('tasklist /FI "IMAGENAME eq BeamNG.drive.x64.exe" /NH').toString()) } catch {}
      if (!running) {
        log('game is not running: starting it')
        spawn(GAME, ['-gfx', 'dx11', '-level', 'east_coast_usa/main.level.json'], { detached: true, stdio: 'ignore' }).unref()
      }
      await sleep(15000)
      continue
    }
    if (st && st.pos) return true
    await sleep(1000)
  }
}

async function loadMap() {
  if (map && spots) return true
  send({ t: 'requestMap' })
  send({ t: 'requestParkingSpots' })
  for (let i = 0; i < 30 && (!map || !spots); i++) await sleep(500)
  return !!(map && spots)
}

const settle = (s = 1.5) => sleep(s * 1000)
async function reset() {
  send({ t: 'autopilot', mode: 'off' }); await settle(0.8)
  send({ t: 'gear', gear: 'P' }); await settle(0.6)
}
async function teleport(p, h) {
  send({ t: 'teleport', x: p[0], y: p[1], z: p[2], hx: h[0], hy: h[1] }); await settle(2.5)
  if (st.dir[0] * h[0] + st.dir[1] * h[1] < 0) {
    send({ t: 'teleport', x: p[0], y: p[1], z: p[2], hx: h[0], hy: h[1], flip: true }); await settle(2.5)
  }
  await settle(1.5)
}

async function waitEnd(timeout) {
  const t0 = Date.now()
  for (let i = 0; Date.now() - t0 < timeout && st; i++) {
    await sleep(500)
    if (existsSync(STOP)) break
    if (i > 12 && !st.autopilot?.engaged && Math.abs(st.speed) < 0.3) break
  }
  await sleep(1000)
  return (Date.now() - t0) / 1000
}

async function parkEpisode(tune) {
  const sp = pick(spots.filter((s) => s.free))
  const a = sp.dir ? [sp.dir[0], sp.dir[1]] : [1, 0]
  const n = Math.hypot(a[0], a[1]) || 1
  a[0] /= n; a[1] /= n
  const p = [-a[1], a[0]], side = pick([1, -1]), kind = pick(['near', 'aisle', 'far'])
  const out = kind === 'near' ? rnd(3.5, 6) : kind === 'aisle' ? rnd(7, 11) : rnd(12, 16)
  const along = rnd(-8, 8), ang = rnd(0, Math.PI * 2)
  const pos = [sp.pos[0] + a[0] * out * side + p[0] * along, sp.pos[1] + a[1] * out * side + p[1] * along, sp.pos[2] - 0.4]
  const h = [Math.cos(ang), Math.sin(ang)]
  await reset()
  evs = []
  send({ t: 'settings', apTune: tune, nags: false })
  await teleport(pos, h)
  send({ t: 'gear', gear: 'D' }); await settle(0.3)
  send({ t: 'autopark', spot: sp.id })
  const secs = await waitEnd(110000)
  const fin = st.pos, hd = st.dir
  const rel = [fin[0] - sp.pos[0], fin[1] - sp.pos[1]]
  const lon = rel[0] * a[0] + rel[1] * a[1], lat = -rel[0] * a[1] + rel[1] * a[0]
  const hdeg = Math.acos(Math.min(1, Math.abs(hd[0] * a[0] + hd[1] * a[1]))) * 180 / Math.PI
  const arrived = evs.some((e) => e.kind === 'arrived')
  const errs = evs.filter((e) => e.kind === 'error').map((e) => String(e.detail || '').slice(0, 80))
  const score = arrived ? clamp(100 - 25 * Math.abs(lat) - 6 * Math.abs(lon) - 2 * hdeg - secs / 6, 5, 100) : 0
  return { type: 'park', spot: sp.id, kind, start: pos.map((x) => +x.toFixed(1)), arrived, lon: +lon.toFixed(2), lat: +lat.toFixed(2), hdeg: +hdeg.toFixed(1), secs: +secs.toFixed(1), score: +score.toFixed(1), errs }
}

async function p2pEpisode() {
  const here = st.pos
  const d = rnd(150, 400)
  const c = (map.nodes || []).filter((nd) => Math.abs(Math.hypot(nd.pos[0] - here[0], nd.pos[1] - here[1]) - d) < 40 && nd.radius > 3.5)
  if (!c.length) return null
  const to = pick(c).pos, arrival = pick(['Street', 'Parking Lot'])
  await reset()
  evs = []
  send({ t: 'gear', gear: 'D' }); await settle(0.5)
  send({ t: 'navigate', to, arrival }); await settle(0.5)
  send({ t: 'autopilot', mode: 'fsd' })
  const secs = await waitEnd(180000)
  const arrived = evs.some((e) => e.kind === 'arrived')
  const dist = Math.hypot(st.pos[0] - to[0], st.pos[1] - to[1])
  const errs = evs.filter((e) => e.kind === 'error' || e.kind === 'disengage').map((e) => `${e.kind}:${String(e.detail || e.reason || '').slice(0, 60)}`).slice(0, 4)
  return { type: 'p2p', arrival, dist0: Math.round(d), arrived, distEnd: +dist.toFixed(0), secs: +secs.toFixed(1), score: arrived ? 100 : 0, errs }
}

function jitter(b) { // one knob moved a little
  const t = { ...b }, k = pick(Object.keys(RANGE)), [lo, hi] = RANGE[k]
  t[k] = +clamp(t[k] + rnd(-0.15, 0.15) * (hi - lo), lo, hi).toFixed(2)
  return [t, k]
}
const mean = (x) => x.reduce((s, v) => s + v, 0) / x.length

async function main() {
  process.on('SIGINT', () => { send({ t: 'autopilot', mode: 'off' }); save(); process.exit(0) })
  log('practice runner: stop with Ctrl-C or by creating', STOP)
  let cand = null, candKey = null, candScores = [], baseScores = []
  while (!existsSync(STOP)) {
    if (!(await ensureGame()) || !(await loadMap())) { await sleep(5000); continue }
    let r = null
    try {
      if (state.episodes % 4 === 3) r = await p2pEpisode()
      else {
        const tune = cand || state.best
        r = await parkEpisode(tune)
        r.tune = tune; r.trial = cand ? candKey : null
        ;(cand ? candScores : baseScores).push(r.score)
        // 6 episodes for the current best, then 6 with one knob changed; the change is kept only when it scored better
        if (cand && candScores.length >= 6) {
          const ref = state.bestScore ?? mean(baseScores)
          const better = mean(candScores) > ref + 2
          log(`trial ${candKey}: ${mean(candScores).toFixed(1)} vs best ${ref.toFixed(1)} -> ${better ? 'kept' : 'dropped'}`)
          if (better) { state.best = cand; state.bestScore = mean(candScores) }
          cand = null; candScores = []; baseScores = []
        } else if (!cand && baseScores.length >= 6) {
          state.bestScore = mean(baseScores);
          [cand, candKey] = jitter(state.best)
          candScores = []
          log('trying', candKey, '->', cand[candKey])
        }
      }
    } catch (e) { log('episode error', e.message); await sleep(3000) }
    if (r) {
      state.episodes++
      appendFileSync(LOG, JSON.stringify({ t: new Date().toISOString(), ...r }) + '\n')
      log(JSON.stringify(r))
      save()
    }
  }
  send({ t: 'autopilot', mode: 'off' }); save(); log('stopped')
  process.exit(0)
}
main()
