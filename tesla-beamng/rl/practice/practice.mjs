// Practice runner: keeps the car parking and driving on its own while nobody is playing.
//  - autopark episodes: random spot, random start pose around it -> scored (arrived, alignment, time)
//  - point-to-point episodes: random destination 150-400 m away -> arrived or not
//  - every few autopark episodes it tries a small change of the parking knobs (apTune) and keeps it only if it scored better
// Everything is logged to ~/.tesla-beamng/practice/. Stop it with Ctrl-C or by creating the file STOP in that folder.
import { createRequire } from 'node:module'
import { spawn, execSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { createServer } from 'node:http'
import { homedir, cpus, setPriority, constants } from 'node:os'
import { join } from 'node:path'
import { screenshot, uploader } from '../lib.mjs'

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
const RANGE = { rmin: [5, 8], fwdSpeed: [1.4, 3.2], revSpeed: [0.9, 1.9], tail: [3, 6], margin: [0, 0.8] }
const DRANGE = { kick: [0.2, 0.7], slideMax: [1.2, 3.5], vMin: [7, 14], kMin: [0.025, 0.07], yawBail: [0.9, 1.6], weaveAmp: [0.8, 2.0], weaveGap: [25, 60], stuntEvery: [12, 40] }
const state = { best: { rmin: 6, fwdSpeed: 2.2, revSpeed: 1.3, tail: 4.5 }, bestScore: null, episodes: 0, ...(existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : {}) }
state.tally = state.tally || { pass: 0, fail: 0 }
state.retryWins = state.retryWins || 0
state.fixes = state.fixes || []
state.hard = state.hard || []
const live = { now: 'starting', started: Date.now(), recent: [], lastState: Date.now(), kicks: 0, slip: 0, prevDrift: null }
const save = () => { try { state.driftBest = actOn(state.dpol, DRANGE, [1], false).tune } catch {} writeFileSync(STATE, JSON.stringify(state, null, 1)) }

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
      if (m.t === 'state') {
        // drift bookkeeping: kicks (handbrake starts) and the biggest angle between where the car points and where it moves
        const dr = m.autopilot?.drift
        if (dr === 'kick' && live.prevDrift !== 'kick') live.kicks++
        live.prevDrift = dr
        if (st && m.speed > 4) {
          const mv = [m.pos[0] - st.pos[0], m.pos[1] - st.pos[1]], ml = Math.hypot(mv[0], mv[1])
          if (ml > 0.05) live.slip = Math.max(live.slip, Math.acos(clamp((mv[0] * m.dir[0] + mv[1] * m.dir[1]) / ml, -1, 1)) * 180 / Math.PI)
        }
        if (live.dmg0 != null && !live.firstHit && (m.damage || 0) - live.dmg0 > 300) live.firstHit = { dmg: Math.round((m.damage || 0) - live.dmg0), phase: m.maneuver?.kind || m.autopilot?.mode || '', step: m.maneuver ? `${m.maneuver.step}/${m.maneuver.total}` : '', v: +(m.speed || 0).toFixed(1), gear: m.gear, pos: m.pos.map((x) => +x.toFixed(1)) }
        st = m; live.lastState = Date.now()
      }
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
      try { running = /BeamNG/i.test(execSync('tasklist /FI "IMAGENAME eq BeamNG.drive.x64.exe" /NH').toString()) || /BeamNG/i.test(execSync('tasklist /FI "IMAGENAME eq BeamNG.drive.exe" /NH').toString()) } catch {}
      // a game that was started less than 4 minutes ago is still loading: never start a second one
      if (!running && Date.now() - (live.launched || 0) > 240000) {
        log('game is not running: starting it')
        live.launched = Date.now()
        // (-windowed crashes this BeamNG version; the window is minimized instead, and the game runs at Idle priority)
        const args = ['-gfx', process.env.PRACTICE_GFX || 'dx11', '-level', 'east_coast_usa/main.level.json']
        spawn(GAME, args, { detached: true, stdio: 'ignore' }).unref()
        setTimeout(() => lowPriority(true), 30000); setTimeout(() => lowPriority(true), 80000); setTimeout(() => lowPriority(true), 150000)
      }
      await sleep(15000)
      continue
    }
    if (st && st.pos) return true
    await sleep(1000)
  }
}

function lowPriority(placeWindow) {
  // the game gets Idle priority (it only uses what nothing else wants) and half of the cores, so a browser stays smooth
  const half = Math.max(2, Math.floor(cpus().length / 2))
  const mask = (2 ** half) - 1
  // a small framed window in the top-left corner so it can be watched (-windowed crashes this version, so it is resized after it starts)
  const mini = !placeWindow ? '' : `; Add-Type -Name U -Namespace W -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr h, int c); [DllImport("user32.dll")] public static extern bool MoveWindow(System.IntPtr h, int x, int y, int w, int hh, bool r); [DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i); [DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int i, int v);'; Get-Process BeamNG.drive.x64 -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { [W.U]::ShowWindowAsync($_.MainWindowHandle, 9) | Out-Null; [W.U]::SetWindowLong($_.MainWindowHandle, -16, ([W.U]::GetWindowLong($_.MainWindowHandle, -16) -bor 0xCF0000)) | Out-Null; [W.U]::MoveWindow($_.MainWindowHandle, 20, 60, 800, 470, $true) | Out-Null }`
  const cmd = `Get-Process BeamNG* | ForEach-Object { $_.PriorityClass = "Idle"; $_.ProcessorAffinity = ${mask} }${mini}`
  try { execSync('powershell -NoProfile -Command "' + cmd.replace(/"/g, '\\"') + '"', { stdio: 'ignore' }) } catch {}
}
try { setPriority(0, constants.priority.PRIORITY_BELOW_NORMAL) } catch {}

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
  send({ t: 'teleport', x: p[0], y: p[1], z: p[2], hx: h[0], hy: h[1], repair: true }); await settle(2.5)
  if (st.dir[0] * h[0] + st.dir[1] * h[1] < 0) {
    send({ t: 'teleport', x: p[0], y: p[1], z: p[2], hx: h[0], hy: h[1], flip: true }); await settle(2.5)
  }
  await settle(1.5)
}

async function waitEnd(timeout) {
  const t0 = Date.now()
  let last = st ? [...st.pos] : null, lastMove = Date.now()
  for (let i = 0; Date.now() - t0 < timeout && st; i++) {
    await sleep(500)
    if (live.trail && st) live.trail.push([st.pos[0], st.pos[1], st.dir[0], st.dir[1], st.gear])
    if (existsSync(STOP)) break
    if (live.dmg0 != null && (st.damage || 0) - live.dmg0 > 8000) { log('hard crash: ending this attempt'); break }
    if (i > 12 && !st.autopilot?.engaged && Math.abs(st.speed) < 0.3) break
    // never sit stuck: nothing has moved for 30 s -> give up on this attempt (the next one starts with a reset)
    if (last && Math.hypot(st.pos[0] - last[0], st.pos[1] - last[1]) > 0.5) { last = [...st.pos]; lastMove = Date.now() }
    else if (Date.now() - lastMove > 30000) { log('no movement for 30 s: giving up on this attempt'); break }
  }
  await sleep(1000)
  return (Date.now() - t0) / 1000
}

// Go to a random parking lot somewhere on the map (hundreds of them) and return a free spot there.
async function randomSpot() {
  const lots = map.parking || []
  for (let tries = 0; tries < 5 && lots.length; tries++) {
    const lot = pick(lots)
    await reset()
    await teleport([lot.pos[0], lot.pos[1], lot.pos[2] + 0.4], lot.dir ? [lot.dir[0], lot.dir[1]] : [1, 0])
    spots = null
    send({ t: 'requestParkingSpots' })
    for (let i = 0; i < 12 && !spots; i++) await sleep(250)
    const free = (spots || []).filter((q) => q.free).sort((u, v) => Math.hypot(u.pos[0] - lot.pos[0], u.pos[1] - lot.pos[1]) - Math.hypot(v.pos[0] - lot.pos[0], v.pos[1] - lot.pos[1]))
    if (free.length) return free[0]
  }
  return pick((spots || []).filter((q) => q.free))
}

async function parkEpisode(kindWanted, fixed, greedy) {
  const sp = fixed ? fixed.sp : await randomSpot()
  if (!sp) throw new Error('no parking spot found')
  const a = sp.dir ? [sp.dir[0], sp.dir[1]] : [1, 0]
  const n = Math.hypot(a[0], a[1]) || 1
  a[0] /= n; a[1] /= n
  const p = [-a[1], a[0]], side = pick([1, -1]), kind = kindWanted || pick(['near', 'aisle', 'far'])
  const out = kind === 'near' ? rnd(3.5, 6) : kind === 'aisle' ? rnd(7, 11) : rnd(12, 16)
  const along = rnd(-8, 8)
  // drivers line up with the road: mostly along the aisle / street (either way), sometimes any direction
  const base = Math.atan2(p[1], p[0]) + (Math.random() < 0.5 ? 0 : Math.PI)
  const ang = Math.random() < 0.3 ? rnd(0, Math.PI * 2) : (Math.random() < 0.5 ? base : Math.atan2(a[1], a[0]) + (Math.random() < 0.5 ? 0 : Math.PI)) + rnd(-0.25, 0.25)
  const pos = fixed ? fixed.pos : [sp.pos[0] + a[0] * out * side + p[0] * along, sp.pos[1] + a[1] * out * side + p[1] * along, sp.pos[2] - 0.4]
  const h = fixed ? fixed.h : [Math.cos(ang), Math.sin(ang)]
  live.now = `parking at spot ${sp.id} (${kind})`
  await reset()
  evs = []
  await teleport(pos, h)
  if (!fixed && (st.damage || 0) > 1500) return { invalid: true, type: 'park', cat: 'park:' + kind, score: 0, errs: ['bad start pose'] }
  live.dmg0 = st.damage || 0; live.firstHit = null
  const f0 = features(st.pos, [st.dir[0], st.dir[1]], sp, a)
  const x = act(f0, !greedy)
  send({ t: 'settings', apTune: x.tune, nags: false })
  live.trail = []
  send({ t: 'gear', gear: 'D' }); await settle(0.3)
  send({ t: 'autopark', spot: sp.id })
  const secs = await waitEnd(110000)
  const fin = st.pos, hd = st.dir
  const rel = [fin[0] - sp.pos[0], fin[1] - sp.pos[1]]
  const lon = rel[0] * a[0] + rel[1] * a[1], lat = -rel[0] * a[1] + rel[1] * a[0]
  const hdeg = Math.acos(Math.min(1, Math.abs(hd[0] * a[0] + hd[1] * a[1]))) * 180 / Math.PI
  const arrived = evs.some((e) => e.kind === 'arrived')
  const errs = evs.filter((e) => e.kind === 'error').map((e) => String(e.detail || '').slice(0, 80))
  const hit = Math.max(0, (st.damage || 0) - live.dmg0)
  if (hit > 600) errs.push(`hit something (damage +${Math.round(hit)}) ${JSON.stringify(live.firstHit)}`)
  // hitting a curb or a wall costs points; a hard hit fails the run outright
  const score = arrived && hit < 6000 ? clamp(100 - 25 * Math.abs(lat) - 6 * Math.abs(lon) - 2 * hdeg - Math.max(0, secs - 60) / 8 - hit / 80, 5, 100) : 0
  // Parking is rarely one move: it pulls forward, backs in, adjusts. Count the extra moves (they are not punished: the finish is what is scored)
  const adjusts = Math.max(0, evs.filter((e) => e.kind === 'autoparkPlan').length - 1) + evs.filter((e) => e.kind === 'notice' && /straighten|another way/.test(String(e.detail || ''))).length
  const trail = live.trail || []
  live.trail = null
  void recordParking({ sp, a, trail, fin, hd, score, lat, lon, hdeg, adjusts, secs, arrived, hit })
  const noRoom = !arrived && secs < 14 && hit < 100 && errs.some((e) => /no room|no free parking/.test(e))
  return { type: 'park', adjusts, invalid: noRoom, cat: 'park:' + kind, hit: Math.round(hit), spot: sp.id, kind, start: pos.map((x) => +x.toFixed(1)), arrived, lon: +lon.toFixed(2), lat: +lat.toFixed(2), hdeg: +hdeg.toFixed(1), secs: +secs.toFixed(1), score: +score.toFixed(1), errs, setup: { sp, pos, h }, tune: x.tune, act: x }
}

// --- pictures of parking jobs ----------------------------------------------------------------------------------------------------
// After every parking episode a top-down picture (SVG: the stall, the path the car took with forward legs blue and reverse legs orange,
// the final pose) is saved next to the numbers; a real screenshot of the game is taken for bad finishes and every 5th episode. Every 10
// episodes a short report plus the worst three and the best one go to GitHub (practice/<stamp>/), so a person or Claude reads a page.
const SHOTS = join(DIR, 'shots')
mkdirSync(SHOTS, { recursive: true })
const PSTAMP = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 16)
const pupload = uploader(`practice/${PSTAMP}`)
const batch = []
let pEp = 0
function parkSvg({ sp, a, trail, fin, hd, score, lat, lon, hdeg, adjusts, secs }) {
  const S = 22, W = 440, H = 440 // 22 px per metre, +-10 m
  const al = Math.hypot(a[0], a[1]) || 1
  const ax = a[0] / al, ay = a[1] / al // the stall's axis points up
  const px = -ay, py = ax
  const T = (x, y) => { const rx = x - sp.pos[0], ry = y - sp.pos[1]; return [W / 2 + (rx * px + ry * py) * S, H / 2 - (rx * ax + ry * ay) * S] }
  const rect = (cx, cy, hx, hy, len, wid, cls) => { // a rectangle centred on (cx,cy), pointing along (hx,hy)
    const hl = Math.hypot(hx, hy) || 1, fx = hx / hl, fy = hy / hl, gx = -fy, gy = fx
    const pts = [[1, 1], [1, -1], [-1, -1], [-1, 1]].map(([u, v]) => T(cx + fx * len / 2 * u + gx * wid / 2 * v, cy + fy * len / 2 * u + gy * wid / 2 * v).map((q) => q.toFixed(1)).join(','))
    return `<polygon points="${pts.join(' ')}" ${cls}/>`
  }
  const legs = []
  for (let i = 1; i < trail.length; i++) {
    const [x0, y0] = T(trail[i - 1][0], trail[i - 1][1]), [x1, y1] = T(trail[i][0], trail[i][1])
    const rev = trail[i][4] === 'R'
    legs.push(`<line x1="${x0.toFixed(1)}" y1="${y0.toFixed(1)}" x2="${x1.toFixed(1)}" y2="${y1.toFixed(1)}" stroke="${rev ? '#ff9f43' : '#4da3ff'}" stroke-width="2"/>`)
  }
  const col = score >= 80 ? '#3ddc84' : score >= 55 ? '#ffd24d' : '#ff5a5a'
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H + 44}" viewBox="0 0 ${W} ${H + 44}"><rect width="100%" height="100%" fill="#1b1c1e"/>
${rect(sp.pos[0], sp.pos[1], ax, ay, 5.5, 2.6, 'fill="none" stroke="#e8e8e8" stroke-width="2"')}
${legs.join('\n')}
${rect(fin[0], fin[1], hd[0], hd[1], 4.6, 1.9, `fill="${col}" fill-opacity="0.35" stroke="${col}" stroke-width="2"`)}
<text x="10" y="${H + 18}" fill="#ddd" font-family="monospace" font-size="13">score ${score.toFixed(0)}  side ${lat.toFixed(2)} m  along ${lon.toFixed(2)} m  angle ${hdeg.toFixed(1)} deg</text>
<text x="10" y="${H + 36}" fill="#999" font-family="monospace" font-size="12">${secs.toFixed(0)} s, ${adjusts} adjusting move(s); blue = forward, orange = reverse, white box = the stall</text></svg>`
}
async function recordParking(e) {
  try {
    const n = ++pEp
    const id = `ep${String(n).padStart(4, '0')}-s${Math.round(e.score)}`
    const svg = parkSvg(e)
    writeFileSync(join(SHOTS, id + '.svg'), svg)
    let jpg = null
    if (e.score < 70 || n % 5 === 0) { const f = join(SHOTS, id + '.jpg'); if (await screenshot(f)) jpg = f }
    batch.push({ n, id, score: e.score, lat: e.lat, lon: e.lon, hdeg: e.hdeg, adjusts: e.adjusts, secs: e.secs, arrived: e.arrived, hit: e.hit, svg: join(SHOTS, id + '.svg'), jpg })
    if (batch.length >= 10) await flushBatch()
  } catch (err) { log('parking picture failed:', err.message) }
}
async function flushBatch() {
  if (!batch.length) return
  const b = batch.splice(0, batch.length)
  const by = [...b].sort((x, y) => x.score - y.score)
  const pick4 = [...by.slice(0, 3), by[by.length - 1]].filter((x, i, arr) => arr.indexOf(x) === i)
  const md = ['# Parking practice ' + PSTAMP, '', '| ep | score | side m | along m | angle | adjusting moves | s | arrived | damage |', '|---|---|---|---|---|---|---|---|---|', ...b.map((x) => `| ${x.n} | ${x.score.toFixed(0)} | ${x.lat.toFixed(2)} | ${x.lon.toFixed(2)} | ${x.hdeg.toFixed(1)} | ${x.adjusts} | ${x.secs.toFixed(0)} | ${x.arrived} | ${x.hit} |`), '', 'Pictures (top-down, blue forward, orange reverse): ' + pick4.map((x) => x.id + '.svg').join(', ')].join('\n')
  const ups = [await pupload(`report-${String(b[0].n).padStart(4, '0')}.md`, Buffer.from(md))]
  for (const x of pick4) { ups.push(await pupload(`${x.id}.svg`, readFileSync(x.svg))); if (x.jpg) ups.push(await pupload(`${x.id}.jpg`, readFileSync(x.jpg))) }
  log('parking batch uploaded:', [...new Set(ups)].join(', '))
}
if (Number(process.env.PRACTICE_HOURS)) setTimeout(() => { try { writeFileSync(STOP, 'time') } catch {} }, Number(process.env.PRACTICE_HOURS) * 3600 * 1000)

// --- scenarios -----------------------------------------------------------------------------------------------------------
// Each scenario has a category; the runner keeps a running score per category and picks weak ones more often.
async function setTraffic(n) {
  send({ t: 'traffic', count: n })
  await settle(n > 0 ? 6 : 1.5)
}

async function p2pEpisode(opts = {}) {
  let to = null
  if (!opts.fromPark && !opts.here) {
    // a random start somewhere on the map (a road node), pointing along the road towards the destination (no U-turn needed)
    const nodes = (map.nodes || []).filter((nd) => nd.radius > 3.5)
    if (nodes.length) {
      const byId = (map._byId ||= new Map((map.nodes || []).map((q) => [q.id, q])))
      const adj = (map._adj ||= (() => { const m = new Map(); for (const l of map.links || []) { if (!(l.drivability > 0.3)) continue; (m.get(l.a) || m.set(l.a, []).get(l.a)).push(l.b); if (!l.oneWay) (m.get(l.b) || m.set(l.b, []).get(l.b)).push(l.a) } return m })())
      const withLinks = nodes.filter((q) => (adj.get(q.id) || []).length)
      const nd = pick(withLinks.length ? withLinks : nodes)
      const d = opts.drift ? rnd(250, 600) : rnd(150, 400)
      const c = (map.nodes || []).filter((q) => Math.abs(Math.hypot(q.pos[0] - nd.pos[0], q.pos[1] - nd.pos[1]) - d) < 40 && q.radius > 3.5)
      if (!c.length) return null
      to = pick(c).pos
      // the neighbour that is closest to the destination
      const nbs = (adj.get(nd.id) || []).map((id) => byId.get(id)).filter(Boolean)
      const nb = nbs.sort((u, v) => Math.hypot(u.pos[0] - to[0], u.pos[1] - to[1]) - Math.hypot(v.pos[0] - to[0], v.pos[1] - to[1]))[0] || nd
      let hx = nb.pos[0] - nd.pos[0], hy = nb.pos[1] - nd.pos[1]
      const hl = Math.hypot(hx, hy) || 1
      hx /= hl; hy /= hl
      const off = Math.min(1.8, nd.radius * 0.4) // right of the road's centre line
      await reset()
      await teleport([nd.pos[0] + hy * off, nd.pos[1] - hx * off, nd.pos[2] + 0.6], [hx, hy])
      if ((st.damage || 0) > 1500) { log('start pose damaged the car (inside something): trying another'); return { invalid: true, type: 'p2p', cat: 'p2p:start', score: 0, errs: ['bad start pose'] } }
    }
  } else if (!opts.fromPark) await reset()
  if (!to) {
    const here = st.pos
    const d = opts.drift ? rnd(250, 600) : rnd(150, 400)
    const c = (map.nodes || []).filter((nd) => Math.abs(Math.hypot(nd.pos[0] - here[0], nd.pos[1] - here[1]) - d) < 40 && nd.radius > 3.5)
    if (!c.length) return null
    to = pick(c).pos
  }
  const arrival = opts.arrival || pick(['Street', 'Parking Lot', 'Curbside', 'Driveway'])
  const profile = opts.profile || pick(['chill', 'standard', 'standard', 'hurry'])
  evs = []
  const nTraffic = opts.traffic ? Math.round(rnd(opts.traffic[0], opts.traffic[1])) : 0
  await setTraffic(nTraffic)
  live.dmg0 = st.damage || 0; live.kicks = 0; live.slip = 0; live.stunts = 0; live.firstHit = null
  const dx = opts.drift ? actOn(state.dpol, DRANGE, [1], true) : null
  send({ t: 'settings', ...(opts.drift ? { drift: true } : {}), ...(dx ? { driftTune: dx.tune } : {}), nags: false })
  send({ t: 'gear', gear: opts.fromPark ? 'P' : 'D' }); await settle(0.5)
  send({ t: 'navigate', to, arrival }); await settle(0.5)
  send({ t: 'autopilot', mode: 'fsd', profile, fromPark: !!opts.fromPark })
  const secs = await waitEnd(200000)
  if (nTraffic) await setTraffic(0)
  const arrived = evs.some((e) => e.kind === 'arrived')
  const hitInfo = live.firstHit
  const stunts = evs.filter((e) => e.kind === 'stunt').length
  const dist = Math.hypot(st.pos[0] - to[0], st.pos[1] - to[1])
  const bad = evs.filter((e) => e.kind === 'error' || (e.kind === 'disengage' && e.reason !== 'arrived'))
  const errs = bad.map((e) => `${e.kind}:${String(e.detail || e.reason || '').slice(0, 60)}`).slice(0, 4)
  const hit = Math.max(0, (st.damage || 0) - live.dmg0)
  if (hit > 600) errs.push(`hit something (damage +${Math.round(hit)})`)
  let score = arrived && hit < 6000 ? clamp(100 - 15 * bad.length - secs / 20 - hit / 80, 20, 100) : 0
  if (opts.drift) {
    // Furious: arriving cleanly is worth 40; drifting (handbrake kicks with a real slide, 12-60 degrees) the other 60; spinning out is not drifting
    const slid = live.slip >= 12 && live.slip <= 60
    // Furious: arriving cleanly 40; drift kicks + a real slide up to 30; weaves / darts (10 each) up to 30; any real damage kills it
    const dscore = arrived && hit < 1500 ? Math.min(30, live.kicks * 10 + (slid ? 10 : 0)) + Math.min(30, stunts * 10) : 0
    score = arrived && hit < 6000 ? clamp(40 - hit / 80 + dscore - 10 * bad.length, 0, 100) : 0
    learn(dx, score)
    errs.push(`kicks ${live.kicks}, slip ${Math.round(live.slip)} deg, stunts ${stunts}`)
  }
  return { type: opts.fromPark ? 'leave' : 'p2p', hit: Math.round(hit), cat: opts.drift ? (opts.traffic ? 'furious:traffic' : 'furious:drift') : opts.traffic ? 'p2p:traffic' : `${opts.fromPark ? 'leave' : 'p2p'}:${arrival}`, arrival, profile, dist0: Math.round(d), arrived, distEnd: +dist.toFixed(0), secs: +secs.toFixed(1), score: +score.toFixed(1), errs }
}

const PASS = 60 // a run counts as passed when it arrived and scored at least this
const CATS = ['park:near', 'park:aisle', 'park:far', 'p2p:Street', 'p2p:Parking Lot', 'p2p:Curbside', 'p2p:Driveway', 'leave:Street', 'p2p:traffic', 'furious:drift', 'furious:traffic']
state.cats = state.cats || {}
function weakCat() { // scores 0-100 -> weight = how much room is left to learn; untried categories first
  const w = CATS.map((c) => { const x = state.cats[c]; return x && x.n >= 3 ? 12 + (100 - x.avg) : 120 })
  const tot = w.reduce((a, b) => a + b, 0)
  let r = Math.random() * tot
  for (let i = 0; i < CATS.length; i++) { r -= w[i]; if (r <= 0) return CATS[i] }
  return CATS[0]
}
function note(cat, score) { const x = state.cats[cat] || { n: 0, avg: 50 }; x.n++; x.pass = (x.pass || 0) + (score >= PASS ? 1 : 0); x.avg = +(x.avg + (score - x.avg) * (x.n < 10 ? 1 / x.n : 0.1)).toFixed(1); state.cats[cat] = x }


// --- the policies: linear Gaussian over a few features, one output per knob -------------------------------------------------
// z_k = w_k . f ; knob_k = lo + (hi - lo) * sigmoid(z_k). Trained with REINFORCE (reward = score/100, running baseline).
//  parking: 7 features of where the car is relative to the spot (features() must match apFeatures() in planner.lua)
//  drift (Furious Max): the stunt's timing/limits, no features (a bandit)
const KNOBS = Object.keys(RANGE), NF = 7
const sig = (z) => 1 / (1 + Math.exp(-z))
const randn = () => Math.sqrt(-2 * Math.log(1 - Math.random())) * Math.cos(2 * Math.PI * Math.random())
const DEFAULTS = { rmin: 6, fwdSpeed: 2.2, revSpeed: 1.3, tail: 4.5, margin: 0.1 }
const DDEFAULTS = { kick: 0.35, slideMax: 2.4, vMin: 9, kMin: 0.04, yawBail: 1.3, weaveAmp: 1.3, weaveGap: 38, stuntEvery: 22 }
function initPol(range, defs, nf) {
  const w = {}
  for (const k of Object.keys(range)) { const [lo, hi] = range[k], u = clamp((defs[k] - lo) / (hi - lo), 0.02, 0.98); w[k] = [Math.log(u / (1 - u)), ...Array(nf - 1).fill(0)] }
  return { w, baseline: 0.5, n: 0 }
}
function fixPol(pol, range, defs, nf) { // a saved policy from an older version: add the knobs it lacks
  const fresh = initPol(range, defs, nf)
  for (const k of Object.keys(range)) if (!pol.w[k] || pol.w[k].length !== nf) pol.w[k] = fresh.w[k]
  return pol
}
state.pol = fixPol(state.pol || initPol(RANGE, DEFAULTS, NF), RANGE, DEFAULTS, NF)
state.dpol = fixPol(state.dpol || initPol(DRANGE, DDEFAULTS, 1), DRANGE, DDEFAULTS, 1)
function features(pos, h, sp, a) {
  const dx = sp.pos[0] - pos[0], dy = sp.pos[1] - pos[1], dist = Math.max(0.5, Math.hypot(dx, dy))
  const rx = pos[0] - sp.pos[0], ry = pos[1] - sp.pos[1]
  return [1, Math.min(dist, 25) / 15, (h[0] * dx + h[1] * dy) / dist, (h[0] * dy - h[1] * dx) / dist, (rx * a[0] + ry * a[1]) / 15, (-rx * a[1] + ry * a[0]) / 15, Math.abs(h[0] * a[0] + h[1] * a[1])]
}
const sigma = (pol) => Math.max(0.12, 0.6 * Math.pow(0.999, pol.n))
function actOn(pol, range, f, explore = true) {
  const sg = explore ? sigma(pol) : 0, eps = {}, tune = {}
  for (const k of Object.keys(range)) {
    const mu = pol.w[k].reduce((s2, w, i) => s2 + w * f[i], 0)
    eps[k] = explore ? randn() : 0
    const [lo, hi] = range[k]
    tune[k] = +(lo + (hi - lo) * sig(mu + sg * eps[k])).toFixed(3)
  }
  return { tune, eps, f, sg, pol, range }
}
const act = (f, explore = true) => actOn(state.pol, RANGE, f, explore)
function learn(x, score) { // one REINFORCE step for one episode
  if (!x || !x.sg) return
  const pol = x.pol, adv = score / 100 - pol.baseline, lr = 0.04
  for (const k of Object.keys(x.range)) for (let i = 0; i < x.f.length; i++) pol.w[k][i] = clamp(pol.w[k][i] + lr * adv * (x.eps[k] / x.sg) * x.f[i], -4, 4)
  pol.baseline += 0.05 * (score / 100 - pol.baseline)
  pol.n++
}
const typical = () => act([1, 0.5, 0.3, 0.3, 0.2, 0.3, 0.5], false).tune

function record(r, cat) {
  r.t = new Date().toISOString()
  if (r.invalid) { // not the policy's fault (no room there, or a bad start pose): log it, do not count or learn
    appendFileSync(LOG, JSON.stringify({ ...r, setup: undefined, act: undefined }) + '\n')
    state.skipped = (state.skipped || 0) + 1
    return
  }
  const pass = r.score >= PASS
  state.episodes++
  state.tally[pass ? 'pass' : 'fail']++
  note(r.cat || cat, r.score)
  delete r.setup
  if (r.act) { r.f = r.act.f.map((v) => +v.toFixed(2)); r.sg = +r.act.sg.toFixed(2); delete r.act }
  live.recent = [{ t: r.t, cat: r.cat || cat, pass, score: r.score, secs: r.secs, attempt: r.attempt || 1, why: (r.errs || [])[0] || '' }, ...live.recent].slice(0, 25)
  appendFileSync(LOG, JSON.stringify(r) + '\n')
  log(pass ? 'PASS' : 'fail', r.cat || cat, 'score', r.score, (r.errs || [])[0] || '')
  save()
}

const PAGE = `<!doctype html><meta charset="utf-8"><title>FSD practice</title><meta name="viewport" content="width=device-width,initial-scale=1">
<style>:root{color-scheme:dark light;--bg:#14161a;--fg:#e8eaed;--mu:#9aa0a6;--ok:#3fb950;--bad:#f85149;--card:#1e2126}
@media(prefers-color-scheme:light){:root{--bg:#f4f5f7;--fg:#1b1d21;--mu:#5f6368;--card:#fff}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px system-ui,sans-serif;padding:16px;max-width:760px}
h1{font-size:18px;margin:0 0 4px}.mu{color:var(--mu)}.row{display:flex;gap:10px;flex-wrap:wrap;margin:12px 0}
.card{background:var(--card);border-radius:10px;padding:12px 14px;min-width:120px;flex:1}.big{font-size:26px;font-weight:600}
table{width:100%;border-collapse:collapse}td,th{padding:5px 6px;text-align:left;font-size:13px}th{color:var(--mu);font-weight:500}
.bar{height:6px;background:#8884;border-radius:3px;overflow:hidden}.bar i{display:block;height:100%;background:var(--ok)}
.ok{color:var(--ok)}.bad{color:var(--bad)}</style>
<h1>FSD practice</h1><div id=now class=mu>connecting</div>
<div class=row><div class=card><div class=mu>Accuracy</div><div class=big id=acc>-</div></div>
<div class=card><div class=mu>Passed</div><div class="big ok" id=p>-</div></div>
<div class=card><div class=mu>Failed</div><div class="big bad" id=f>-</div></div>
<div class=card><div class=mu>Fixed on retry</div><div class=big id=rw>-</div></div></div>
<div class=card><b>By scenario</b><table id=cats></table></div>
<div class=card style="margin-top:10px"><b>Learned policy</b><div id=best class=mu></div></div>
<div class=card style="margin-top:10px"><b>Recent runs</b><table id=rec></table></div>
<script>
const e=(i)=>document.getElementById(i)
async function tick(){try{const s=await (await fetch('/status')).json()
e('now').textContent=s.now+' - running '+s.uptime+', '+s.episodes+' runs'
const n=s.pass+s.fail;e('acc').textContent=n?Math.round(100*s.pass/n)+'%':'-';e('p').textContent=s.pass;e('f').textContent=s.fail;e('rw').textContent=s.retryWins
e('cats').innerHTML='<tr><th>scenario<th>runs<th>pass<th>avg score<th></tr>'+s.cats.map(c=>'<tr><td>'+c.name+'<td>'+c.n+'<td>'+(c.n?Math.round(100*(c.pass||0)/c.n)+'%':'-')+'<td>'+c.avg+'<td style="width:25%"><div class=bar><i style="width:'+c.avg+'%"></i></div></tr>').join('')
e('best').textContent='parking policy: '+s.policy.n+' runs, exploration '+s.policy.sigma+', expected score '+s.policy.baseline+'; Furious Max drift policy: '+s.policy.dn+' runs, expected score '+s.policy.dbase+' - parking picks for a typical start: '+Object.entries(s.best).map(([k,v])=>k+' '+(+v).toFixed(2)).join(', ')
e('rec').innerHTML=s.recent.map(r=>'<tr><td>'+r.t.slice(11,19)+'<td>'+r.cat+(r.attempt>1?' (try '+r.attempt+')':'')+'<td class='+(r.pass?'ok':'bad')+'>'+(r.pass?'passed':'failed')+'<td>'+r.score+'<td class=mu>'+r.why+'</tr>').join('')
}catch(x){e('now').textContent='runner not reachable'}}
tick();setInterval(tick,2000)
</script>`

createServer((req, res) => {
  if (req.url === '/status') {
    const up = Math.round((Date.now() - live.started) / 60000)
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify({ now: live.now, uptime: up >= 60 ? `${Math.floor(up / 60)} h ${up % 60} min` : `${up} min`, episodes: state.episodes, pass: state.tally.pass, fail: state.tally.fail, retryWins: state.retryWins, best: typical(), policy: { n: state.pol.n, sigma: +sigma(state.pol).toFixed(2), baseline: +(state.pol.baseline * 100).toFixed(0), dn: state.dpol.n, dbase: +(state.dpol.baseline * 100).toFixed(0) }, recent: live.recent, cats: CATS.map((c) => ({ name: c, n: state.cats[c]?.n || 0, pass: state.cats[c]?.pass || 0, avg: state.cats[c]?.avg ?? 0 })) }))
  } else { res.setHeader('content-type', 'text/html'); res.end(PAGE) }
}).on('error', () => {}).listen(8780, '127.0.0.1')

// A hung game (no state for 90 s although it is running) is restarted
setInterval(() => lowPriority(false), 120000)
setInterval(() => {
  if (ws && Date.now() - live.lastState > 90000) {
    log('game stopped answering: restarting it')
    live.now = 'restarting the game'
    try { execSync('taskkill /IM BeamNG.drive.x64.exe /F', { stdio: 'ignore' }) } catch {}
    try { ws.close() } catch {}
    ws = null; st = null; map = null; spots = null; live.lastState = Date.now()
  }
}, 15000)

// keep the PC awake while this runs (a child that holds the "system required" flag and ends when this process does)
function keepAwake() {
  const ps = `Add-Type -Namespace W -Name K -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'; while (Get-Process -Id ${process.pid} -ErrorAction SilentlyContinue) { [W.K]::SetThreadExecutionState(2147483649) | Out-Null; Start-Sleep 30 }`
  try { spawn('powershell', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps], { stdio: 'ignore', windowsHide: true }).unref() } catch {}
}

async function main() {
  process.on('SIGINT', () => { send({ t: 'autopilot', mode: 'off' }); send({ t: 'traffic', count: 0 }); send({ t: 'settings', nags: true }); save(); process.exit(0) })
  log('practice runner: stop with Ctrl-C or by creating', STOP)
  lowPriority(true)
  keepAwake()
  while (!existsSync(STOP)) {
    if (!(await ensureGame()) || !(await loadMap())) { await sleep(5000); continue }
    let r = null
    try {
      const cat = weakCat()
      if (cat.startsWith('park')) {
        const kind = cat.split(':')[1]
        r = await parkEpisode(kind)
        if (!r.invalid) learn(r.act, r.score)
        const setup = r.setup
        record(r, cat)
        // not right yet: the same start again (the policy samples a different action each time), up to 4 more tries
        let ok = r.score >= PASS || r.invalid, lastR = r
        for (let k = 1; k <= 4 && !ok && !existsSync(STOP); k++) {
          live.now = `retry ${k}: same start, a different action`
          const r2 = await parkEpisode(kind, setup)
          if (!r2.invalid) learn(r2.act, r2.score)
          r2.attempt = k + 1; r2.retry = true
          lastR = r2
          record(r2, cat)
          if (r2.score >= PASS) { ok = true; state.retryWins++ }
        }
        if (!ok) state.hard = [...state.hard.slice(-19), { t: new Date().toISOString(), cat, spot: lastR.spot, start: lastR.start, errs: lastR.errs }]
      } else if (cat.startsWith('leave')) {
        // park first (so the car sits in a spot), then drive away from it; up to 3 tries
        for (let k = 1; k <= 3 && !existsSync(STOP); k++) {
          live.now = `leaving a spot (try ${k})`
          const pr = await parkEpisode('near', null, true)
          if (!pr.arrived) { record(pr, 'park:near'); continue }
          const lr = await p2pEpisode({ fromPark: true, arrival: 'Street' })
          if (lr) { lr.attempt = k; record(lr, 'leave:Street'); if (lr.score >= PASS) break }
        }
      } else if (cat === 'furious:drift' || cat === 'furious:traffic') {
        live.now = cat === 'furious:traffic' ? 'Furious Max in traffic: cutting up, weaving' : 'Furious Max: drifting and weaving'
        const pr = await p2pEpisode({ drift: true, profile: 'furious', arrival: 'Street', traffic: cat === 'furious:traffic' ? [3, 8] : null })
        if (pr) record(pr, cat)
      } else {
        live.now = `driving to a destination (${cat.split(':')[1]})`
        const pr = await p2pEpisode(cat === 'p2p:traffic' ? { arrival: 'Street', traffic: [4, 10], profile: pick(['standard', 'hurry', 'madmax']) } : { arrival: cat.split(':')[1], traffic: Math.random() < 0.4 ? [1, 4] : null })
        if (pr) record(pr, cat)
      }
    } catch (e) { log('episode error', e.message); await sleep(3000) }
  }
  send({ t: 'autopilot', mode: 'off' }); send({ t: 'traffic', count: 0 }); send({ t: 'settings', nags: true }); save(); await flushBatch(); log('stopped')
  process.exit(0)
}
main()
