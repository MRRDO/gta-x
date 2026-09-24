// Messages between the BeamNG mod, the relay and the app.
// Every message is { t: '<type>', ...fields }. Game <-> relay: one JSON object
// per line over TCP (127.0.0.1:8766). Relay <-> app: one JSON object per
// WebSocket message (ws://<pc>:8765/?token=...).
//
// World coordinates are BeamNG meters: x east, y north, z up.

export type Vec3 = [number, number, number]
export type Gear = 'P' | 'R' | 'N' | 'D'
export type Profile = 'sloth' | 'chill' | 'standard' | 'hurry' | 'madmax'
export type AutopilotMode = 'off' | 'autosteer' | 'fsd'
export type SignalDir = 'left' | 'right' | 'hazard' | null
export type Arrival = 'Parking Lot' | 'Street' | 'Driveway' | 'Parking Garage' | 'Curbside'
export type DisengageReason = 'steer' | 'brake' | 'throttle' | 'arrived' | 'error' | 'app'

// ---------------------------------------------------------------------------
// Game -> app
// ---------------------------------------------------------------------------

/** 20 Hz, the player's car. */
export type State = {
  t: 'state'
  time: number // game seconds
  vehicle: { id: number; name: string; model: string }
  pos: Vec3
  dir: Vec3 // unit forward vector
  speed: number // m/s (wheel speed)
  gear: Gear | string // 'M3' etc. for manual gears
  throttle: number // 0..1 actual input (player or autopilot)
  brake: number // 0..1
  parkingbrake: number // 0..1
  steering: number // -1..1 input
  steeringWheelDeg: number // steering wheel angle, + = turned right (clockwise)
  signal: SignalDir
  lights: { low: boolean; high: boolean; fog: boolean }
  doors: Record<string, boolean> // true = open. FL/FR/RL/RR/trunk/hood/frunk when recognised, else the car's own names
  battery: number | null // 0..1 for EVs
  fuel: number | null // 0..1 otherwise
  autopilot: AutopilotState
}

export type AutopilotState = {
  engaged: boolean
  mode: AutopilotMode
  profile: Profile
  targetSpeed: number // m/s
  speedLimit: number | null // m/s at the car, from the road graph (or a class default)
  leadGap: number | null // m to the car ahead in our lane
  control: { kind: 'stop' | 'signal'; dist: number; red: boolean } | null
  nextTurn: { dir: 'left' | 'right' | 'straight'; dist: number; road: string } | null
  remaining: number | null // m to destination
  lastDisengage: { reason: DisengageReason; time: number } | null
  /** Learned steering calibration, for debugging. */
  steerSign?: number
  steerGain?: number
}

/** 5 Hz: other cars within 600 m. */
export type Traffic = {
  t: 'traffic'
  cars: { id: number; pos: Vec3; dir: Vec3; speed: number; w: number; l: number }[]
}

/** On connect and on level/vehicle change. */
export type MapInfo = {
  t: 'map'
  level: string
  bounds: { min: [number, number]; max: [number, number] }
  /** Relay URL of the level's minimap image, once the relay has it. */
  minimap?: string
  /** Where the minimap sits in the world, from the level's info.json (best effort). */
  minimapInfo?: { file: string; offset?: number[]; size?: number[] }
  nodes: { id: string; pos: Vec3; radius: number }[] // radius = half road width
  links: { a: string; b: string; oneWay: boolean; speedLimit: number | null; drivability: number; name?: string }[] // one-way links run a -> b
  signals: { id: string; pos: Vec3; kind: 'stop' | 'signal' }[]
  parking: { pos: Vec3; dir: Vec3 }[]
}

/** The planned route (after `navigate`, or the road ahead when FSD has no destination). Empty points = no route. */
export type Route = { t: 'route'; points: Vec3[]; length: number; openEnded?: boolean; arrival?: 'parking' | 'curb' | 'point' }

/** Relay -> app when the minimap image arrives. */
export type Minimap = { t: 'minimap'; url: string; offset?: number[]; size?: number[] }

export type Event = {
  t: 'event'
  kind: 'disengage' | 'engaged' | 'arrived' | 'vehicleChanged' | 'levelLoaded' | 'error'
  detail?: string
}

/** Relay status. `game` is whether the mod is connected. */
export type Bridge = { t: 'bridge'; game: 'connected' | 'disconnected'; version?: string }

export type Hello = { t: 'hello'; protocol: number; game: string; version: string }
export type Pong = { t: 'pong'; time: number }
/** Answer to `debug`: what this BeamNG version exposes (for fixing API mismatches). */
export type Debug = { t: 'debug'; ge: Record<string, unknown>; vehicle?: Record<string, unknown> }

export type GameMessage = State | Traffic | MapInfo | Route | Minimap | Event | Bridge | Hello | Pong | Debug

// ---------------------------------------------------------------------------
// App -> game
// ---------------------------------------------------------------------------

export type Command =
  | { t: 'gear'; gear: Gear }
  | { t: 'lights'; low?: boolean; high?: boolean; fog?: boolean }
  | { t: 'signal'; dir: SignalDir }
  | { t: 'horn'; on: boolean }
  | { t: 'door'; door: string; open: boolean }
  | { t: 'autopilot'; mode: AutopilotMode; profile?: Profile }
  | { t: 'navigate'; to: Vec3 | { node: string }; stops?: Vec3[]; arrival?: Arrival }
  | { t: 'cancelRoute' }
  | { t: 'throttleOverride'; value: number } // -1..1, resend at >= 5 Hz while held; lapses after 0.5 s
  | { t: 'requestMap' }
  | { t: 'requestMinimap' }
  | { t: 'debug' }
  | { t: 'ping' }

export const COMMAND_TYPES: ReadonlySet<Command['t']> = new Set([
  'gear', 'lights', 'signal', 'horn', 'door', 'autopilot', 'navigate', 'cancelRoute',
  'throttleOverride', 'requestMap', 'requestMinimap', 'debug', 'ping',
])

export const MPH = 0.44704
