// Offline speech to text for the app's "talk to the car" button.
// The iPad records a few seconds of audio and POSTs it to /stt; this converts it with ffmpeg and reads it with
// whisper.cpp, all on this PC. Nothing is sent anywhere. Needs (set the paths if they are not on PATH):
//   WHISPER_BIN   whisper.cpp's CLI (whisper-cli.exe, or main.exe in older builds)
//   WHISPER_MODEL a ggml model, e.g. ggml-base.en.bin (about 150 MB; "tiny.en" is faster and a bit worse)
//   FFMPEG_BIN    ffmpeg (default: ffmpeg on PATH)
// With any of them missing it answers 501 and the app falls back to typing.
import { spawn } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const MAX_BYTES = 6 * 1024 * 1024

export function sttConfig() {
  return { whisper: process.env.WHISPER_BIN ?? '', model: process.env.WHISPER_MODEL ?? '', ffmpeg: process.env.FFMPEG_BIN ?? 'ffmpeg' }
}
export const sttAvailable = () => { const c = sttConfig(); return !!c.whisper && !!c.model && existsSync(c.model) }

function run(cmd: string, args: string[], timeoutMs: number): Promise<{ code: number; out: string; err: string }> {
  return new Promise((resolve) => {
    let out = '', err = ''
    const p = spawn(cmd, args, { windowsHide: true })
    const t = setTimeout(() => { try { p.kill() } catch { /* gone */ } }, timeoutMs)
    p.stdout.on('data', (d) => (out += d))
    p.stderr.on('data', (d) => (err += d))
    p.on('error', (e) => { clearTimeout(t); resolve({ code: -1, out, err: String(e) }) })
    p.on('close', (code) => { clearTimeout(t); resolve({ code: code ?? -1, out, err }) })
  })
}

/** Audio bytes in, text out. Throws an Error with a plain message the app can show. */
export async function transcribe(audio: Buffer, ext = 'm4a'): Promise<string> {
  if (!sttAvailable()) throw Object.assign(new Error('speech recognition is not installed on the PC (WHISPER_BIN / WHISPER_MODEL)'), { status: 501 })
  if (audio.length < 800) throw Object.assign(new Error('that recording was empty'), { status: 400 })
  if (audio.length > MAX_BYTES) throw Object.assign(new Error('that recording is too long'), { status: 413 })
  const c = sttConfig()
  const dir = mkdtempSync(join(tmpdir(), 'tesla-stt-'))
  try {
    const inp = join(dir, `in.${ext.replace(/[^a-z0-9]/gi, '') || 'm4a'}`)
    const wav = join(dir, 'in.wav')
    writeFileSync(inp, audio)
    const f = await run(c.ffmpeg, ['-y', '-i', inp, '-ar', '16000', '-ac', '1', '-t', '15', wav], 20000)
    if (f.code !== 0 || !existsSync(wav)) throw new Error('could not read the recording (is ffmpeg installed? FFMPEG_BIN)')
    const w = await run(c.whisper, ['-m', c.model, '-f', wav, '-nt', '-np', '-l', 'en'], 30000)
    if (w.code !== 0) throw new Error('whisper failed: ' + w.err.slice(0, 120))
    return w.out.replace(/\[[^\]]*\]/g, ' ').replace(/\s+/g, ' ').trim()
  } finally {
    try { rmSync(dir, { recursive: true, force: true }) } catch { /* temp */ }
  }
}
