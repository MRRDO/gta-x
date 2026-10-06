// Black box: the last 90 s of what the car and the driver were doing, kept in memory, written to a file when you press the hotkey
// (Ctrl+Alt+B, see laptop/blackbox-hotkey.ps1) so that when FSD "almost crashed" there is a record: steering wheel angle, pedals, speed,
// FSD state, the road ahead (stop / signal / lead gap), and the events around it. A note can be added afterwards.
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const WINDOW_MS = 90_000 // 90 s: covers the 45 s before the hotkey and the 45 s of FSD before that
const MIN_GAP_MS = 100
const r = (v: unknown, d = 2) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 10 ** d) / 10 ** d : null)

type Sample = { at: number; t: number | null; fsd: boolean; mode: string; v: number | null; thr: number | null; brk: number | null; str: number | null; wheelDeg: number | null; gear: string | null; sig: string | null; lead: number | null; ctl: string | null; lane: number | null; fps: number | null; pos: number[] | null; target: number | null; ai: string | null }
type Ev = { at: number; kind: string; detail: string | null; data?: unknown }

// What the planner is doing, as one short string: activity/phase, lane change, waiting, go-around, turn ahead, confidence, alert.
function aiNote(a: any): string | null {
  const p: string[] = []
  if (a.activity && a.activity !== 'drive') p.push(a.activity)
  if (a.phase && a.phase !== 'driving') p.push(`phase:${a.phase}`)
  if (a.maneuver) p.push(`maneuver:${a.maneuver.kind} ${a.maneuver.step}/${a.maneuver.total}`)
  if (a.lane?.changing) p.push(`lane ${a.lane.changing.dir}:${a.lane.changing.reason}:${a.lane.changing.phase}`)
  if (a.waitingFor) p.push(`waiting:${a.waitingFor}`)
  if (a.goAround) p.push('goAround')
  if (a.creeping) p.push('creeping')
  if (a.phantomBrake) p.push('phantomBrake')
  if (a.emergencyVehicle) p.push(`ev:${a.emergencyVehicle}`)
  if (a.nextTurn) p.push(`turn ${a.nextTurn.dir}@${r(a.nextTurn.dist, 0)}`)
  if (typeof a.confidence === 'number' && a.confidence < 0.8) p.push(`conf ${r(a.confidence)}`)
  if (a.alert?.kind) p.push(`alert:${a.alert.kind}`)
  if (a.lastDisengage && typeof a.lastDisengage.reason === 'string') p.push(`lastOff:${a.lastDisengage.reason}`)
  return p.length ? p.join(' | ') : null
}

export class BlackBox {
  samples: Sample[] = []
  events: Ev[] = []
  lastAt = 0
  dir: string
  constructor(dir = join(homedir(), '.tesla-beamng', 'blackbox')) {
    this.dir = dir
  }

  push(msg: any, now = Date.now()) {
    if (msg?.t === 'state') {
      if (now - this.lastAt < MIN_GAP_MS) return
      this.lastAt = now
      const a = msg.autopilot ?? {}
      this.samples.push({
        at: now, t: r(msg.time), fsd: !!a.engaged, mode: a.mode ?? 'off', v: r(msg.speed), thr: r(msg.throttle), brk: r(msg.brake), str: r(msg.steering, 3),
        wheelDeg: r(msg.steeringWheelDeg, 1), gear: typeof msg.gear === 'string' ? msg.gear : null, sig: msg.signal ?? null, lead: r(a.leadGap, 1),
        ctl: a.control ? `${a.control.kind}@${r(a.control.dist, 0)}${a.control.state ? ':' + a.control.state : ''}` : null, lane: a.lane?.index ?? null, fps: r(msg.fps, 0),
        pos: Array.isArray(msg.pos) ? msg.pos.map((x: number) => r(x, 1) as number) : null, target: r(a.targetSpeed), ai: aiNote(a),
      })
      while (this.samples.length && now - this.samples[0].at > WINDOW_MS) this.samples.shift()
    } else if (msg?.t === 'event' && typeof msg.kind === 'string') {
      this.events.push({ at: now, kind: msg.kind, detail: msg.detail ?? null, ...(msg.data !== undefined && JSON.stringify(msg.data).length < 600 ? { data: msg.data } : {}) }) // (data: parking error, spot, plan numbers...)
      while (this.events.length && now - this.events[0].at > WINDOW_MS) this.events.shift()
    }
  }

  /** Write the window to a file; returns its path. */
  mark(note = '', now = Date.now()): string {
    mkdirSync(this.dir, { recursive: true })
    const file = join(this.dir, `mark-${new Date(now).toISOString().replace(/[:.]/g, '-')}.json`)
    writeFileSync(file, JSON.stringify({ markedAt: new Date(now).toISOString(), note, seconds: WINDOW_MS / 1000, samples: this.samples, events: this.events }))
    return file
  }

  /** Add or replace the note of a file written by mark(). */
  addNote(file: string, note: string) {
    const j = JSON.parse(readFileSync(file, 'utf8'))
    j.note = String(note).slice(0, 500)
    writeFileSync(file, JSON.stringify(j))
  }
}

// ---- auto-upload to GitHub --------------------------------------------------------------------------------------------------
// So a black box can be read from anywhere (the cloud session) without anyone copying files around. Needs a GitHub token that you put on
// this PC yourself, in %USERPROFILE%\.tesla-beamng\github-token.txt (one line) or the TESLA_GH_TOKEN environment variable: a fine-grained
// token for ONE repository with "Contents: read and write". The repo and folder default to MRRDO/tesla-ui-atv and blackbox/ and can be
// changed in %USERPROFILE%\.tesla-beamng\blackbox-upload.json ({"repo": "owner/name", "dir": "blackbox", "branch": "main"}).
// Without a token nothing is sent; the file stays on this PC.
export type UploadResult = { ok: boolean; status: string; url?: string }
const shas = new Map<string, string>() // file name -> blob sha of what we uploaded, for the note update

export function uploadConfig(home = homedir()) {
  const dir = join(home, '.tesla-beamng')
  let token = (process.env.TESLA_GH_TOKEN ?? '').trim()
  try { if (!token) token = readFileSync(join(dir, 'github-token.txt'), 'utf8').trim() } catch { /* none */ }
  let cfg: { repo?: string; dir?: string; branch?: string } = {}
  try { if (existsSync(join(dir, 'blackbox-upload.json'))) cfg = JSON.parse(readFileSync(join(dir, 'blackbox-upload.json'), 'utf8')) } catch { /* bad json: defaults */ }
  return { token, repo: cfg.repo || 'MRRDO/tesla-ui-atv', dir: (cfg.dir || 'blackbox').replace(/^\/+|\/+$/g, ''), branch: cfg.branch || '' }
}

/** PUT one file into the repo (create, or update when we uploaded it before). Never throws. */
export async function uploadToGitHub(file: string, home = homedir(), fetchFn: typeof fetch = fetch): Promise<UploadResult> {
  try {
    const c = uploadConfig(home)
    if (!c.token) return { ok: false, status: 'not uploaded: no GitHub token on this PC (see docs/BLACKBOX.md)' }
    const name = file.split(/[\\/]/).pop()!
    const path = `${c.dir}/${name}`
    const body: Record<string, unknown> = {
      message: `black box ${name}`,
      content: Buffer.from(readFileSync(file)).toString('base64'),
    }
    if (c.branch) body.branch = c.branch
    const sha = shas.get(name)
    if (sha) body.sha = sha
    const r = await fetchFn(`https://api.github.com/repos/${c.repo}/contents/${path}`, {
      method: 'PUT',
      headers: { authorization: `Bearer ${c.token}`, accept: 'application/vnd.github+json', 'user-agent': 'tesla-beamng-bridge', 'x-github-api-version': '2022-11-28' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15000),
    })
    const j = (await r.json().catch(() => ({}))) as { content?: { sha?: string; html_url?: string }; message?: string }
    if (!r.ok) return { ok: false, status: `GitHub said ${r.status}: ${String(j.message ?? '').slice(0, 120)}` }
    if (j.content?.sha) shas.set(name, j.content.sha)
    return { ok: true, status: 'uploaded', url: j.content?.html_url }
  } catch (e) {
    return { ok: false, status: `not uploaded: ${(e as Error).message}`.slice(0, 160) }
  }
}
