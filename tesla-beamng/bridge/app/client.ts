// BeamNG bridge client for the Tesla UI app (browser or Node 22+, no dependencies).
//
//   const bridge = new BeamNGClient(bridgeUrl())   // or new BeamNGClient('ws://192.168.1.20:8765/?token=ab12cd34')
//   bridge.subscribe((msg) => { if (msg.t === 'state') ... })
//   bridge.setGear('D'); bridge.autopilot('fsd', 'standard'); bridge.navigate([x, y, z])
//   bridge.autopilot('tacc')  (cruise only)  bridge.autopilot('autosteer')  bridge.autopilot('off')
//
// Reconnects by itself. Keeps the latest state/map/traffic/route so late subscribers can read them.

import type {
  ActionName, Arrival, AutopilotMode, ButtonMap, Command, Event, GameMessage, Gear, MapInfo, Minimap, Profile, Quirks, Route, SafetySettings, SignalDir, State,
  Traffic, Vec3,
} from '../protocol.ts'

export type ConnectionStatus = 'connecting' | 'open' | 'closed'

export type ClientSnapshot = {
  status: ConnectionStatus
  /** The relay is connected to the game (BeamNG running with the mod). */
  game: boolean
  gameVersion?: string
  state: State | null
  map: MapInfo | null
  traffic: Traffic['cars']
  route: Route | null
  minimap: Minimap | null
  lastEvent: Event | null
  /** wheel button -> action mapping (Settings > Wheel buttons) */
  buttonMap: ButtonMap | null
  /** last wheel button pressed, for "press a button" screens */
  lastButton: { button: number; at: number } | null
  /**
   * Backup camera while in R (null = hide it). `src` works as an <img src>; draw it flipped
   * horizontally when `mirrored` (backup cameras show a mirror image).
   */
  camera: { src: string; seq: number; width: number; height: number; mirrored: boolean; at: number } | null
}

type Listener = (msg: GameMessage | { t: 'status'; status: ConnectionStatus }) => void

/**
 * Bridge WebSocket URL for this page.
 * - `?bridge=ws://host:8765/?token=...` in the page URL wins (handy on the iPad).
 * - When the app is served by the relay (`npm run bridge -- --app dist`, page at http://<pc>:8765/app/),
 *   it's the same host, with the page's `?token=`.
 * - Otherwise `fallback` (e.g. a URL saved in the app's settings).
 */
export function bridgeUrl(fallback?: string): string | undefined {
  if (typeof location === 'undefined') return fallback
  const q = new URLSearchParams(location.search)
  const explicit = q.get('bridge')
  if (explicit) return explicit
  if (location.pathname.startsWith('/app')) {
    const token = q.get('token')
    return `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/${token ? `?token=${token}` : ''}`
  }
  return fallback
}

export class BeamNGClient {
  readonly url: string
  private ws: WebSocket | null = null
  private listeners = new Set<Listener>()
  private retryMs = 500
  private retryTimer: ReturnType<typeof setTimeout> | null = null
  private pingTimer: ReturnType<typeof setInterval> | null = null
  private lastMessageAt = 0
  private closedByUser = false
  private holdTimer: ReturnType<typeof setInterval> | null = null
  private dropLink: (() => void) | null = null

  snapshot: ClientSnapshot = {
    status: 'closed', game: false, state: null, map: null, traffic: [], route: null, minimap: null, lastEvent: null,
    buttonMap: null, lastButton: null, camera: null,
  }

  constructor(url: string, opts: { autoConnect?: boolean } = {}) {
    this.url = url
    if (opts.autoConnect !== false) this.connect()
  }

  connect() {
    this.closedByUser = false
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING)) return
    this.setStatus('connecting')
    let ws: WebSocket
    try {
      ws = new WebSocket(this.url)
    } catch {
      this.scheduleReconnect()
      return
    }
    this.ws = ws
    let done = false
    // Some WebSocket implementations (Node's) fire `error` without `close` when the
    // connect fails, and a half-open network can hang in CONNECTING: handle both.
    const fail = () => {
      if (done) return
      done = true
      clearTimeout(connectTimer)
      if (this.ws === ws) this.ws = null
      this.stopPing()
      try { ws.close() } catch { /* already closed */ }
      this.snapshot = { ...this.snapshot, game: false }
      this.setStatus('closed')
      if (!this.closedByUser) this.scheduleReconnect()
    }
    this.dropLink = fail
    const connectTimer = setTimeout(() => { if (ws.readyState !== WebSocket.OPEN) fail() }, 5000)
    ws.onopen = () => {
      clearTimeout(connectTimer)
      this.retryMs = 500
      this.lastMessageAt = Date.now()
      this.setStatus('open')
      this.startPing()
    }
    ws.onmessage = (e) => {
      this.lastMessageAt = Date.now()
      let msg: GameMessage
      try {
        msg = JSON.parse(typeof e.data === 'string' ? e.data : String(e.data))
      } catch {
        return
      }
      this.absorb(msg)
      for (const l of this.listeners) l(msg)
    }
    ws.onclose = fail
    ws.onerror = () => { if (ws.readyState !== WebSocket.OPEN) fail() }
  }

  close() {
    this.closedByUser = true
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.releaseThrottle()
    this.stopPing()
    this.ws?.close()
    this.ws = null
    this.setStatus('closed')
  }

  /** Every message from the game, plus `{ t: 'status' }` when the connection changes. Returns an unsubscribe fn. */
  subscribe(fn: Listener): () => void {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }

  get connected() {
    return this.snapshot.status === 'open' && this.snapshot.game
  }

  /** Send a raw command. Returns false when not connected. */
  send(cmd: Command): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false
    this.ws.send(JSON.stringify(cmd))
    return true
  }

  // ---------------------------------------------------------------- commands
  setGear(gear: Gear) { return this.send({ t: 'gear', gear }) }
  setLights(lights: { low?: boolean; high?: boolean; fog?: boolean }) { return this.send({ t: 'lights', ...lights }) }
  setSignal(dir: SignalDir) { return this.send({ t: 'signal', dir }) }
  horn(on: boolean) { return this.send({ t: 'horn', on }) }
  /** Door names come from `state.doors` (FL/FR/RL/RR/trunk/hood/frunk when the car has them). */
  setDoor(door: string, open: boolean) { return this.send({ t: 'door', door, open }) }
  autopilot(mode: AutopilotMode, profile?: Profile) { return this.send({ t: 'autopilot', mode, profile }) }
  setProfile(profile: Profile) {
    const a = this.snapshot.state?.autopilot
    return this.send({ t: 'autopilot', mode: a?.engaged ? a.mode : 'off', profile })
  }
  /** Destination in world meters (convert a map tap with lngLatToWorld). */
  navigate(to: Vec3 | { node: string }, opts: { stops?: Vec3[]; arrival?: Arrival } = {}) {
    return this.send({ t: 'navigate', to, ...opts })
  }
  cancelRoute() { return this.send({ t: 'cancelRoute' }) }
  /** Force-feedback wheel spring (G29): on/off and strength 0..1. */
  wheel(opts: { spring?: boolean; strength?: number }) { return this.send({ t: 'wheel', ...opts }) }
  /** FSD settings: quirks, active safety, speed offset (mph over the limit), TACC set speed (m/s), follow distance 1..7, auto lane changes, nags. */
  settings(opts: {
    quirks?: Partial<Quirks>; safety?: Partial<SafetySettings>; speedOffsetMph?: number | null; setSpeed?: number | null
    followDistance?: number | null; laneChanges?: boolean; nags?: boolean
  }) { return this.send({ t: 'settings', ...opts }) }
  /** The cabin camera's read on the driver. Send it 2-5 times a second while FSD is on; stale after 3 s. */
  attention(state: 'ok' | 'phone' | 'eyesOff' | 'unknown') { return this.send({ t: 'attention', state }) }
  /** "Hands on the wheel" for the nag (a button, for players without a wheel). */
  nudge() { return this.send({ t: 'nudge' }) }
  /** Dumb Summon: creep ~12 m forward/back at walking pace and stop. null stops it. */
  summon(dir: 'forward' | 'reverse' | null) { return this.send({ t: 'summon', dir }) }
  /** Back into the nearest free parking spot beside the car. */
  autopark() { return this.send({ t: 'autopark' }) }
  resetStrikes() { return this.send({ t: 'resetStrikes' }) }
  /** Upload a voice note (e.g. from MediaRecorder). The relay saves it with the car's state for later. */
  async voiceNote(audio: Blob, opts: { durationSec?: number; text?: string } = {}) {
    const bytes = new Uint8Array(await audio.arrayBuffer())
    let bin = ''
    for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return this.send({ t: 'voiceNote', audio: btoa(bin), mime: audio.type || 'application/octet-stream', ...opts })
  }
  /** Show the backup camera for 15 s without shifting to R (a preview button); false hides it. */
  showCamera(on: boolean) { return this.send({ t: 'camera', on }) }
  /** Do what a wheel button would (e.g. 'toggleFSD', 'speedUp'). */
  action(name: ActionName) { return this.send({ t: 'action', name }) }
  /** Settings > Wheel buttons: the next button pressed on the wheel gets `action` (null cancels). */
  learnButton(action: ActionName | null) { return this.send({ t: 'learnButton', action }) }
  /** Set or clear (null) the button for an action directly. */
  setButton(action: ActionName, button: number | null) { return this.send({ t: 'setButton', action, button }) }
  requestMap() { return this.send({ t: 'requestMap' }) }
  debug() { return this.send({ t: 'debug' }) }

  /**
   * Accelerator strip: -1 (full brake) .. 1 (full throttle). The game drops it after 0.5 s,
   * so this repeats it every 100 ms until `releaseThrottle()` (or a new value).
   * Positive values with FSD on make it go faster (it stays engaged); negative values disengage it.
   */
  holdThrottle(value: number | (() => number)) {
    this.releaseThrottle(false)
    const get = typeof value === 'function' ? value : () => value
    this.send({ t: 'throttleOverride', value: get() })
    this.holdTimer = setInterval(() => this.send({ t: 'throttleOverride', value: get() }), 100)
  }
  releaseThrottle(sendZero = true) {
    if (this.holdTimer) clearInterval(this.holdTimer)
    this.holdTimer = null
    if (sendZero) this.send({ t: 'throttleOverride', value: 0 })
  }

  // ---------------------------------------------------------------- internals
  private absorb(msg: GameMessage) {
    const s = this.snapshot
    switch (msg.t) {
      case 'bridge': this.snapshot = { ...s, game: msg.game === 'connected', gameVersion: msg.version ?? s.gameVersion }; break
      case 'hello': this.snapshot = { ...s, game: true, gameVersion: msg.version }; break
      case 'state': this.snapshot = { ...s, state: msg, game: true }; break
      case 'traffic': this.snapshot = { ...s, traffic: msg.cars }; break
      case 'map': this.snapshot = { ...s, map: msg }; break
      case 'route': this.snapshot = { ...s, route: msg.points.length ? msg : null }; break
      case 'minimap': this.snapshot = { ...s, minimap: msg }; break
      case 'event': this.snapshot = { ...s, lastEvent: msg }; break
      case 'buttonMap': this.snapshot = { ...s, buttonMap: msg }; break
      case 'camera':
        this.snapshot = {
          ...s,
          camera: msg.off || !msg.data ? null : {
            src: `data:${msg.mime ?? 'image/png'};base64,${msg.data}`, seq: msg.seq ?? 0, width: msg.width ?? 320,
            height: msg.height ?? 180, mirrored: msg.mirrored !== false, at: Date.now(),
          },
        }
        break
      case 'wheelButton': if (msg.down) this.snapshot = { ...s, lastButton: { button: msg.button, at: Date.now() } }; break
    }
  }

  private setStatus(status: ConnectionStatus) {
    if (this.snapshot.status === status) return
    this.snapshot = { ...this.snapshot, status }
    for (const l of this.listeners) l({ t: 'status', status })
  }

  private scheduleReconnect() {
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.retryTimer = setTimeout(() => this.connect(), this.retryMs)
    this.retryMs = Math.min(5000, this.retryMs * 2)
  }

  private startPing() {
    this.stopPing()
    this.pingTimer = setInterval(() => {
      // state arrives at 20 Hz while the game runs; ping keeps the link alive in menus
      if (Date.now() - this.lastMessageAt > 8000) { this.dropLink?.(); return }
      this.send({ t: 'ping' })
    }, 3000)
  }

  private stopPing() {
    if (this.pingTimer) clearInterval(this.pingTimer)
    this.pingTimer = null
  }
}
