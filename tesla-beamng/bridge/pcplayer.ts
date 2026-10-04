// Apple Music playing on the PC (OptiPlex), driven from the iPad. The iPad keeps the music screen; this
// runs music.apple.com in its own Chrome window (sign in there once yourself) and controls it over Chrome's
// DevTools port with MusicKit, which the Apple Music web player already has. The sound goes to the music
// output you picked (Chrome setSinkId), and Equalizer APO / device volume (audio.ts) shape it at system level.
// EXPERIMENTAL and UNTESTED: written from MusicKit JS / DevTools docs without Apple Music or Windows here.
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { WebSocket } from 'ws'

const PORT = Number(process.env.TESLA_CHROME_PORT ?? 9223)
const CANDIDATES = [
  process.env.CHROME_BIN,
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
  '/usr/bin/google-chrome',
]

type Send = (expr: string) => Promise<unknown>

const HIDDEN = { left: -32000, top: -32000 }

export const chromePath = () => CANDIDATES.find((p): p is string => !!p && existsSync(p))
export const pcPlayerAvailable = () => !!chromePath()

async function targets(): Promise<{ type: string; url: string; webSocketDebuggerUrl: string }[]> {
  const r = await fetch(`http://127.0.0.1:${PORT}/json`, { signal: AbortSignal.timeout(2000) })
  return (await r.json()) as never
}

/** Start the player window if it isn't running (own profile folder, so it keeps your Apple sign-in). */
async function ensureWindow(profileDir: string) {
  try {
    if ((await targets()).some((t) => t.type === 'page' && t.url.includes('music.apple.com'))) return
  } catch {
    const bin = chromePath()
    if (!bin) throw new Error('Chrome not found (set CHROME_BIN)')
    // An app window (no tab strip, no address bar) parked off screen: it plays in the background and is never a window you
    // alt-tab into. Sign in once with showWindow(true) (the app's "Open the player to sign in" button), then hide it again.
    // The flags keep Chrome from slowing a window nobody can see.
    spawn(bin, [
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${join(profileDir, 'chrome-player')}`,
      '--autoplay-policy=no-user-gesture-required',
      '--use-fake-ui-for-media-stream',
      '--app=https://music.apple.com/',
      `--window-position=${HIDDEN.left},${HIDDEN.top}`,
      '--window-size=520,380',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding',
      '--disable-backgrounding-occluded-windows',
      '--disable-features=CalculateNativeWinOcclusion',
    ], {
      detached: true,
      stdio: 'ignore',
    }).unref()
  }
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 500))
    try {
      if ((await targets()).some((t) => t.type === 'page' && t.url.includes('music.apple.com'))) return
    } catch { /* still starting */ }
  }
  throw new Error('the player window did not open')
}

async function withPage<T>(profileDir: string, f: (send: Send) => Promise<T>): Promise<T> {
  await ensureWindow(profileDir)
  const page = (await targets()).find((t) => t.type === 'page' && t.url.includes('music.apple.com'))
  if (!page) throw new Error('no Apple Music page')
  const ws = new WebSocket(page.webSocketDebuggerUrl)
  await new Promise<void>((res, rej) => { ws.once('open', () => res()); ws.once('error', rej) })
  let id = 0
  const pending = new Map<number, (v: unknown) => void>()
  ws.on('message', (d) => {
    const m = JSON.parse(String(d)) as { id?: number; result?: { result?: { value?: unknown }; exceptionDetails?: { text?: string; exception?: { description?: string } } } }
    if (m.id && pending.has(m.id)) pending.get(m.id)!(m.result)
  })
  const send: Send = (expression) =>
    new Promise((res, rej) => {
      const n = ++id
      const t = setTimeout(() => rej(new Error('player did not answer')), 10000)
      pending.set(n, (r) => {
        clearTimeout(t)
        const ex = (r as { exceptionDetails?: { exception?: { description?: string }; text?: string } })?.exceptionDetails
        if (ex) return rej(new Error((ex.exception?.description ?? ex.text ?? 'error').split('\n')[0]))
        res((r as { result?: { value?: unknown } })?.result?.value)
      })
      ws.send(JSON.stringify({ id: n, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }))
    })
  try {
    return await f(send)
  } finally {
    ws.close()
  }
}

const MK = `(()=>{const m=window.MusicKit&&MusicKit.getInstance();if(!m)throw new Error('Apple Music is not signed in / not loaded yet');return m})()`

/** Send the player's sound to the output device whose name contains `name` (the music output). */
const SINK = (name: string) => `(async()=>{
  const want=${JSON.stringify(name.toLowerCase())};
  let ds=await navigator.mediaDevices.enumerateDevices();
  if(ds.every(d=>!d.label)){try{(await navigator.mediaDevices.getUserMedia({audio:true})).getTracks().forEach(t=>t.stop())}catch(e){}ds=await navigator.mediaDevices.enumerateDevices()}
  const d=ds.find(d=>d.kind==='audiooutput'&&d.label.toLowerCase().includes(want));
  if(!d)throw new Error('Chrome can not see an output called '+want);
  for(const el of document.querySelectorAll('audio,video'))await el.setSinkId(d.deviceId);
  return d.label})()`

export async function play(appleId: string, profileDir: string, sinkName?: string) {
  if (!/^\d{3,20}$/.test(appleId)) throw new Error('bad song id')
  return withPage(profileDir, async (send) => {
    await send(`(async()=>{const m=${MK};await m.setQueue({song:'${appleId}'});await m.play()})()`)
    if (sinkName) await send(SINK(sinkName)).catch((e) => { throw new Error('playing, but not on the music output: ' + (e as Error).message) })
    return true
  })
}

export async function control(action: 'play' | 'pause' | 'next' | 'prev' | 'seek', value: number | undefined, profileDir: string) {
  const call = { play: 'm.play()', pause: 'm.pause()', next: 'm.skipToNextItem()', prev: 'm.skipToPreviousItem()', seek: `m.seekToTime(${Number(value) || 0})` }[action]
  if (!call) throw new Error('bad action')
  return withPage(profileDir, async (send) => {
    await send(`(async()=>{const m=${MK};await ${call}})()`)
    return true
  })
}

export async function status(profileDir: string) {
  return withPage(profileDir, async (send) => {
    const v = (await send(`(()=>{const m=${MK};return {title:(m.nowPlayingItem&&m.nowPlayingItem.title)||'',playing:m.isPlaying,position:m.currentPlaybackTime,duration:m.currentPlaybackDuration,ended:m.playbackState===10||m.playbackState===5}})()`)) as {
      title?: string
      playing: boolean
      position: number
      duration: number
      ended: boolean
    }
    return v
  })
}

/** Bring the player window on screen (to sign in) or put it away off screen again. Browser-level DevTools calls, no tab switching. */
export async function showWindow(show: boolean, profileDir: string) {
  await ensureWindow(profileDir)
  const info = (await (await fetch(`http://127.0.0.1:${PORT}/json/version`, { signal: AbortSignal.timeout(2000) })).json()) as { webSocketDebuggerUrl: string }
  const page = (await targets()).find((t) => t.type === 'page' && t.url.includes('music.apple.com')) as { id?: string } | undefined
  if (!page?.id) throw new Error('no Apple Music page')
  const ws = new WebSocket(info.webSocketDebuggerUrl)
  await new Promise<void>((res, rej) => { ws.once('open', () => res()); ws.once('error', rej) })
  let id = 0
  const call = (method: string, params: unknown) =>
    new Promise<Record<string, unknown>>((res, rej) => {
      const n = ++id
      const t = setTimeout(() => rej(new Error('Chrome did not answer')), 5000)
      const on = (d: unknown) => {
        const m = JSON.parse(String(d)) as { id?: number; result?: Record<string, unknown>; error?: { message?: string } }
        if (m.id !== n) return
        clearTimeout(t)
        ws.off('message', on)
        m.error ? rej(new Error(m.error.message ?? 'Chrome error')) : res(m.result ?? {})
      }
      ws.on('message', on)
      ws.send(JSON.stringify({ id: n, method, params }))
    })
  try {
    const w = (await call('Browser.getWindowForTarget', { targetId: page.id })) as { windowId: number }
    await call('Browser.setWindowBounds', { windowId: w.windowId, bounds: show ? { left: 80, top: 60, width: 1100, height: 760, windowState: 'normal' } : { left: HIDDEN.left, top: HIDDEN.top, width: 520, height: 380, windowState: 'normal' } })
    return true
  } finally {
    ws.close()
  }
}
