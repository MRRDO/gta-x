// Which sound card each thing plays on, for the OptiPlex: the game on the TV (HDMI), music on the back
// 3.5 mm jack. Windows only has one "default" device, so:
//   game  = the Windows default playback device (BeamNG follows it), set here
//   music = a device the PC music player picks itself (Chrome setSinkId), only remembered here
// Needs the PowerShell module AudioDeviceCmdlets (Install-Module AudioDeviceCmdlets). UNTESTED on real
// Windows: the PowerShell part has only been run against a fake exec in audio_test.ts.
import { execFile } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export type Device = { id: string; name: string; default: boolean }
export type AudioConfig = { game: string | null; music: string | null } // device ids
export type Run = (script: string) => Promise<string>

const here = dirname(fileURLToPath(import.meta.url))
const file = join(here, '.audio.json')

const psRun: Run = (script) =>
  new Promise((resolve, reject) => {
    if (process.platform !== 'win32') return reject(new Error('only on Windows'))
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { timeout: 15000 }, (err, out, errOut) =>
      err ? reject(new Error(String(errOut || err.message).trim().slice(0, 300))) : resolve(out),
    )
  })

export function loadConfig(path = file): AudioConfig {
  try {
    const j = JSON.parse(readFileSync(path, 'utf8'))
    return { game: typeof j.game === 'string' ? j.game : null, music: typeof j.music === 'string' ? j.music : null }
  } catch {
    return { game: null, music: null }
  }
}

export function saveConfig(c: AudioConfig, path = file) {
  writeFileSync(path, JSON.stringify(c))
}

/** Playback devices (not microphones). */
export async function listDevices(run: Run = psRun): Promise<Device[]> {
  const out = await run("Get-AudioDevice -List | Where-Object { $_.Type -eq 'Playback' } | ForEach-Object { '{0}|{1}|{2}' -f $_.ID, $_.Name, $_.Default }")
  return out
    .split(/\r?\n/)
    .map((l) => l.trim().split('|'))
    .filter((p) => p.length >= 3 && p[0])
    .map((p) => ({ id: p[0], name: p.slice(1, -1).join('|'), default: /^true$/i.test(p[p.length - 1]) }))
}

const safeId = (id: string) => /^[\w{}.\-]+$/.test(id)

/** Make a device the Windows default playback device (what the game plays on). */
export async function setGameOutput(id: string, run: Run = psRun) {
  if (!safeId(id)) throw new Error('bad device id')
  await run(`Set-AudioDevice -ID '${id}' | Out-Null`)
}

/** What the app shows: the devices, which ones are chosen, and whether this PC can do it. */
export async function audioStatus(run: Run = psRun, path = file) {
  const cfg = loadConfig(path)
  try {
    const devices = await listDevices(run)
    const volumes: Record<string, number> = {}
    for (const id of [...new Set([cfg.game, cfg.music].filter((x): x is string => !!x))]) {
      try { const v = await getVolume(id, run); if (Number.isFinite(v)) volumes[id] = v } catch { /* a device that went away */ }
    }
    return { ok: true as const, devices, volumes, ...cfg }
  } catch (e) {
    return { ok: false as const, devices: [] as Device[], error: (e as Error).message, ...cfg }
  }
}

export async function chooseOutputs(body: { game?: string | null; music?: string | null }, run: Run = psRun, path = file) {
  const cfg = loadConfig(path)
  if (body.music !== undefined) cfg.music = body.music
  if (body.game !== undefined) {
    cfg.game = body.game
    if (body.game) await setGameOutput(body.game, run)
  }
  saveConfig(cfg, path)
  return cfg
}

/** A short beep on one device so you can hear which output is which (plays through the default device, so we switch, beep, switch back). */
export async function testTone(id: string, run: Run = psRun) {
  if (!safeId(id)) throw new Error('bad device id')
  await run(
    `$old = (Get-AudioDevice -Playback).ID; Set-AudioDevice -ID '${id}' | Out-Null; [console]::beep(660,350); [console]::beep(880,350); Set-AudioDevice -ID $old | Out-Null`,
  )
}

export type Band = { freq: number; type: 'lowshelf' | 'peaking' | 'highshelf'; gain: number }
const APO_TYPE = { lowshelf: 'LSC', peaking: 'PK', highshelf: 'HSC' } as const

/**
 * Equalizer APO config for the music output only (the game's output stays flat). Equalizer APO is a
 * separate install that filters everything a device plays (so it also works on Apple Music in Chrome);
 * it reads this file via an `Include: tesla-eq.txt` line in its config.txt (the OptiPlex kit adds it).
 */
// Estimated peak of the summed filters (RBJ biquads at 48 kHz, 20 Hz to 20 kHz). Boosts add up where bands overlap, so without
// a matching preamp loud bass passes 0 dBFS, clips, and the sound card's limiter ducks the whole signal ("gets quieter when the bass hits").
function biquadDb(b: Band, f: number): number {
  const fs = 48000, A = Math.pow(10, b.gain / 40), w0 = (2 * Math.PI * b.freq) / fs, cs = Math.cos(w0), sn = Math.sin(w0)
  let b0: number, b1: number, b2: number, a0: number, a1: number, a2: number
  if (b.type === 'peaking') {
    const al = sn / 2 // Q 1.0, as written to the file
    b0 = 1 + al * A; b1 = -2 * cs; b2 = 1 - al * A; a0 = 1 + al / A; a1 = -2 * cs; a2 = 1 - al / A
  } else {
    const al = (sn / 2) * Math.sqrt(2), s2 = 2 * Math.sqrt(A) * al
    if (b.type === 'lowshelf') {
      b0 = A * (A + 1 - (A - 1) * cs + s2); b1 = 2 * A * (A - 1 - (A + 1) * cs); b2 = A * (A + 1 - (A - 1) * cs - s2)
      a0 = A + 1 + (A - 1) * cs + s2; a1 = -2 * (A - 1 + (A + 1) * cs); a2 = A + 1 + (A - 1) * cs - s2
    } else {
      b0 = A * (A + 1 + (A - 1) * cs + s2); b1 = -2 * A * (A - 1 + (A + 1) * cs); b2 = A * (A + 1 + (A - 1) * cs - s2)
      a0 = A + 1 - (A - 1) * cs + s2; a1 = 2 * (A - 1 - (A + 1) * cs); a2 = A + 1 - (A - 1) * cs - s2
    }
  }
  const w = (2 * Math.PI * f) / fs, c1 = Math.cos(w), c2 = Math.cos(2 * w)
  const num = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * c1 + 2 * b0 * b2 * c2
  const den = a0 * a0 + a1 * a1 + a2 * a2 + 2 * (a0 * a1 + a1 * a2) * c1 + 2 * a0 * a2 * c2
  return 10 * Math.log10(num / den)
}
export function peakGainDb(bands: Band[]): number {
  let peak = 0
  for (let i = 0; i <= 240; i++) {
    const f = 20 * Math.pow(1000, i / 240)
    peak = Math.max(peak, bands.reduce((sum, b) => sum + biquadDb(b, f), 0))
  }
  return peak
}

const usableBands = (bands: Band[]) =>
  bands
    .filter((b) => Number.isFinite(b.gain) && Number.isFinite(b.freq) && Math.abs(b.gain) > 0.05 && b.type in APO_TYPE)
    .map((b) => ({ ...b, gain: Math.max(-12, Math.min(12, b.gain)) }))

/** The preamp (a cut, in dB, as a positive number) that keeps the whole chain's peak at about -0.5 dB. */
export function headroomDb(bands: Band[], existingPreampDb = 0) {
  const used = usableBands(bands)
  if (!used.length) return 0
  return Math.min(20, Math.ceil(Math.max(0, peakGainDb(used) + 0.5 - Math.max(0, existingPreampDb)) * 10) / 10)
}

/**
 * No "Device:" line on purpose: Equalizer APO only processes the devices ticked in its installer (the music output), and
 * the Windows-style name with brackets ("Speakers / Headphones (Realtek Audio)") never matches APO's own device naming,
 * so the curve was silently not applied.
 */
export function apoConfig(_deviceName: string, bands: Band[], existingPreampDb = 0) {
  const used = usableBands(bands)
  const lines = used.map((b) => `Filter: ON ${APO_TYPE[b.type]} Fc ${Math.round(b.freq)} Hz Gain ${b.gain.toFixed(1)} dB${b.type === 'peaking' ? ' Q 1.0' : ''}`)
  const h = headroomDb(bands, existingPreampDb)
  return `Preamp: ${h > 0 ? '-' : ''}${h.toFixed(1)} dB\n${lines.join('\n')}\n`
}

export const apoDir = () => process.env.APO_CONFIG_DIR || 'C:\\Program Files\\EqualizerAPO\\config'

// a cut Equalizer APO's own config.txt already applies (Preamp: -x dB), which counts towards our headroom
function existingPreamp(dir: string) {
  try {
    const m = /^\s*Preamp:\s*(-?[0-9.]+)\s*dB/im.exec(readFileSync(join(dir, 'config.txt'), 'utf8'))
    if (m && Number(m[1]) < 0) return -Number(m[1])
  } catch { /* no config.txt yet */ }
  return 0
}

/** Write the music output's EQ where Equalizer APO reads it. */
export function writeEq(bands: Band[], musicName: string, dir = apoDir()) {
  if (!existsSync(dir)) throw new Error('Equalizer APO is not installed (no config folder)')
  writeFileSync(join(dir, 'tesla-eq.txt'), apoConfig(musicName, bands, existingPreamp(dir)))
}

/** What the app shows: the bands in tesla-eq.txt, the preamp written with them and the estimated peak of the chain. */
export function readEq(dir = apoDir()) {
  if (!existsSync(dir)) return { ok: true as const, apoInstalled: false, bands: [] as Band[], preampDb: 0, peakDb: 0 }
  let txt = ''
  try { txt = readFileSync(join(dir, 'tesla-eq.txt'), 'utf8') } catch { /* nothing written yet */ }
  const back: Record<string, Band['type']> = { LSC: 'lowshelf', PK: 'peaking', HSC: 'highshelf' }
  const bands: Band[] = []
  for (const m of txt.matchAll(/^Filter:\s*ON\s+(LSC|PK|HSC)\s+Fc\s+([0-9.]+)\s*Hz\s+Gain\s+(-?[0-9.]+)\s*dB/gim)) {
    bands.push({ freq: Number(m[2]), type: back[m[1].toUpperCase()], gain: Number(m[3]) })
  }
  const pm = /^\s*Preamp:\s*(-?[0-9.]+)\s*dB/im.exec(txt)
  const preampDb = pm ? Number(pm[1]) : 0
  const extra = existingPreamp(dir)
  // peak after our boosts, preamp and any cut already in config.txt: close to or under -0.5 dB means no clipping
  const peakDb = Math.round((peakGainDb(bands) + preampDb - extra) * 10) / 10
  return { ok: true as const, apoInstalled: true, bands, preampDb, peakDb }
}

// ---- volume per output, ducking ----
// Per device (not just the default one), straight from Windows' core audio, so the music output's volume
// and the game output's volume are independent. UNTESTED on Windows.
const VOL_PS = `
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume { int R1(); int R2(); int R3(); int SetMasterVolumeLevel(float l, ref Guid c); int SetMasterVolumeLevelScalar(float l, ref Guid c); int GetMasterVolumeLevel(out float l); int GetMasterVolumeLevelScalar(out float l); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int R1(); int R2(); int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice d); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
public static class DevVol {
  static IAudioEndpointVolume Ep(string id) {
    var e = (IMMDeviceEnumerator)(new MMDeviceEnumerator()); IMMDevice d; e.GetDevice(id, out d);
    var iid = typeof(IAudioEndpointVolume).GUID; object o; d.Activate(ref iid, 23, IntPtr.Zero, out o); return (IAudioEndpointVolume)o; }
  public static float Get(string id) { float v; Ep(id).GetMasterVolumeLevelScalar(out v); return v; }
  public static void Set(string id, float v) { var g = Guid.Empty; Ep(id).SetMasterVolumeLevelScalar(v, ref g); }
}
'@
`

export async function getVolume(id: string, run: Run = psRun): Promise<number> {
  if (!safeId(id)) throw new Error('bad device id')
  return Number((await run(`${VOL_PS}\n[DevVol]::Get('${id}')`)).trim())
}

export async function setVolume(id: string, value: number, run: Run = psRun) {
  if (!safeId(id)) throw new Error('bad device id')
  const v = Math.max(0, Math.min(1, Number(value)))
  if (!Number.isFinite(v)) throw new Error('bad volume')
  await run(`${VOL_PS}\n[DevVol]::Set('${id}', ${v.toFixed(3)})`)
}

// Lower the game's and the music's output while the driver is talking to the assistant, then put them back.
// Failsafe: puts them back by itself after 30 s even if the app never says to.
let ducked: Record<string, number> | null = null
let duckTimer: ReturnType<typeof setTimeout> | undefined

export async function duck(on: boolean, factor = 0.3, run: Run = psRun, path = file) {
  clearTimeout(duckTimer)
  if (on) {
    if (ducked) return
    const cfg = loadConfig(path)
    const ids = [...new Set([cfg.game, cfg.music].filter((x): x is string => !!x))]
    ducked = {}
    for (const id of ids) {
      try {
        const v = await getVolume(id, run)
        ducked[id] = v
        await setVolume(id, v * factor, run)
      } catch { /* a device that can't be read stays as it is */ }
    }
    duckTimer = setTimeout(() => void duck(false, factor, run, path), 30000)
    duckTimer.unref?.()
  } else if (ducked) {
    const was = ducked
    ducked = null
    for (const [id, v] of Object.entries(was)) await setVolume(id, v, run).catch(() => {})
  }
}

export const audioConfigExists = () => existsSync(file)
