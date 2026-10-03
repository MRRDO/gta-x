import { audioStatus, chooseOutputs, apoConfig, testTone, setVolume, duck, writeEq, type Run } from './audio.ts'
import { readFileSync, existsSync } from 'node:fs'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

let pass = 0, fail = 0
const ok = (c: unknown, m: string) => { if (c) pass++; else { fail++; console.log('FAIL', m) } }
const dir = mkdtempSync(join(tmpdir(), 'aud-')); const path = join(dir, 'a.json')
const calls: string[] = []
const run: Run = async (s) => { calls.push(s); return s.includes('List') ? 'a1|Speakers (Realtek)|False\nb2|TV (HDMI)|True\n' : '' }

const st = await audioStatus(run, path)
ok(st.ok && st.devices.length === 2 && st.devices[1].default && st.devices[1].name === 'TV (HDMI)', 'lists playback devices')
const cfg = await chooseOutputs({ game: 'b2', music: 'a1' }, run, path)
ok(cfg.game === 'b2' && cfg.music === 'a1', 'saves both choices')
ok(calls.some((c) => c.includes("Set-AudioDevice -ID 'b2'")), 'game output becomes the Windows default')
ok(!calls.some((c) => c.includes("-ID 'a1'")), 'music output is not made the default')
ok((await audioStatus(run, path)).music === 'a1', 'choices persist')
let bad = false; try { await chooseOutputs({ game: "x'; rm -rf /" }, run, path) } catch { bad = true }
ok(bad, 'refuses a device id that is not an id')
let bad2 = false; try { await testTone("x' ;", run) } catch { bad2 = true }
ok(bad2, 'test tone refuses odd ids')
const failing: Run = async () => { throw new Error('only on Windows') }
const off = await audioStatus(failing, path)
ok(!off.ok && /Windows/.test(off.error), 'reports when not on Windows')
ok(apoConfig('TV', [{ freq: 80, type: 'lowshelf', gain: 3 }, { freq: 1000, type: 'peaking', gain: 0 }, { freq: 3500, type: 'peaking', gain: -2 }]) === 'Device: TV\nFilter: ON LSC Fc 80 Hz Gain 3.0 dB\nFilter: ON PK Fc 3500 Hz Gain -2.0 dB Q 1.0\n', 'apo config skips flat bands, shelves vs peaks')
const vols: Record<string, number> = { b2: 0.8, a1: 0.5 }
const vrun: Run = async (s) => {
  const id = /'([^']+)'/.exec(s.split('[DevVol]::')[1] ?? '')?.[1] ?? ''
  if (s.includes('[DevVol]::Get')) return String(vols[id])
  vols[id] = Number(/, ([\d.]+)\)/.exec(s)![1]); return ''
}
await setVolume('a1', 0.25, vrun)
ok(vols.a1 === 0.25, 'sets one device volume')
await duck(true, 0.5, vrun, path)
ok(Math.abs(vols.b2 - 0.4) < 1e-6 && Math.abs(vols.a1 - 0.125) < 1e-6, 'duck lowers both outputs')
await duck(false, 0.5, vrun, path)
ok(Math.abs(vols.b2 - 0.8) < 1e-6 && Math.abs(vols.a1 - 0.25) < 1e-6, 'unduck restores both')
writeEq([{ freq: 80, type: 'lowshelf', gain: 2 }], 'Speakers', dir)
ok(/Device: Speakers/.test(readFileSync(join(dir, 'tesla-eq.txt'), 'utf8')), 'writes the apo file')
let noApo = false; try { writeEq([], 'x', join(dir, 'nope')) } catch { noApo = true }
ok(noApo && !existsSync(join(dir, 'nope')), 'no write when Equalizer APO is missing')
console.log(`${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0)
