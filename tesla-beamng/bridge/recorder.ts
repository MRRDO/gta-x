// Driving log for the "learn from Quentin" AI (docs/AI_COMPUTE_PLAN.md).
// Off by default. With `--record` (or TESLA_RECORD=1) the relay appends one JSON line per
// ~100 ms of the player's car (and one per event: takeovers, alerts...) to
//   ~/.tesla-beamng/logs/drive-YYYY-MM-DD.jsonl
// rl/features.py turns those lines into training data. Nothing leaves the PC; a day of driving
// is roughly 20-30 MB of text. No positions are sent anywhere: it is a local file.
import { mkdirSync, appendFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const DIR = join(homedir(), '.tesla-beamng', 'logs')
const MIN_GAP_MS = 100

let last = 0
let dayOpen = ''
let file = ''

function target(): string {
  const day = new Date().toISOString().slice(0, 10)
  if (day !== dayOpen) {
    mkdirSync(DIR, { recursive: true })
    dayOpen = day
    file = join(DIR, `drive-${day}.jsonl`)
  }
  return file
}

const r = (v: unknown, d = 3) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 10 ** d) / 10 ** d : null)

/** One compact line from a `state` message (the fields rl/features.py reads). */
export function stateLine(s: any): string {
  const a = s.autopilot ?? {}
  return JSON.stringify({
    k: 's',
    t: r(s.time, 2),
    fsd: !!a.engaged,
    mode: a.mode ?? 'off',
    prof: a.profile ?? null,
    v: r(s.speed, 2),
    lim: r(s.speedLimit ?? a.speedLimit, 1),
    gap: r(a.leadGap, 1),
    thr: r(s.throttle, 2),
    brk: r(s.brake, 2),
    str: r(s.steering, 3),
    pos: Array.isArray(s.pos) ? s.pos.map((x: number) => r(x, 1)) : null,
    dir: Array.isArray(s.dir) ? s.dir.map((x: number) => r(x, 3)) : null,
    ctl: a.control ? { k: a.control.kind, d: r(a.control.dist, 0), s: a.control.state ?? null } : null,
    lane: a.lane?.index ?? null,
    fps: r(s.fps, 0),
  })
}

export function record(msg: any, enabled: boolean): void {
  if (!enabled) return
  try {
    if (msg.t === 'state') {
      const now = Date.now()
      if (now - last < MIN_GAP_MS) return
      last = now
      appendFileSync(target(), stateLine(msg) + '\n')
    } else if (msg.t === 'event' && ['disengage', 'aeb', 'fcw', 'collisionEvasion', 'laneChange', 'brain', 'stuck', 'crash'].includes(msg.kind)) {
      appendFileSync(target(), JSON.stringify({ k: 'e', kind: msg.kind, detail: msg.detail ?? null, at: Date.now() }) + '\n')
    }
  } catch {
    /* a full disk must never stop the bridge */
  }
}
