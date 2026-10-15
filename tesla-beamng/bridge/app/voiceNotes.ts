// Voice notes from the wheel: press the "Tesla: voice note" button (bound in BeamNG's
// controls) and the iPad starts recording with its mic; press it again (or tap the UI's
// stop button, or wait 60 s) and the note goes to the relay, which saves it in
// bridge/feedback/ with what the car was doing, for a future update.
//
//   import { startVoiceNotes, useVoiceNote } from '.../bridge/app'
//   const stop = startVoiceNotes()                    // once, after connectBeamNG()
//   const rec = useVoiceNote((s) => s.recording)      // show a red mic badge
//   useVoiceNote.getState().toggle()                  // a UI button can start/stop it too
//
// Browser only (MediaRecorder + getUserMedia). The iPad asks for mic permission the
// first time; Safari needs the page on https or localhost, or a user tap to start (a
// wheel press can't count as one), so the first recording may need a tap in the app.

import { create } from 'zustand'
import { useBeamNG } from './useBeamNG.ts'

export type VoiceNoteState = {
  recording: boolean
  startedAt: number | null
  /** last problem (no mic, permission denied, upload failed) */
  error: string | null
  /** saved note names, newest first */
  saved: string[]
  toggle: () => void
}

const MAX_SEC = 60

let recorder: MediaRecorder | null = null
let chunks: Blob[] = []
let stream: MediaStream | null = null
let maxTimer: ReturnType<typeof setTimeout> | null = null
let starting = false // waiting on the mic permission prompt

function pickMime(): string | undefined {
  if (typeof MediaRecorder === 'undefined') return undefined
  for (const m of ['audio/mp4', 'audio/webm;codecs=opus', 'audio/webm', 'audio/ogg']) {
    if (MediaRecorder.isTypeSupported?.(m)) return m
  }
  return undefined
}

async function start() {
  const set = useVoiceNote.setState
  if (recorder || starting) return
  if (typeof navigator === 'undefined' || !navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
    set({ error: 'no microphone recording in this browser' })
    return
  }
  starting = true
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true })
  } catch (e) {
    set({ error: `mic: ${(e as Error).message ?? e}` })
    return
  } finally {
    starting = false
  }
  const mime = pickMime()
  recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined)
  chunks = []
  const startedAt = Date.now()
  recorder.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data) }
  recorder.onstop = async () => {
    const type = recorder?.mimeType || mime || 'audio/webm'
    stream?.getTracks().forEach((t) => t.stop())
    stream = null
    recorder = null
    if (maxTimer) clearTimeout(maxTimer)
    maxTimer = null
    set({ recording: false, startedAt: null })
    const blob = new Blob(chunks, { type })
    chunks = []
    const client = useBeamNG.getState().client
    if (!blob.size) return
    if (!client?.connected) { set({ error: 'not connected: note not saved' }); return }
    await client.voiceNote(blob, { durationSec: (Date.now() - startedAt) / 1000 })
  }
  recorder.start(1000)
  maxTimer = setTimeout(() => stop(), MAX_SEC * 1000)
  set({ recording: true, startedAt, error: null })
}

function stop() {
  if (recorder && recorder.state !== 'inactive') recorder.stop()
}

export const useVoiceNote = create<VoiceNoteState>(() => ({
  recording: false, startedAt: null, error: null, saved: [],
  toggle: () => { if (recorder) stop(); else void start() },
}))

/** Listen for the wheel button (game event `voiceNote`) and the relay's `voiceNoteSaved`. Returns an unsubscribe fn. */
export function startVoiceNotes(): () => void {
  let seen = useBeamNG.getState().events[0]
  return useBeamNG.subscribe((b) => {
    if (!b.events.length || b.events[0] === seen) return
    // everything newer than the last one we handled (several can land in one update)
    const cut = seen ? b.events.indexOf(seen) : -1
    const fresh = (cut >= 0 ? b.events.slice(0, cut) : b.events.slice(0, 1)).reverse()
    seen = b.events[0]
    for (const ev of fresh) {
      if (ev.kind === 'voiceNote') useVoiceNote.getState().toggle()
      else if (ev.kind === 'voiceNoteSaved' && ev.detail) useVoiceNote.setState((s) => ({ saved: [ev.detail!, ...s.saved].slice(0, 20) }))
    }
  })
}
