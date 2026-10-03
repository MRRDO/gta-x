import { audioStatus, chooseOutputs, apoConfig, testTone, type Run } from './audio.ts'
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
ok(apoConfig('TV', { '60': 3, '1000': 0 }) === 'Device: TV\nFilter: ON PK Fc 60 Hz Gain 3.0 dB Q 1.0\n', 'apo config skips flat bands')
console.log(`${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0)
