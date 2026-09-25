// React/zustand store for the bridge.
//
//   import { useBeamNG, connectBeamNG } from '.../bridge/app'
//   connectBeamNG()                                   // once, e.g. when "Vehicle source: BeamNG" is picked
//   const mph = useBeamNG((s) => (s.state?.speed ?? 0) * MPS_TO_MPH)
//   const fsd = useBeamNG((s) => s.state?.autopilot.engaged)
//   useBeamNG.getState().client?.autopilot('fsd')
//
// The store re-renders at the game's 20 Hz, so select only what a component needs.

import { create } from 'zustand'
import { BeamNGClient, bridgeUrl, type ClientSnapshot } from './client.ts'
import type { Event } from '../protocol.ts'

const URL_KEY = 'beamng.bridgeUrl'

export type BeamNGStore = ClientSnapshot & {
  client: BeamNGClient | null
  url: string | null
  /** Last 50 events (disengage, arrived, errors...), newest first. */
  events: Event[]
}

export const useBeamNG = create<BeamNGStore>(() => ({
  status: 'closed', game: false, state: null, map: null, traffic: [], route: null, minimap: null, lastEvent: null,
  buttonMap: null, lastButton: null,
  client: null, url: null, events: [],
}))

function savedUrl(): string | undefined {
  try { return localStorage.getItem(URL_KEY) ?? undefined } catch { return undefined }
}

/**
 * Connect to the relay. With no URL: the page's `?bridge=`, then the relay's own host (app served
 * from `/app/`), then the last URL used. Saves the URL for next time. Returns the client.
 */
export function connectBeamNG(url?: string): BeamNGClient | null {
  const target = url ?? bridgeUrl(savedUrl())
  if (!target) return null
  const cur = useBeamNG.getState()
  if (cur.client && cur.url === target) return cur.client
  cur.client?.close()
  try { localStorage.setItem(URL_KEY, target) } catch { /* private mode */ }
  const client = new BeamNGClient(target)
  client.subscribe((msg) => {
    const patch: Partial<BeamNGStore> = { ...client.snapshot }
    if (msg.t === 'event') patch.events = [msg, ...useBeamNG.getState().events].slice(0, 50)
    useBeamNG.setState(patch)
  })
  useBeamNG.setState({ ...client.snapshot, client, url: target })
  return client
}

export function disconnectBeamNG() {
  useBeamNG.getState().client?.close()
  useBeamNG.setState({ client: null, status: 'closed', game: false, state: null })
}

/** Shorthand for the client (null until connected). */
export const bridge = () => useBeamNG.getState().client
