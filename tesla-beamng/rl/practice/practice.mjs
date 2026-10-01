// Practice runner: keeps the car parking and driving on its own while nobody is playing.
//  - autopark episodes: random spot, random start pose around it -> scored (arrived, alignment, time)
//  - point-to-point episodes: random destination 150-400 m away -> arrived or not
//  - every few autopark episodes it tries a small change of the parking knobs (apTune) and keeps it only if it scored better
// Everything is logged to ~/.tesla-beamng/practice/. Stop it with Ctrl-C or by creating the file STOP in that folder.
import { createRequire } from 'node:module'
import { spawn, execSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { createServer } from 'node:http'
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
state.tally = state.tally || { pass: 0, fail: 0 }
state.retryWins = state.retryWins || 0
state.fixes = state.fixes || []
state.hard = state.hard || []
const live = { now: 'starting', started: Date.now(), recent: [], lastState: Date.now() }
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
      if (m.t === 'state') { st = m; live.lastState = Date.now() }
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
        // lightweight: small window, below-normal priority so it never competes with what you are doing
        const args = ['-gfx', process.env.PRACTICE_GFX || 'dx11', '-level', 'east_coast_usa/main.level.json']
        if (!process.env.PRACTICE_FULL) args.push('-windowed', '-resx', '640', '-resy', '360')
        const g = spawn(GAME, args, { detached: true, stdio: 'ignore' })
        g.unref()
        setTimeout(lowPriority, 20000); setTimeout(lowPriority, 60000)
      }
      await sleep(15000)
      continue
    }
    if (st && st.pos) return true
    await sleep(1000)
  }
}

function lowPriority() {
  const cmd = 'Get-Process BeamNG* | ForEach-Object { $_.PriorityClass = "BelowNormal" }'
  try { execSync('powershell -NoProfile -Command "' + cmd.replace(/"/g, '\\"') + '"', { stdio: 'ignore' }) } catch {}
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
  let last = st ? [...st.pos] : null, lastMove = Date.now()
  for (let i = 0; Date.now() - t0 < timeout && st; i++) {
    await sleep(500)
    if (existsSync(STOP)) break
    if (i > 12 && !st.autopilot?.engaged && Math.abs(st.speed) < 0.3) break
    // never sit stuck: nothing has moved for 30 s -> give up on this attempt (the next one starts with a reset)
    if (last && Math.hypot(st.pos[0] - last[0], st.pos[1] - last[1]) > 0.5) { last = [...st.pos]; lastMove = Date.now() }
    else if (Date.now() - lastMove > 30000) { log('no movement for 30 s: giving up on this attempt'); break }
  }
  await sleep(1000)
  return (Date.now() - t0) / 1000
}

async function parkEpisode(kindWanted, fixed, greedy) {
  const sp = fixed ? fixed.sp : pick(spots.filter((s) => s.free))
  const a = sp.dir ? [sp.dir[0], sp.dir[1]] : [1, 0]
  const n = Math.hypot(a[0], a[1]) || 1
  a[0] /= n; a[1] /= n
  const p = [-a[1], a[0]], side = pick([1, -1]), kind = kindWanted || pick(['near', 'aisle', 'far'])
  const out = kind === 'near' ? rnd(3.5, 6) : kind === 'aisle' ? rnd(7, 11) : rnd(12, 16)
  const along = rnd(-8, 8), ang = rnd(0, Math.PI * 2)
  const pos = fixed ? fixed.pos : [sp.pos[0] + a[0] * out * side + p[0] * along, sp.pos[1] + a[1] * out * side + p[1] * along, sp.pos[2] - 0.4]
  const h = fixed ? fixed.h : [Math.cos(ang), Math.sin(ang)]
  live.now = `parking at spot ${sp.id} (${kind})`
  await reset()
  evs = []
  await teleport(pos, h)
  const f0 = features(st.pos, [st.dir[0], st.dir[1]], sp, a)
  const x = act(f0, !greedy)
  send({ t: 'settings', apTune: x.tune, nags: false })
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
  return { type: 'park', cat: 'park:' + kind, spot: sp.id, kind, start: pos.map((x) => +x.toFixed(1)), arrived, lon: +lon.toFixed(2), lat: +lat.toFixed(2), hdeg: +hdeg.toFixed(1), secs: +secs.toFixed(1), score: +score.toFixed(1), errs, setup: { sp, pos, h }, tune: x.tune, act: x }
}

// --- scenarios -----------------------------------------------------------------------------------------------------------
// Each scenario has a category; the runner keeps a running score per category and picks weak ones more often.
async function p2pEpisode(opts = {}) {
  const here = st.pos
  const d = rnd(150, 400)
  const c = (map.nodes || []).filter((nd) => Math.abs(Math.hypot(nd.pos[0] - here[0], nd.pos[1] - here[1]) - d) < 40 && nd.radius > 3.5)
  if (!c.length) return null
  const to = pick(c).pos
  const arrival = opts.arrival || pick(['Street', 'Parking Lot', 'Curbside', 'Driveway'])
  const profile = opts.profile || pick(['chill', 'standard', 'standard', 'hurry'])
  if (!opts.fromPark) await reset()
  evs = []
  send({ t: 'gear', gear: opts.fromPark ? 'P' : 'D' }); await settle(0.5)
  send({ t: 'navigate', to, arrival }); await settle(0.5)
  send({ t: 'autopilot', mode: 'fsd', profile, fromPark: !!opts.fromPark })
  const secs = await waitEnd(200000)
  const arrived = evs.some((e) => e.kind === 'arrived')
  const dist = Math.hypot(st.pos[0] - to[0], st.pos[1] - to[1])
  const bad = evs.filter((e) => e.kind === 'error' || (e.kind === 'disengage' && e.reason !== 'arrived'))
  const errs = bad.map((e) => `${e.kind}:${String(e.detail || e.reason || '').slice(0, 60)}`).slice(0, 4)
  const score = arrived ? clamp(100 - 15 * bad.length - secs / 20, 20, 100) : 0
  return { type: opts.fromPark ? 'leave' : 'p2p', cat: `${opts.fromPark ? 'leave' : 'p2p'}:${arrival}`, arrival, profile, dist0: Math.round(d), arrived, distEnd: +dist.toFixed(0), secs: +secs.toFixed(1), score: +score.toFixed(1), errs }
}

const PASS = 60 // a run counts as passed when it arrived and scored at least this
const CATS = ['park:near', 'park:aisle', 'park:far', 'p2p:Street', 'p2p:Parking Lot', 'p2p:Curbside', 'p2p:Driveway', 'leave:Street']
state.cats = state.cats || {}
function weakCat() { // scores 0-100 -> weight = how much room is left to learn; untried categories first
  const w = CATS.map((c) => { const x = state.cats[c]; return x && x.n >= 3 ? 12 + (100 - x.avg) : 120 })
  const tot = w.reduce((a, b) => a + b, 0)
  let r = Math.random() * tot
  for (let i = 0; i < CATS.length; i++) { r -= w[i]; if (r <= 0) return CATS[i] }
  return CATS[0]
}
function note(cat, score) { const x = state.cats[cat] || { n: 0, avg: 50 }; x.n++; x.pass = (x.pass || 0) + (score >= PASS ? 1 : 0); x.avg = +(x.avg + (score - x.avg) * (x.n < 10 ? 1 / x.n : 0.1)).toFixed(1); state.cats[cat] = x }


// --- the policy: linear Gaussian over 7 features of where the car is relative to the spot, one output per autopark knob -----
// z_k = w_k . f ; knob_k = lo + (hi - lo) * sigmoid(z_k). Trained with REINFORCE (reward = score/100, running baseline).
// features() must match apFeatures() in planner.lua, which uses the learned weights in normal play.
const KNOBS = Object.keys(RANGE), NF = 7
const sig = (z) => 1 / (1 + Math.exp(-z))
const randn = () => Math.sqrt(-2 * Math.log(1 - Math.random())) * Math.cos(2 * Math.PI * Math.random())
const DEFAULTS = { rmin: 6, fwdSpeed: 2.2, revSpeed: 1.3, tail: 4.5 }
if (!state.pol) {
  state.pol = { w: {}, baseline: 0.5, n: 0 }
  for (const k of KNOBS) { const [lo, hi] = RANGE[k], u = (DEFAULTS[k] - lo) / (hi - lo); state.pol.w[k] = [Math.log(u / (1 - u)), ...Array(NF - 1).fill(0)] }
}
function features(pos, h, sp, a) {
  const dx = sp.pos[0] - pos[0], dy = sp.pos[1] - pos[1], dist = Math.max(0.5, Math.hypot(dx, dy))
  const rx = pos[0] - sp.pos[0], ry = pos[1] - sp.pos[1]
  return [1, Math.min(dist, 25) / 15, (h[0] * dx + h[1] * dy) / dist, (h[0] * dy - h[1] * dx) / dist, (rx * a[0] + ry * a[1]) / 15, (-rx * a[1] + ry * a[0]) / 15, Math.abs(h[0] * a[0] + h[1] * a[1])]
}
const sigma = () => Math.max(0.12, 0.6 * Math.pow(0.999, state.pol.n))
function act(f, explore = true) {
  const sg = explore ? sigma() : 0, eps = {}, tune = {}
  for (const k of KNOBS) {
    const mu = state.pol.w[k].reduce((s2, w, i) => s2 + w * f[i], 0)
    eps[k] = explore ? randn() : 0
    const [lo, hi] = RANGE[k]
    tune[k] = +(lo + (hi - lo) * sig(mu + sg * eps[k])).toFixed(3)
  }
  return { tune, eps, f, sg }
}
function learn(x, score) { // one REINFORCE step for one episode
  if (!x || !x.sg) return
  const adv = score / 100 - state.pol.baseline, lr = 0.04
  for (const k of KNOBS) for (let i = 0; i < NF; i++) state.pol.w[k][i] = clamp(state.pol.w[k][i] + lr * adv * (x.eps[k] / x.sg) * x.f[i], -4, 4)
  state.pol.baseline += 0.05 * (score / 100 - state.pol.baseline)
  state.pol.n++
}
const typical = () => { // what the policy picks for an ordinary start (shown on the page)
  const f = [1, 0.5, 0.3, 0.3, 0.2, 0.3, 0.5], t = act(f, false).tune
  return t
}

function record(r, cat) {
  r.t = new Date().toISOString()
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
e('best').textContent='policy trained on '+s.policy.n+' runs, exploration '+s.policy.sigma+', expected score '+s.policy.baseline+' - picks for a typical start: '+Object.entries(s.best).map(([k,v])=>k+' '+(+v).toFixed(2)).join(', ')
e('rec').innerHTML=s.recent.map(r=>'<tr><td>'+r.t.slice(11,19)+'<td>'+r.cat+(r.attempt>1?' (try '+r.attempt+')':'')+'<td class='+(r.pass?'ok':'bad')+'>'+(r.pass?'passed':'failed')+'<td>'+r.score+'<td class=mu>'+r.why+'</tr>').join('')
}catch(x){e('now').textContent='runner not reachable'}}
tick();setInterval(tick,2000)
</script>`

createServer((req, res) => {
  if (req.url === '/status') {
    const up = Math.round((Date.now() - live.started) / 60000)
    res.setHeader('content-type', 'application/json')
    res.end(JSON.stringify({ now: live.now, uptime: up >= 60 ? `${Math.floor(up / 60)} h ${up % 60} min` : `${up} min`, episodes: state.episodes, pass: state.tally.pass, fail: state.tally.fail, retryWins: state.retryWins, best: typical(), policy: { n: state.pol.n, sigma: +sigma().toFixed(2), baseline: +(state.pol.baseline * 100).toFixed(0) }, recent: live.recent, cats: CATS.map((c) => ({ name: c, n: state.cats[c]?.n || 0, pass: state.cats[c]?.pass || 0, avg: state.cats[c]?.avg ?? 0 })) }))
  } else { res.setHeader('content-type', 'text/html'); res.end(PAGE) }
}).on('error', () => {}).listen(8780, '127.0.0.1')

// A hung game (no state for 90 s although it is running) is restarted
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
  process.on('SIGINT', () => { send({ t: 'autopilot', mode: 'off' }); save(); process.exit(0) })
  log('practice runner: stop with Ctrl-C or by creating', STOP)
  keepAwake()
  while (!existsSync(STOP)) {
    if (!(await ensureGame()) || !(await loadMap())) { await sleep(5000); continue }
    let r = null
    try {
      const cat = weakCat()
      if (cat.startsWith('park')) {
        const kind = cat.split(':')[1]
        r = await parkEpisode(kind)
        learn(r.act, r.score)
        const setup = r.setup
        record(r, cat)
        // not right yet: the same start again (the policy samples a different action each time), up to 4 more tries
        let ok = r.score >= PASS, lastR = r
        for (let k = 1; k <= 4 && !ok && !existsSync(STOP); k++) {
          live.now = `retry ${k}: same start, a different action`
          const r2 = await parkEpisode(kind, setup)
          learn(r2.act, r2.score)
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
      } else {
        live.now = `driving to a destination (${cat.split(':')[1]})`
        const pr = await p2pEpisode({ arrival: cat.split(':')[1] })
        if (pr) record(pr, cat)
      }
    } catch (e) { log('episode error', e.message); await sleep(3000) }
  }
  send({ t: 'autopilot', mode: 'off' }); save(); log('stopped')
  process.exit(0)
}
main()
