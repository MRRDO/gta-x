import { chmodSync, writeFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseVoiceIntent, buildCommandPrompt } from './assistant.ts'
let ok = 0, bad = 0
const check = (n: string, c: boolean) => { c ? ok++ : (bad++, console.log('FAIL:', n)) }
check('navigate with a query', parseVoiceIntent('{"kind":"navigate","query":"gas station"}')?.query === 'gas station')
check('navigate without a query is rejected', parseVoiceIntent('{"kind":"navigate","query":""}') === null)
check('chatter around the JSON', parseVoiceIntent('ok {"kind":"park"} done')?.kind === 'park')
check('unknown intent name rejected', parseVoiceIntent('{"kind":"launchMissiles"}') === null)
check('emergency parses (the app still asks first)', parseVoiceIntent('{"kind":"emergency"}')?.kind === 'emergency')
check('say is kept and trimmed', parseVoiceIntent('{"kind":"unknown","say":"hey there"}')?.say === 'hey there')
check('tired is an intent', parseVoiceIntent('{"kind":"tired","say":"i got you"}')?.kind === 'tired')
check('prompt carries history + state', /Driver: hi/.test(buildCommandPrompt('x', [{ role: 'driver', text: 'hi' }], { driving: true })) && /moving/.test(buildCommandPrompt('x', [], { driving: true })))
check('prompt carries the phrase', buildCommandPrompt('take me home').includes('take me home'))

// speech: with fake ffmpeg + whisper scripts (unix only: skipped on Windows)
if (process.platform !== 'win32') {
  const dir = mkdtempSync(join(tmpdir(), 'stt-test-'))
  const ff = join(dir, 'ffmpeg'), wh = join(dir, 'whisper'), model = join(dir, 'm.bin')
  writeFileSync(ff, '#!/bin/sh\nfor last; do :; done\necho wav > "$last"\n'); chmodSync(ff, 0o755)
  writeFileSync(wh, '#!/bin/sh\necho " [00:00.000 --> 00:02.000]  Take me to downtown. "\n'); chmodSync(wh, 0o755)
  writeFileSync(model, 'x')
  process.env.WHISPER_BIN = wh; process.env.WHISPER_MODEL = model; process.env.FFMPEG_BIN = ff
  const { transcribe, sttAvailable } = await import('./stt.ts')
  check('available when configured', sttAvailable())
  check('transcribes through ffmpeg + whisper', (await transcribe(Buffer.alloc(2000, 1))) === 'Take me to downtown.')
  check('empty recording rejected', await transcribe(Buffer.alloc(10)).then(() => false, (e) => e.status === 400))
  check('huge recording rejected', await transcribe(Buffer.alloc(7 * 1024 * 1024)).then(() => false, (e) => e.status === 413))
  process.env.WHISPER_MODEL = join(dir, 'missing.bin')
  check('missing model -> 501', await transcribe(Buffer.alloc(2000, 1)).then(() => false, (e) => e.status === 501))
}
console.log(`${ok} passed, ${bad} failed`)
process.exit(bad ? 1 : 0)
