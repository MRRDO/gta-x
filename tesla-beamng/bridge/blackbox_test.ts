import { BlackBox } from './blackbox.ts'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
let pass = 0, fail = 0
const ok = (c: unknown, m: string) => { if (c) pass++; else { fail++; console.log('FAIL', m) } }
const bb = new BlackBox(mkdtempSync(join(tmpdir(), 'bb-')))
const st = (i: number) => ({ t: 'state', time: i, speed: 10 + i, throttle: 0.2, brake: 0, steering: 0.1, steeringWheelDeg: 12.34, gear: 'D', signal: null, autopilot: { engaged: true, mode: 'fsd', leadGap: 25.55, control: { kind: 'stop', dist: 40.2, state: 'red' } }, pos: [1, 2, 3], fps: 59.9 })
for (let i = 0; i < 1500; i++) bb.push(st(i), 1_000_000 + i * 100) // 150 s at 10 Hz
bb.push({ t: 'event', kind: 'disengage', detail: 'x' }, 1_000_000 + 149_900)
ok(bb.samples.length <= 901 && bb.samples.length > 850, 'keeps about the last 90 s (' + bb.samples.length + ')')
ok(bb.samples[bb.samples.length - 1].wheelDeg === 12.3 && bb.samples[0].ctl === 'stop@40:red', 'wheel angle, pedals, road ahead are recorded')
bb.push(st(1), 1_000_000 + 149_950) // faster than 10 Hz: ignored
const n = bb.samples.length
bb.push(st(2), 1_000_000 + 149_960)
ok(bb.samples.length === n, 'samples closer than 100 ms are dropped')
const f = bb.mark('', 1_000_000 + 150_000)
bb.addNote(f, 'fsd almost crashed')
const j = JSON.parse(readFileSync(f, 'utf8'))
ok(j.note === 'fsd almost crashed' && j.samples.length === n && j.events.length === 1, 'the file has the samples, the events and the note')
// upload: no token -> says so and sends nothing; with a token -> PUT to the contents API, base64 body, remembers the sha for the note update
{
  const { uploadToGitHub } = await import('./blackbox.ts')
  const home = mkdtempSync(join(tmpdir(), 'bbhome-'))
  const none = await uploadToGitHub(f, home, (async () => { throw new Error('must not be called') }) as unknown as typeof fetch)
  ok(!none.ok && /no GitHub token/.test(none.status), 'no token: nothing is sent')
  process.env.TESLA_GH_TOKEN = 'x'
  const calls: { url: string; init: RequestInit }[] = []
  const fake = (async (url: string, init: RequestInit) => { calls.push({ url, init }); return { ok: true, status: 201, json: async () => ({ content: { sha: 'abc', html_url: 'u' } }) } }) as unknown as typeof fetch
  const up = await uploadToGitHub(f, home, fake)
  ok(up.ok && /contents\/blackbox\/mark-/.test(calls[0].url) && JSON.parse(String(calls[0].init.body)).content.length > 100, 'with a token: PUT of the file to blackbox/')
  await uploadToGitHub(f, home, fake)
  ok(JSON.parse(String(calls[1].init.body)).sha === 'abc', 'a second upload (the note) updates the same file')
  delete process.env.TESLA_GH_TOKEN
}
console.log(`${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0)
