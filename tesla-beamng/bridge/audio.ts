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
    return { ok: true as const, devices: await listDevices(run), ...cfg }
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

/**
 * Equalizer APO config for the music output only (the game's output stays flat). Equalizer APO is a
 * separate install; it reads this file. `bands` are dB per frequency (the app's EQ).
 */
export function apoConfig(deviceName: string, bands: Record<string, number>) {
  const lines = Object.entries(bands)
    .filter(([, g]) => Number.isFinite(g) && Math.abs(g) > 0.05)
    .map(([hz, g]) => `Filter: ON PK Fc ${Number(hz)} Hz Gain ${g.toFixed(1)} dB Q 1.0`)
  return `Device: ${deviceName.replace(/[\r\n]/g, ' ')}\n${lines.join('\n') || 'Preamp: 0 dB'}\n`
}

export const audioConfigExists = () => existsSync(file)
