// Soak test: FSD drives on its own for hours, everything it does is recorded, the car is reset every few minutes, and a small report
// is written (and uploaded to GitHub when the black box token is set up) so a person or Claude reads ONE short file, not the raw log.
//
//   node rl/soak/soak.mjs            (or "Soak Start.bat")      stop: create the file STOP (or "Soak Stop.bat"), or SOAK_HOURS runs out
//
// Needs: the relay and BeamNG running with a car in a level (the launcher service does that). Nothing here touches settings except
// turning driver monitoring off for the run, so the car is never pulled over for a driver that is not there.
// Output (per run of the soak): ~/.tesla-beamng/soak/<stamp>/ : runs/run-NN.jsonl.gz (all samples, 10 Hz), events.jsonl, summary.json,
//   incidents.json (the moments worth looking at: +-6 s of samples around each), final.md (the report to read first).
import { createRequire } from 'node:module'
import { mkdirSync, appendFileSync, writeFileSync, readFileSync, existsSync, unlinkSync } from 'node:fs'
import { gzipSync } from 'node:zlib'
import { homedir } from 'node:os'
import { join } from 'node:path'

const require = createRequire(import.meta.url)
const WebSocket = require('ws')

const ENV = process.env
const RELAY = ENV.RELAY || 'ws://127.0.0.1:8765/'
const RUN_SEC = Number(ENV.SOAK_RUN_SEC) || (Number(ENV.SOAK_RUN_MIN) || 12) * 60
const MAX_SEC = (Number(ENV.SOAK_HOURS) || 6) * 3600
const HOME = join(homedir(), '.tesla-beamng')
const ROOT = join(HOME, 'soak')
const STOP = join(ROOT, 'STOP')
const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 16)
const OUT = join(ROOT, stamp)
mkdirSync(join(OUT, 'runs'), { recursive: true })
try { if (existsSync(STOP)) unlinkSync(STOP) } catch {}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const log = (...a) => { const l = `${new Date().toLocaleTimeString()} ${a.join(' ')}`; console.log(l); try { appendFileSync(join(OUT, 'soak.log'), l + '\n') } catch {} }
const r1 = (v, d = 2) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 10 ** d) / 10 ** d : null)
const stopping = () => existsSync(STOP)
const pick = (a) => a[Math.floor(Math.random() * a.length)]

// ---- link to the relay --------------------------------------------------------------------------------------------------------
let ws = null, st = null, map = null
let run = null // the run being recorded
const send = (o) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)) }
function connect() {
  return new Promise((res) => {
    const w = new WebSocket(RELAY)
    w.on('open', () => { ws = w; send({ t: 'hello', app: 'tesla-soak', version: '1' }); res(true) })
    w.on('error', () => res(false))
    w.on('close', () => { if (ws === w) { ws = null; st = null } })
    w.on('message', (d) => {
      let m
      try { m = JSON.parse(d) } catch { return }
      if (m.t === 'state') { st = m; if (run) sample(m) }
      else if (m.t === 'map') map = m
      else if (m.t === 'event' && run && !/cameras/.test(m.detail || '')) event(m)
    })
  })
}

// ---- recording ----------------------------------------------------------------------------------------------------------------
// one sample = a compact array so a 12 minute run stays under a megabyte (gzipped much less); COLS names every position
const COLS = ['t', 'x', 'y', 'v', 'steer', 'wheelDeg', 'thr', 'brk', 'gear', 'sig', 'dmg', 'fps', 'eng', 'mode', 'tgt', 'lim', 'lead', 'ctl', 'lane', 'laneChg', 'alert', 'conf', 'phase', 'act', 'ffb', 'rearDist', 'yawRate', 'aLat', 'aLon']
function sample(m) {
  const now = Date.now() / 1000
  if (run.last && now - run.last < 0.095) return
  const ap = m.autopilot || {}
  const p = m.pos || []
  // acceleration from what the car actually did (speed and heading change over the last sample)
  let yaw = null, aLat = null, aLon = null
  const prev = run.prev
  if (prev && now - prev.t > 0.05 && now - prev.t < 0.5) {
    const dt = now - prev.t
    const h = Math.atan2(m.dir?.[1] ?? 0, m.dir?.[0] ?? 1)
    let dh = h - prev.h
    while (dh > Math.PI) dh -= 2 * Math.PI
    while (dh < -Math.PI) dh += 2 * Math.PI
    yaw = dh / dt
    aLat = (m.speed || 0) * yaw
    aLon = ((m.speed || 0) - prev.v) / dt
  }
  run.prev = { t: now, h: Math.atan2(m.dir?.[1] ?? 0, m.dir?.[0] ?? 1), v: m.speed || 0 }
  run.last = now
  const row = [r1(now - run.t0, 1), r1(p[0], 1), r1(p[1], 1), r1(m.speed), r1(m.steering, 3), r1(m.steeringWheelDeg, 1), r1(m.throttle), r1(m.brake), m.gear ?? null, m.signal ?? null, r1(m.damage ?? ap.damage, 0), r1(m.fps, 0),
    ap.engaged ? 1 : 0, ap.mode ?? null, r1(ap.targetSpeed), r1(ap.speedLimit), r1(ap.leadGap, 1), ap.control ? `${ap.control.kind}@${r1(ap.control.dist, 0)}${ap.control.state ? ':' + ap.control.state : ''}` : null,
    ap.lane?.index ?? null, ap.lane?.changing ? `${ap.lane.changing.dir}:${ap.lane.changing.reason}:${ap.lane.changing.phase}` : null, ap.alert ? `${ap.alert.kind}:${ap.alert.level}` : null, r1(ap.confidence),
    ap.phase ?? null, ap.activity ?? null, m.wheel?.status ?? null, m.safety?.rearDist ?? null, r1(yaw, 3), r1(aLat), r1(aLon)]
  run.rows.push(row)
}
function event(m) {
  const e = { t: r1(Date.now() / 1000 - run.t0, 1), kind: m.kind, detail: m.detail ?? null, ...(m.data !== undefined && JSON.stringify(m.data).length < 800 ? { data: m.data } : {}) }
  run.events.push(e)
  try { appendFileSync(join(OUT, 'events.jsonl'), JSON.stringify({ run: run.n, ...e }) + '\n') } catch {}
}

// ---- analysis: metrics and the moments worth looking at ---------------------------------------------------------------------------
const C = Object.fromEntries(COLS.map((c, i) => [c, i]))
function analyse(r) {
  const rows = r.rows
  const m = { run: r.n, profile: r.profile, secs: r1(rows.length ? rows[rows.length - 1][0] : 0, 0), samples: rows.length, start: r.start, route: r.routes }
  const inc = [] // { t, kind, why }
  let dist = 0, engT = 0, vSum = 0, vN = 0, vMax = 0, hardBrakes = 0, maxALat = 0, maxDecel = 0, stuckT = 0, stuckSince = null
  const aLats = []
  const rev = [] // steering sign reversals at speed
  let lastSign = 0, lastAmpT = -9
  for (let i = 1; i < rows.length; i++) {
    const a = rows[i - 1], b = rows[i]
    const dt = b[C.t] - a[C.t]
    if (dt <= 0 || dt > 1) continue
    dist += Math.hypot(b[C.x] - a[C.x], b[C.y] - a[C.y])
    if (b[C.eng]) { engT += dt; vSum += b[C.v] || 0; vN++ }
    vMax = Math.max(vMax, b[C.v] || 0)
    if (b[C.aLat] != null && b[C.v] > 5) { aLats.push(Math.abs(b[C.aLat])); maxALat = Math.max(maxALat, Math.abs(b[C.aLat])) }
    if (b[C.aLon] != null && b[C.aLon] < -4 && b[C.v] > 3 && b[C.brk] > 0.2) { hardBrakes++; maxDecel = Math.max(maxDecel, -b[C.aLon]); inc.push({ t: b[C.t], kind: 'hardBrake', why: `decel ${r1(-b[C.aLon])} m/s2 at ${r1(b[C.v], 1)} m/s ctl=${b[C.ctl]} lead=${b[C.lead]}` }) }
    if (b[C.dmg] != null && a[C.dmg] != null && b[C.dmg] - a[C.dmg] > 300) inc.push({ t: b[C.t], kind: 'damage', why: `damage +${Math.round(b[C.dmg] - a[C.dmg])} at ${r1(b[C.v], 1)} m/s` })
    // steering reversals: sign changes of the steering input past a dead zone while moving fast = swerving
    const s = b[C.steer]
    if (s != null && b[C.v] > 10 && Math.abs(s) > 0.05) {
      const sg = s > 0 ? 1 : -1
      if (lastSign && sg !== lastSign) rev.push(b[C.t])
      lastSign = sg; lastAmpT = b[C.t]
    } else if (b[C.t] - lastAmpT > 3) lastSign = 0
    // stuck: engaged, nothing explains it, not moving
    if (b[C.eng] && (b[C.v] || 0) < 0.4 && !b[C.ctl] && !b[C.lead] && b[C.act] !== 'maneuver') { if (stuckSince == null) stuckSince = b[C.t]; else if (b[C.t] - stuckSince > 20 && b[C.t] - stuckSince < 20.2) inc.push({ t: b[C.t], kind: 'stuck', why: 'engaged, not moving for 20 s, no light/stop/car ahead' }) }
    else if (stuckSince != null) { stuckT += Math.max(0, b[C.t] - stuckSince); stuckSince = null }
  }
  // swerve bursts: 4 or more reversals inside 6 s
  let lastBurst = -99
  for (let i = 3; i < rev.length; i++) if (rev[i] - rev[i - 3] < 6 && rev[i] - lastBurst > 10) { lastBurst = rev[i]; inc.push({ t: rev[i], kind: 'swerve', why: `4 steering reversals in ${r1(rev[i] - rev[i - 3], 1)} s at speed` }) }
  const km = dist / 1000
  aLats.sort((x, y) => x - y)
  Object.assign(m, {
    km: r1(km, 2), engagedPct: rows.length ? Math.min(100, r1((100 * engT) / Math.max(1, m.secs), 0)) : 0, avgSpeedMph: vN ? r1((vSum / vN) * 2.237, 1) : null, maxSpeedMph: r1(vMax * 2.237, 0),
    hardBrakes, maxDecel: r1(maxDecel, 1), aLatP95: r1(aLats[Math.floor(aLats.length * 0.95)] ?? 0), aLatMax: r1(maxALat), steerReversalsPerKm: km > 0.2 ? r1(rev.length / km, 1) : null, stuckSec: r1(stuckT, 0),
  })
  // events
  const by = {}
  for (const e of r.events) by[e.kind] = (by[e.kind] || 0) + 1
  m.events = by
  const dis = r.events.filter((e) => e.kind === 'disengage')
  m.disengages = dis.map((e) => ({ t: e.t, why: e.data?.reason ?? e.detail ?? null, detail: e.data?.detail ?? null }))
  for (const e of r.events) {
    if (e.kind === 'disengage') inc.push({ t: e.t, kind: 'disengage', why: `${e.data?.reason ?? ''} ${e.data?.detail ?? e.detail ?? ''}`.trim() })
    else if (['error', 'unresponsive', 'pullOver', 'collision', 'stuck', 'phantomBrake', 'lowConfidence', 'missedDest', 'uturn'].includes(e.kind)) inc.push({ t: e.t, kind: e.kind, why: `${e.detail ?? ''} ${e.data ? JSON.stringify(e.data).slice(0, 160) : ''}`.trim() })
  }
  // lane changes: was the signal on for 2 s before it started, and the right way?
  let lc = 0, lcNoSig = 0
  for (const e of r.events.filter((x) => x.kind === 'laneChange')) {
    lc++
    const dir = e.data?.dir ?? e.detail
    const win = rows.filter((x) => x[C.t] >= e.t - 2.2 && x[C.t] <= e.t)
    const sig = win.filter((x) => x[C.sig] === dir).length
    if (!win.length || sig < win.length * 0.6) { lcNoSig++; inc.push({ t: e.t, kind: 'laneChangeNoSignal', why: `lane change ${dir} (${e.data?.reason ?? ''}), signal on for ${sig}/${win.length} samples before` }) }
  }
  m.laneChanges = lc; m.laneChangesNoSignal = lcNoSig
  // signals on with no lane change or turn about to happen
  let sigNoReason = 0, sigRun = 0
  for (const x of rows) {
    if ((x[C.sig] === 'left' || x[C.sig] === 'right') && x[C.eng] && !x[C.laneChg]) sigRun++
    else { if (sigRun > 40) sigNoReason++; sigRun = 0 }
  }
  m.longSignalsNoLaneChange = sigNoReason
  return { m, inc }
}
function windows(r, inc) {
  inc.sort((a, b) => a.t - b.t)
  const merged = []
  for (const i of inc) {
    const last = merged[merged.length - 1]
    if (last && i.t - last.to < 3) { last.to = Math.max(last.to, i.t + 6); last.why.push(`${i.kind}: ${i.why}`) }
    else merged.push({ from: Math.max(0, i.t - 6), to: i.t + 6, at: i.t, why: [`${i.kind}: ${i.why}`] })
  }
  return merged.slice(0, 40).map((w) => ({ run: r.n, at: w.at, why: w.why, cols: COLS, rows: r.rows.filter((x) => x[0] >= w.from && x[0] <= w.to), events: r.events.filter((e) => e.t >= w.from && e.t <= w.to) }))
}

// ---- upload (same token and repo as the black box) ------------------------------------------------------------------------------
function uploadCfg() {
  let token = (ENV.TESLA_GH_TOKEN || '').trim()
  try { if (!token) token = readFileSync(join(HOME, 'github-token.txt'), 'utf8').trim() } catch {}
  let cfg = {}
  try { cfg = JSON.parse(readFileSync(join(HOME, 'blackbox-upload.json'), 'utf8')) } catch {}
  return { token, repo: cfg.repo || 'MRRDO/tesla-ui-atv', branch: cfg.branch || '' }
}
const shas = new Map()
async function upload(rel, buf) {
  if (ENV.SOAK_NO_UPLOAD) return 'skipped (SOAK_NO_UPLOAD)'
  const c = uploadCfg()
  if (!c.token) return 'no GitHub token on this PC'
  const path = `soak/${stamp}/${rel}`
  try {
    const body = { message: `soak ${stamp} ${rel}`, content: Buffer.from(buf).toString('base64') }
    if (c.branch) body.branch = c.branch
    if (shas.has(path)) body.sha = shas.get(path)
    const r = await fetch(`https://api.github.com/repos/${c.repo}/contents/${path}`, { method: 'PUT', headers: { authorization: `Bearer ${c.token}`, accept: 'application/vnd.github+json', 'user-agent': 'tesla-soak' }, body: JSON.stringify(body), signal: AbortSignal.timeout(30000) })
    const j = await r.json().catch(() => ({}))
    if (!r.ok) return `GitHub ${r.status}: ${String(j.message || '').slice(0, 80)}`
    if (j.content?.sha) shas.set(path, j.content.sha)
    return 'uploaded'
  } catch (e) { return `not uploaded: ${e.message}`.slice(0, 120) }
}

// ---- the loop -----------------------------------------------------------------------------------------------------------------
const all = { runs: [], incidents: [] }
function report(final) {
  const lines = []
  const R = all.runs
  const sum = (k) => R.reduce((a, r) => a + (r[k] || 0), 0)
  lines.push(`# FSD soak ${stamp}${final ? '' : ' (so far)'}`, '', `${R.length} runs, ${r1(sum('km'), 1)} km, ${r1(sum('secs') / 3600, 2)} h recorded. Profiles cycle standard / chill / hurry / madmax. Samples are 10 Hz arrays (columns in each incident).`, '')
  lines.push('| run | profile | min | km | eng% | avg mph | disengages | hard brakes | swerve/km | aLat p95 | lane chg (no signal) | long signals no lane chg | stuck s |', '|---|---|---|---|---|---|---|---|---|---|---|---|---|')
  for (const r of R) lines.push(`| ${r.run} | ${r.profile} | ${r1(r.secs / 60, 1)} | ${r.km} | ${r.engagedPct} | ${r.avgSpeedMph} | ${r.disengages.length} | ${r.hardBrakes} | ${r.steerReversalsPerKm ?? '-'} | ${r.aLatP95} | ${r.laneChanges} (${r.laneChangesNoSignal}) | ${r.longSignalsNoLaneChange} | ${r.stuckSec} |`)
  const kinds = {}
  for (const i of all.incidents) for (const w of i.why) { const k = w.split(':')[0]; kinds[k] = (kinds[k] || 0) + 1 }
  lines.push('', '## Incident counts', '', Object.entries(kinds).sort((a, b) => b[1] - a[1]).map(([k, n]) => `- ${k}: ${n}`).join('\n') || '- none', '')
  const dis = {}
  for (const r of R) for (const d of r.disengages) { const k = `${d.why}${d.detail ? ' / ' + String(d.detail).slice(0, 60) : ''}`; dis[k] = (dis[k] || 0) + 1 }
  lines.push('## Why FSD switched off', '', Object.entries(dis).sort((a, b) => b[1] - a[1]).map(([k, n]) => `- ${n}x ${k}`).join('\n') || '- never', '')
  lines.push('## First 12 incidents (full detail in incidents.json)', '')
  for (const i of all.incidents.slice(0, 12)) lines.push(`- run ${i.run} t=${i.at}s: ${i.why.join(' | ')}`)
  lines.push('', 'Files: summary.json (all metrics), incidents.json (6 s before and after each incident, 10 Hz), events.jsonl (every event), runs/*.jsonl.gz (all samples).')
  return lines.join('\n')
}

async function waitForCar(maxSec = 600) {
  for (let i = 0; i < maxSec && !stopping(); i++) {
    if (!ws) await connect()
    if (ws && st?.pos && !map) { send({ t: 'requestMap' }); await sleep(1500) }
    if (ws && st?.pos && map?.nodes) return true
    await sleep(1000)
  }
  return false
}

function roadPoint() {
  // a stretch of real road: both ends at least 3 m wide, heading along the link
  const nodes = new Map(map.nodes.map((n) => [n.id, n]))
  const links = map.links.filter((l) => { const a = nodes.get(l.a), b = nodes.get(l.b); return a && b && a.radius >= 3 && b.radius >= 3 && Math.hypot(a.pos[0] - b.pos[0], a.pos[1] - b.pos[1]) > 25 })
  for (let k = 0; k < 40; k++) {
    const l = pick(links.length ? links : map.links)
    const a = nodes.get(l.a), b = nodes.get(l.b)
    if (!a || !b) continue
    const t = 0.3 + Math.random() * 0.4
    let dx = b.pos[0] - a.pos[0], dy = b.pos[1] - a.pos[1]
    const d = Math.hypot(dx, dy) || 1
    dx /= d; dy /= d
    if (!l.oneWay && Math.random() < 0.5) { dx = -dx; dy = -dy }
    return { pos: [a.pos[0] + (b.pos[0] - a.pos[0]) * t, a.pos[1] + (b.pos[1] - a.pos[1]) * t, a.pos[2] + 0.4], h: [dx, dy] }
  }
  return null
}
function destination(from) {
  // a road node 1.5 to 4 km away (drive on past it: arrival 'Drive On', so nothing parks)
  const ok = map.nodes.filter((n) => { const d = Math.hypot(n.pos[0] - from[0], n.pos[1] - from[1]); return n.radius >= 3 && d > 1500 && d < 4000 })
  const n = ok.length ? pick(ok) : pick(map.nodes)
  return [n.pos[0], n.pos[1], n.pos[2]]
}

async function oneRun(n) {
  const profile = ['standard', 'chill', 'hurry', 'madmax'][(n - 1) % 4]
  const pt = roadPoint()
  if (!pt) throw new Error('no road point')
  send({ t: 'autopilot', mode: 'off' }); await sleep(800)
  send({ t: 'gear', gear: 'P' }); await sleep(600)
  send({ t: 'teleport', x: pt.pos[0], y: pt.pos[1], z: pt.pos[2], hx: pt.h[0], hy: pt.h[1], repair: true }); await sleep(3500)
  if (st && st.dir[0] * pt.h[0] + st.dir[1] * pt.h[1] < 0) { send({ t: 'teleport', x: pt.pos[0], y: pt.pos[1], z: pt.pos[2], hx: pt.h[0], hy: pt.h[1], flip: true }); await sleep(3000) }
  send({ t: 'settings', nags: false, nagMode: 'off' })
  run = { n, profile, t0: Date.now() / 1000, rows: [], events: [], start: pt.pos.map((x) => r1(x, 0)), routes: 0 }
  const newRoute = () => { const to = destination(st.pos); send({ t: 'navigate', to, arrival: 'Drive On' }); run.routes++ }
  newRoute()
  send({ t: 'gear', gear: 'D' }); await sleep(400)
  send({ t: 'autopilot', mode: 'fsd', profile })
  log(`run ${n} (${profile}): started at ${run.start}`)
  const t0 = Date.now()
  let lastMove = Date.now(), lastPos = st?.pos, reRoute = Date.now()
  while (Date.now() - t0 < RUN_SEC * 1000 && !stopping() && Date.now() - T_START < MAX_SEC * 1000) {
    await sleep(500)
    if (!ws || !st) { log('lost the relay: waiting'); if (!(await waitForCar(300))) break; continue }
    // FSD off (disengaged on its own or crashed): turn it on again, like a person would, after a short pause; count it (the events say why)
    if (!st.autopilot?.engaged && Date.now() - t0 > 6000) {
      await sleep(2500)
      if (!st.autopilot?.engaged) { run.restarts = (run.restarts || 0) + 1; if (run.restarts > 25) break; newRoute(); send({ t: 'gear', gear: 'D' }); send({ t: 'autopilot', mode: 'fsd', profile }) }
    }
    if (st.autopilot?.remaining != null && st.autopilot.remaining < 120 && Date.now() - reRoute > 15000) { newRoute(); reRoute = Date.now() }
    if (lastPos && Math.hypot(st.pos[0] - lastPos[0], st.pos[1] - lastPos[1]) > 1) { lastPos = [...st.pos]; lastMove = Date.now() }
    else if (Date.now() - lastMove > 90000) { log('no movement for 90 s: ending this run'); break }
    if ((st.damage ?? 0) > 20000) { log('car is wrecked: ending this run'); break }
  }
  send({ t: 'autopilot', mode: 'off' })
  const r = run
  run = null
  const { m, inc } = analyse(r)
  m.restarts = r.restarts || 0
  const w = windows(r, inc)
  all.runs.push(m); all.incidents.push(...w)
  const gz = gzipSync(Buffer.from(r.rows.map((x) => JSON.stringify(x)).join('\n')))
  writeFileSync(join(OUT, 'runs', `run-${String(n).padStart(2, '0')}.jsonl.gz`), gz)
  writeFileSync(join(OUT, 'summary.json'), JSON.stringify({ stamp, cols: COLS, runs: all.runs }, null, 1))
  writeFileSync(join(OUT, 'incidents.json'), JSON.stringify(all.incidents))
  writeFileSync(join(OUT, 'final.md'), report(false))
  log(`run ${n} done: ${m.km} km, ${m.disengages.length} disengages, ${m.hardBrakes} hard brakes, ${m.laneChangesNoSignal} lane changes without signal, ${w.length} incidents`)
  const ups = await Promise.all([upload('final.md', readFileSync(join(OUT, 'final.md'))), upload('summary.json', readFileSync(join(OUT, 'summary.json'))), upload('incidents.json', readFileSync(join(OUT, 'incidents.json'))), upload(`runs/run-${String(n).padStart(2, '0')}.jsonl.gz`, gz)])
  log('upload:', [...new Set(ups)].join(', '))
}

const T_START = Date.now()
if (process.platform === 'win32' && !ENV.SOAK_NO_KEEPAWAKE) {
  // keep Windows (and the screen) from sleeping while the soak runs; ends by itself when this process ends
  try {
    const { spawn } = await import('node:child_process')
    const ps = `Add-Type -Name K -Namespace W -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'; [W.K]::SetThreadExecutionState(0x80000003) | Out-Null; Wait-Process -Id ${process.pid} -ErrorAction SilentlyContinue`
    spawn('powershell.exe', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps], { stdio: 'ignore', windowsHide: true }).unref()
  } catch {}
}
log(`soak ${stamp}: ${RUN_SEC} s per run, up to ${MAX_SEC / 3600} h, output ${OUT}`)
let n = 0
while (!stopping() && Date.now() - T_START < MAX_SEC * 1000) {
  if (!(await waitForCar())) { log('no car/map from the relay: giving up'); break }
  try { await oneRun(++n) } catch (e) { log('run failed:', e.message); run = null; await sleep(5000) }
}
writeFileSync(join(OUT, 'final.md'), report(true))
log('finished:', await upload('final.md', readFileSync(join(OUT, 'final.md'))))
try { ws?.close() } catch {}
process.exit(0)
