// Messages between the BeamNG mod, the relay and the app.
// Every message is { t: '<type>', ...fields }. Game <-> relay: one JSON object
// per line over TCP (127.0.0.1:8766). Relay <-> app: one JSON object per
// WebSocket message (ws://<pc>:8765/?token=...).
//
// World coordinates are BeamNG meters: x east, y north, z up.

export type Vec3 = [number, number, number]
export type Gear = 'P' | 'R' | 'N' | 'D'
export type Profile = 'sloth' | 'chill' | 'standard' | 'hurry' | 'madmax'
/** fsd: drives everything · autosteer: steers + cruise (Tesla Autosteer) · tacc: cruise only, you steer */
export type AutopilotMode = 'off' | 'autosteer' | 'fsd' | 'tacc'
export type SignalDir = 'left' | 'right' | 'hazard' | null
export type Arrival = 'Parking Lot' | 'Street' | 'Driveway' | 'Parking Garage' | 'Curbside'
export type DisengageReason = 'steer' | 'brake' | 'throttle' | 'arrived' | 'error' | 'app' | 'attention' | 'summon' | 'switch'

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
  /** Force-feedback wheel (G29 etc.) spring that turns the physical wheel while the autopilot drives. */
  wheel?: WheelState
  /** Active safety, on whether or not FSD drives. */
  safety?: SafetyState
}

export type SafetyState = {
  fcw: boolean // forward collision warning (beep + red car on screen)
  aeb: boolean // automatic emergency braking right now
  blindLeft: boolean // car in the left blind spot (red light in the mirror)
  blindRight: boolean
  laneDeparture: boolean // lane departure avoidance is steering you back
  ttc: number | null // seconds to a predicted collision
}

export type NagState = {
  level: 0 | 1 | 2 | 3 // 1 "Pay attention to the road" (blue flash), 2 beeping, 3 "Take over immediately" (red)
  reason: 'phone' | 'eyesOff' | 'hands' | null
  strikes: number
  maxStrikes: number // 5
  lockedOut: boolean // FSD unavailable for the rest of the drive
}

export type WheelState = {
  /** active = driving the wheel now; available = FFB wheel found; helper = the external wheel helper drives it; no wheel / unavailable / off / disabled otherwise */
  status: 'active' | 'available' | 'no wheel' | 'unavailable' | 'off' | 'disabled' | 'helper' | 'unknown'
  reason?: string
  strength: number // 0..1 of the wheel's max force
  pos: number // physical wheel, raw axis -1..1
  target: number // where the spring pulls it
  force: number // -1..1 of max
  ratio: number // steering input per raw wheel unit (learned)
  calibrated: boolean // motor direction confirmed (first turn of a session proves it)
}

export type AutopilotState = {
  engaged: boolean
  mode: AutopilotMode
  profile: Profile
  targetSpeed: number // m/s
  speedLimit: number | null // m/s at the car, from the road graph (or a class default)
  leadGap: number | null // m to the car ahead in our lane
  control: { kind: 'stop' | 'signal'; dist: number; red: boolean; state?: 'red' | 'yellow' | 'green' | null } | null
  nextTurn: { dir: 'left' | 'right' | 'straight'; dist: number; road: string } | null
  remaining: number | null // m to destination
  lastDisengage: { reason: DisengageReason; time: number } | null
  /** The driver is pressing the accelerator (pedal or the app's strip): FSD stays on and goes faster, no braking. */
  accelOverride: boolean
  /** drive | maneuver (backing out, 3-point turn, back-in parking) | summon */
  activity?: 'drive' | 'maneuver' | 'summon'
  setSpeed?: number | null // m/s, TACC / Autosteer
  lane?: { index: number; count: number; changing?: { dir: 'left' | 'right'; reason: 'route' | 'pass' | 'merge' | 'return' | 'driver' | 'moveOver' | 'madMax' | 'evasion'; phase: 'signal' | 'moving' } }
  creeping?: boolean // "Creeping for visibility"
  waitingFor?: 'gap' | 'crossTraffic' | 'emergencyVehicle' | null
  goAround?: boolean // going around a stopped car
  emergencyVehicle?: 'pullOver' | 'yield' | 'moveOver' | null
  schoolBus?: boolean
  phantomBrake?: boolean
  weather?: { rain: number; fog: number } | null
  maneuver?: { kind: string; step: number; total: number; dir: 1 | -1 } | null
  nag?: NagState
  /** Learned steering calibration, for debugging. */
  steerSign?: number
  steerGain?: number
}

/** 5 Hz: other cars within 600 m. */
export type Traffic = {
  t: 'traffic'
  cars: { id: number; pos: Vec3; dir: Vec3; speed: number; w: number; l: number; emergency?: boolean; schoolBus?: boolean }[]
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
export type Route = {
  t: 'route'; points: Vec3[]; length: number; openEnded?: boolean; arrival?: 'parking' | 'curb' | 'point'
  /** FSD v14 style "P" pin: the parking spot it picked */
  parkingPin?: { pos: Vec3 }
}

/** Relay -> app when the minimap image arrives. */
export type Minimap = { t: 'minimap'; url: string; offset?: number[]; size?: number[] }

export type EventKind =
  | 'disengage' | 'engaged' | 'reengaged' | 'arrived' | 'vehicleChanged' | 'levelLoaded' | 'error' | 'settings'
  // FSD behavior
  | 'laneChange' | 'creeping' | 'nudge' | 'goAround' | 'emergencyVehicle' | 'schoolBus' | 'maneuver' | 'summon'
  | 'phantomBrake' | 'yellowHesitation' | 'collisionEvasion'
  // supervision
  | 'nag' | 'strike' | 'lockout'
  // active safety
  | 'fcw' | 'aeb' | 'blindSpotWarning' | 'laneDeparture' | 'obstacleAwareAccel'
  // voice notes: the wheel button asks the app to start/stop recording; the relay confirms saving
  | 'voiceNote' | 'voiceNoteSaved'

export type Event = {
  t: 'event'
  kind: EventKind
  detail?: string
  /** the raw event fields (e.g. { dir, reason } for laneChange, { level, reason } for nag) */
  data?: Record<string, unknown>
}

/** Relay status. `game` is whether the mod is connected. */
export type Bridge = { t: 'bridge'; game: 'connected' | 'disconnected'; version?: string }

export type Hello = { t: 'hello'; protocol: number; game: string; version: string }
export type Pong = { t: 'pong'; time: number }
/** Answer to `debug`: what this BeamNG version exposes (for fixing API mismatches). */
export type Debug = { t: 'debug'; ge: Record<string, unknown>; vehicle?: Record<string, unknown> }

/** Things a wheel button can do (mapped in the app's settings). */
export type ActionName =
  | 'toggleFSD' | 'toggleAutosteer' | 'toggleTACC' | 'disengage' | 'voiceNote' | 'nudge'
  | 'laneLeft' | 'laneRight' | 'profileNext' | 'profilePrev' | 'speedUp' | 'speedDown'
  | 'followCloser' | 'followFarther' | 'autopark' | 'summonForward' | 'summonReverse' | 'summonStop'

export const ACTIONS: { name: ActionName; label: string }[] = [
  { name: 'toggleFSD', label: 'Start / stop FSD' },
  { name: 'toggleAutosteer', label: 'Start / stop Autosteer' },
  { name: 'toggleTACC', label: 'Start / stop cruise (TACC)' },
  { name: 'disengage', label: 'Turn autopilot off' },
  { name: 'voiceNote', label: 'Voice note (iPad mic)' },
  { name: 'nudge', label: 'Hands-on nudge' },
  { name: 'laneLeft', label: 'Lane change left' },
  { name: 'laneRight', label: 'Lane change right' },
  { name: 'speedUp', label: 'Faster (FSD: next profile)' },
  { name: 'speedDown', label: 'Slower (FSD: previous profile)' },
  { name: 'profileNext', label: 'Next speed profile' },
  { name: 'profilePrev', label: 'Previous speed profile' },
  { name: 'followCloser', label: 'Follow closer' },
  { name: 'followFarther', label: 'Follow farther' },
  { name: 'autopark', label: 'Autopark' },
  { name: 'summonForward', label: 'Summon forward' },
  { name: 'summonReverse', label: 'Summon reverse' },
  { name: 'summonStop', label: 'Stop summon' },
]

/**
 * Relay -> app: which wheel button does what. Buttons are read by the wheel companion
 * (bridge/wheel_helper.py), so any button works, bound in BeamNG or not.
 */
export type ButtonMap = {
  t: 'buttonMap'
  map: Partial<Record<ActionName, number>>
  /** waiting for a button press to assign to this action */
  learning: ActionName | null
  /** the companion that reads the wheel's buttons (null: not running) */
  companion: { name: string; buttons: number } | null
}
/** Relay -> app: a wheel button went down/up (for "press a button" UIs). */
export type WheelButton = { t: 'wheelButton'; button: number; down: boolean }

/**
 * Relay -> app: a backup-camera frame (while in R, or a preview). `data` is base64 PNG.
 * Real backup cameras show a mirror image: draw it flipped when `mirrored`. `off` = hide the view.
 */
export type CameraFrame = {
  t: 'camera'; view: 'rear'; off?: boolean
  seq?: number; mime?: string; data?: string; width?: number; height?: number; mirrored?: boolean
}

export type GameMessage = State | Traffic | MapInfo | Route | Minimap | Event | Bridge | Hello | Pong | Debug | ButtonMap | WheelButton | CameraFrame

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
  | { t: 'wheel'; spring?: boolean; strength?: number; helper?: boolean } // FFB wheel spring on/off, strength 0..1 (default on, 0.6); helper: the SDL wheel helper drives the wheel
  | { t: 'settings'; quirks?: Partial<Quirks>; safety?: Partial<SafetySettings>; speedOffsetMph?: number | null; setSpeed?: number | null; followDistance?: number | null; laneChanges?: boolean; nags?: boolean; camera?: CameraSettings }
  | { t: 'attention'; state: 'ok' | 'phone' | 'eyesOff' | 'unknown' } // from the app's cabin camera, ~2-5 Hz
  | { t: 'nudge' } // "hands on wheel" (e.g. a button for keyboard players)
  | { t: 'summon'; dir: 'forward' | 'reverse' | null } // Dumb Summon (null stops)
  | { t: 'autopark' }
  | { t: 'resetStrikes' }
  | { t: 'voiceNote'; audio: string; mime: string; durationSec?: number; text?: string } // base64 audio; saved by the relay
  | { t: 'action'; name: ActionName } // do what a wheel button would
  | { t: 'learnButton'; action: ActionName | null } // the next wheel button pressed gets this action (null cancels)
  | { t: 'setButton'; action: ActionName; button: number | null } // set / clear directly
  | { t: 'requestButtonMap' }
  | { t: 'camera'; on?: boolean } // show the backup camera for 15 s without shifting to R (a preview button); false hides it
  | { t: 'wheelButton'; button: number; down: boolean } // from the wheel companion
  | { t: 'companionHello'; name: string; buttons: number } // from the wheel companion
  | { t: 'requestMap' }
  | { t: 'requestMinimap' }
  | { t: 'debug' }
  | { t: 'ping' }

/** Backup camera: on in R (default on), frames per second 1..10 (default 5), quality low 320x180 (default) / medium 480x270 / high 640x360. Higher costs more fps in the game. */
export type CameraSettings = { backup?: boolean; fps?: number; quality?: 'low' | 'medium' | 'high' }
export type Quirks = { phantomBraking: boolean; yellowHesitation: boolean; wiggle: boolean; weather: boolean; creep: boolean }
export type SafetySettings = { fcw: 'early' | 'medium' | 'late' | 'off'; aeb: boolean; evasion: boolean; lda: boolean; blindSpot: boolean; obstacleAware: boolean }

export const COMMAND_TYPES: ReadonlySet<Command['t']> = new Set([
  'gear', 'lights', 'signal', 'horn', 'door', 'autopilot', 'navigate', 'cancelRoute',
  'throttleOverride', 'wheel', 'settings', 'attention', 'nudge', 'summon', 'autopark', 'resetStrikes', 'voiceNote',
  'action', 'learnButton', 'setButton', 'requestButtonMap', 'wheelButton', 'companionHello', 'camera',
  'requestMap', 'requestMinimap', 'debug', 'ping',
])

export const MPH = 0.44704
