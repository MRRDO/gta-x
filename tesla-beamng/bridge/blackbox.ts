// Black box: the last 90 s of what the car and the driver were doing, kept in memory, written to a file when you press the hotkey
// (Ctrl+Alt+B, see laptop/blackbox-hotkey.ps1) so that when FSD "almost crashed" there is a record: steering wheel angle, pedals, speed,
// FSD state, the road ahead (stop / signal / lead gap), and the events around it. A note can be added afterwards.
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const WINDOW_MS = 90_000
const MIN_GAP_MS = 100
const r = (v: unknown, d = 2) => (typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 10 ** d) / 10 ** d : null)

type Sample = { at: number; t: number | null; fsd: boolean; mode: string; v: number | null; thr: number | null; brk: number | null; str: number | null; wheelDeg: number | null; gear: string | null; sig: string | null; lead: number | null; ctl: string | null; lane: number | null; fps: number | null; pos: number[] | null; target: number | null }
type Ev = { at: number; kind: string; detail: string | null }

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
        pos: Array.isArray(msg.pos) ? msg.pos.map((x: number) => r(x, 1) as number) : null, target: r(a.targetSpeed),
      })
      while (this.samples.length && now - this.samples[0].at > WINDOW_MS) this.samples.shift()
    } else if (msg?.t === 'event' && typeof msg.kind === 'string') {
      this.events.push({ at: now, kind: msg.kind, detail: msg.detail ?? null })
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
