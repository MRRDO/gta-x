// Two-way sync between the game and the app's existing zustand stores, so the
// current UI (gauges, gear strip, door/light buttons, nav map) works in BeamNG
// mode without touching its components.
//
//   import { useVehicleStore } from '@/store'
//   import { useSimStore } from '@/sim/drive'
//   import { useNavStore } from '@/nav/store'
//   const stop = syncBeamNGToApp({ vehicle: useVehicleStore, sim: useSimStore, nav: useNavStore })
//
// Field names follow the handoff (src/store.ts, src/sim/drive.ts, src/nav/store.ts). If a
// store names something differently, change it in the MAP section below. Fields a store
// doesn't have are skipped.
//
// Game -> app: every state message (20 Hz) writes speed, gear, doors, lights, charge,
// position, heading, signal, FSD state... Stop the app's simulator (useDriveSim) while this
// runs, so it doesn't fight over the same fields.
// App -> game: when the UI changes gear, doors, frunk/trunk, headlights or fog lights in the
// store, the matching command goes to the game. The game's reply then confirms it (or puts
// it back if the car can't). The same goes for the FSD switch and speed profile (sim store)
// and the destination / stops (nav store): picking a place on the map routes the game car there.

import { useBeamNG } from './useBeamNG.ts'
import { MPS_TO_MPH, headingDeg, lngLatToWorld, originFor, routeCoords, worldToLatLon } from './geo.ts'
import type { Arrival, Profile, State, Vec3 } from '../protocol.ts'

type AnyState = Record<string, any>
export type StoreLike = {
  getState: () => AnyState
  setState: (partial: AnyState) => void
  subscribe: (listener: (state: AnyState, prev: AnyState) => void) => () => void
}

// ---------------------------------------------------------------- MAP (edit if the app's names differ)

function vehiclePatch(s: State, prev: AnyState): AnyState {
  const d = s.doors
  const gear = ['P', 'R', 'N', 'D'].includes(s.gear) ? s.gear : 'D' // manual gears ('M3') show as D
  const energy = s.battery ?? s.fuel
  const patch: AnyState = {
    gear,
    speedMph: s.speed * MPS_TO_MPH,
    doors: { ...(prev.doors ?? {}), FL: !!d.FL, FR: !!d.FR, RL: !!d.RL, RR: !!d.RR },
    frunkOpen: !!(d.frunk ?? d.hood),
    trunkOpen: !!d.trunk,
    toggles: { ...(prev.toggles ?? {}), headlightsOn: s.lights.low || s.lights.high, fogLights: s.lights.fog },
  }
  if (energy != null) patch.chargePercent = Math.round(energy * 100)
  return patch
}

// the sim store's FSD switch / profile / arrival choice, whichever of these names it uses
const FSD_KEYS = ['fsd', 'fsdEngaged', 'fsdOn', 'fsdActive', 'autopilotEngaged']
const PROFILE_KEYS = ['profile', 'fsdProfile', 'speedProfile']
const ARRIVAL_KEYS = ['arrivalPark', 'arrival']
const PROFILE_LABEL: Record<Profile, string> = { sloth: 'Sloth', chill: 'Chill', standard: 'Standard', hurry: 'Hurry', madmax: 'Mad Max' }
const ARRIVALS: Arrival[] = ['Parking Lot', 'Street', 'Driveway', 'Parking Garage', 'Curbside']

/** 'Mad Max' / 'madMax' / 'MADMAX' -> 'madmax' (null if it isn't a profile) */
export function toProfile(v: unknown): Profile | null {
  if (typeof v !== 'string') return null
  const k = v.toLowerCase().replace(/[\s_-]/g, '')
  return k in PROFILE_LABEL ? (k as Profile) : null
}
/** Write a profile back in the format the store already uses ('Standard' vs 'standard'). */
function profileLike(cur: unknown, p: Profile): string {
  return typeof cur === 'string' && Object.values(PROFILE_LABEL).includes(cur) ? PROFILE_LABEL[p] : p
}
function toArrival(v: unknown): Arrival | undefined {
  if (typeof v !== 'string') return undefined
  const k = v.toLowerCase().replace(/[\s_-]/g, '')
  return ARRIVALS.find((a) => a.toLowerCase().replace(/\s/g, '') === k)
}

/**
 * A place from the nav store as [lon, lat]. Accepts [lat, lon] (like `position`),
 * { lat, lon|lng }, { coords|lngLat|center: [lon, lat] }, { position: [lat, lon] }.
 */
export function placeLngLat(p: unknown): [number, number] | null {
  if (!p) return null
  const num = (a: unknown): a is [number, number] => Array.isArray(a) && a.length >= 2 && typeof a[0] === 'number' && typeof a[1] === 'number'
  if (num(p)) return [p[1], p[0]]
  if (typeof p !== 'object') return null
  const o = p as AnyState
  if (typeof o.lat === 'number' && typeof (o.lon ?? o.lng) === 'number') return [o.lon ?? o.lng, o.lat]
  for (const k of ['coords', 'lngLat', 'center', 'coordinates']) if (num(o[k])) return [o[k][0], o[k][1]]
  if (num(o.position)) return [o.position[1], o.position[0]]
  if (o.geometry && num(o.geometry.coordinates)) return [o.geometry.coordinates[0], o.geometry.coordinates[1]]
  return null
}

function simPatch(s: State, cur: AnyState): AnyState {
  const a = s.autopilot
  const patch: AnyState = {
    heading: headingDeg(s.dir),
    signal: s.signal === 'hazard' ? null : s.signal,
    control: a.control,
    lead: a.leadGap,
    autopilot: a,
  }
  const on = a.engaged && a.mode !== 'tacc'
  for (const k of FSD_KEYS) if (typeof cur[k] === 'boolean') patch[k] = on // never clobber a field that isn't the switch
  for (const k of PROFILE_KEYS) if (toProfile(cur[k])) patch[k] = profileLike(cur[k], a.profile)
  return patch
}

function navPatch(s: State, level?: string | null): AnyState {
  return { position: worldToLatLon(s.pos[0], s.pos[1], originFor(level)), heading: headingDeg(s.dir) }
}

// ---------------------------------------------------------------- sync

const HOLD_MS = 1200 // after a UI change, ignore the game's older value for this long

export function syncBeamNGToApp(stores: { vehicle?: StoreLike; sim?: StoreLike; nav?: StoreLike }): () => void {
  let applying = false
  const pending = new Map<string, { value: unknown; until: number }>()
  const client = () => useBeamNG.getState().client

  const only = (store: StoreLike, patch: AnyState) => {
    const cur = store.getState()
    const out: AnyState = {}
    for (const k of Object.keys(patch)) {
      if (!(k in cur)) continue
      const p = pending.get(k)
      if (p && Date.now() < p.until && JSON.stringify(p.value) !== JSON.stringify(patch[k])) continue
      out[k] = patch[k]
    }
    return out
  }

  const unsubs: (() => void)[] = []

  unsubs.push(useBeamNG.subscribe((b, prevB) => {
    const s = b.state
    if (s && s !== prevB.state) {
      applying = true
      try {
        if (stores.vehicle) stores.vehicle.setState(only(stores.vehicle, vehiclePatch(s, stores.vehicle.getState())))
        if (stores.sim) stores.sim.setState(only(stores.sim, simPatch(s, stores.sim.getState())))
        if (stores.nav) stores.nav.setState(only(stores.nav, navPatch(s, b.map?.level)))
      } finally {
        applying = false
      }
    }
    if (stores.nav && b.route !== prevB.route && 'route' in stores.nav.getState()) {
      const coords = routeCoords(b.route, originFor(b.map?.level))
      applying = true
      try { stores.nav.setState({ route: coords.length ? { ...(stores.nav.getState().route ?? {}), coords } : null }) } finally { applying = false }
    }
  }))

  if (stores.vehicle) {
    unsubs.push(stores.vehicle.subscribe((st, prev) => {
      if (applying) return
      const c = client()
      if (!c) return
      const hold = (k: string) => pending.set(k, { value: st[k], until: Date.now() + HOLD_MS })
      if (st.gear !== prev.gear && ['P', 'R', 'N', 'D'].includes(st.gear)) { hold('gear'); c.setGear(st.gear) }
      for (const door of ['FL', 'FR', 'RL', 'RR'] as const) {
        if (st.doors?.[door] !== prev.doors?.[door]) { hold('doors'); c.setDoor(door, !!st.doors[door]) }
      }
      if (st.frunkOpen !== prev.frunkOpen) {
        hold('frunkOpen')
        const doors = useBeamNG.getState().state?.doors ?? {}
        c.setDoor('frunk' in doors ? 'frunk' : 'hood', !!st.frunkOpen)
      }
      if (st.trunkOpen !== prev.trunkOpen) { hold('trunkOpen'); c.setDoor('trunk', !!st.trunkOpen) }
      const t = st.toggles ?? {}, pt = prev.toggles ?? {}
      if (t.headlightsOn !== pt.headlightsOn) { hold('toggles'); c.setLights({ low: !!t.headlightsOn, high: false }) }
      if (t.fogLights !== pt.fogLights) { hold('toggles'); c.setLights({ fog: !!t.fogLights }) }
    }))
  }

  if (stores.sim) {
    unsubs.push(stores.sim.subscribe((st, prev) => {
      if (applying) return
      const c = client()
      if (!c) return
      const hold = (k: string) => pending.set(k, { value: st[k], until: Date.now() + HOLD_MS })
      const profileKey = PROFILE_KEYS.find((k) => toProfile(st[k]))
      const profile = profileKey ? toProfile(st[profileKey]) ?? undefined : undefined
      const fsdKey = FSD_KEYS.find((k) => k in st && typeof st[k] === 'boolean' && st[k] !== prev[k])
      if (fsdKey) {
        hold(fsdKey)
        c.autopilot(st[fsdKey] ? 'fsd' : 'off', profile)
      } else if (profileKey && st[profileKey] !== prev[profileKey] && profile) {
        hold(profileKey)
        c.setProfile(profile)
      }
    }))
  }

  if (stores.nav) {
    const arrival = () => {
      const sim = stores.sim?.getState() ?? {}
      const k = ARRIVAL_KEYS.find((key) => toArrival(sim[key]))
      return k ? toArrival(sim[k]) : undefined
    }
    const world = (p: unknown): Vec3 | null => {
      const ll = placeLngLat(p)
      if (!ll) return null
      const b = useBeamNG.getState()
      return lngLatToWorld(ll[0], ll[1], originFor(b.map?.level), b.map)
    }
    unsubs.push(stores.nav.subscribe((st, prev) => {
      if (applying) return
      const c = client()
      if (!c) return
      if (st.destination === prev.destination && st.stops === prev.stops) return
      if (!st.destination) { if (prev.destination) c.cancelRoute(); return }
      const to = world(st.destination)
      if (!to) return
      const stops = (Array.isArray(st.stops) ? st.stops : []).map(world).filter((p: Vec3 | null): p is Vec3 => !!p)
      c.navigate(to, { stops, arrival: arrival() })
    }))
  }

  return () => unsubs.forEach((u) => u())
}
