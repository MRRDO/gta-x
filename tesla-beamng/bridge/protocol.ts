// Messages between the BeamNG mod, the relay and the app.
// Every message is { t: '<type>', ...fields }. Game <-> relay: one JSON object
// per line over TCP (127.0.0.1:8766). Relay <-> app: one JSON object per
// WebSocket message (ws://<pc>:8765/?token=...).
//
// World coordinates are BeamNG meters: x east, y north, z up.

export type Vec3 = [number, number, number]
export type Gear = 'P' | 'R' | 'N' | 'D'
/** 'furious' = hold Max / Service mode: cuts in, tails and speeds; the safety layer still brakes. Not in the dial's profile cycle. */
export type Profile = 'sloth' | 'chill' | 'standard' | 'hurry' | 'madmax' | 'furious'
/** fsd: drives everything · autosteer: steers + cruise (Tesla Autosteer) · tacc: cruise only, you steer */
export type AutopilotMode = 'off' | 'autosteer' | 'fsd' | 'tacc'
export type SignalDir = 'left' | 'right' | 'hazard' | null
export type Arrival = 'Parking Lot' | 'Street' | 'Driveway' | 'Parking Garage' | 'Curbside' | 'Drive Thru'
export type DisengageReason = 'steer' | 'brake' | 'throttle' | 'arrived' | 'error' | 'app' | 'attention' | 'summon' | 'switch'

// ---------------------------------------------------------------------------
// Game -> app
// ---------------------------------------------------------------------------

/** 20 Hz, the player's car. */
export type State = {
  t: 'state'
  time: number // game seconds
  vehicle: { id: number; name: string; model: string; color?: string /* paint, #rrggbb */ }
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
  /** The game's frame rate. State comes once per frame at most, so below 20 fps the rate = fps. */
  fps?: number
  /** Speed limit of the road the car is on (m/s), FSD on or off. */
  speedLimit?: number
  /** Over the limit by more than the warning offset (Speed Assist): show the limit sign highlighted. */
  speedWarning?: boolean
  /** Vehicle Hold is holding the car (stopping mode 'hold'): the "H" icon. */
  hold?: boolean
  /** This trip so far (resets when you park after driving 300 m or more): Safety Score 0..100 and stats. */
  /** Climate settings the app last sent ({t:'climate'}). Nothing in the game reacts to them; hardware bridges (fan, heater) can read this. */
  climate?: Record<string, unknown>
  /** Cameras: which views are streaming and whether the frame-rate governor has slowed or paused them (the game's fps fell). */
  camera?: { views: CamView[]; level: 0 | 1 | 2 | 3; paused: boolean }
  trip?: { score: number; km: number; fsdPercent: number; hardBrakes: number }
}

export type SafetyState = {
  fcw: boolean // forward collision warning (beep + red car on screen)
  aeb: boolean // automatic emergency braking right now
  blindLeft: boolean // car in the left blind spot (red light in the mirror)
  blindRight: boolean
  laneDeparture: boolean // lane departure avoidance is steering you back
  ttc: number | null // seconds to a predicted collision
  rearDist?: number // metres to what is behind the bumper, only while in Reverse (wheel lights as a parking meter)
  rearWarn?: boolean // Rear Cross Traffic Alert: something crosses behind while reversing (beep + red on the rear view); braking follows if it gets close
}

export type NagState = {
  level: 0 | 1 | 2 | 3 // 1 "Pay attention to the road" (blue flash), 2 beeping, 3 "Take over immediately" (red)
  reason: 'phone' | 'eyesOff' | 'hands' | null
  strikes: number
  maxStrikes: number // 5
  lockedOut: boolean // FSD unavailable for the rest of the drive
  /** Driver monitoring setting (nagMode) and what's watching right now. */
  mode?: 'auto' | 'camera' | 'wheel' | 'off'
  active?: 'camera' | 'wheel'
  /** Wheel mode: seconds between required hands-on-wheel nudges here (longer on highways and at low speed). */
  interval?: number
}

export type WheelState = {
  /** active = driving the wheel now; available = FFB wheel found; helper = the external wheel helper drives it; no wheel / unavailable / off / disabled otherwise */
  status: 'active' | 'available' | 'no wheel' | 'unavailable' | 'off' | 'disabled' | 'helper' | 'own' | 'unknown'
  reason?: string
  strength: number // 0..1 of the wheel's max force
  pos: number // physical wheel, raw axis -1..1
  target: number // where the spring pulls it
  force: number // -1..1 of max
  ratio: number // steering input per raw wheel unit (learned)
  calibrated: boolean // motor direction confirmed (first turn of a session proves it)
  /** Device id the game's own force feedback drives (>= 0 = normal game FFB is on; only while FSD isn't holding the wheel). */
  gameId?: number
  /** The physical wheel's rotation in degrees (G29: 900); the wheel is turned 1:1 with the car's steering wheel. */
  rangeDeg?: number
}

export type AutopilotState = {
  engaged: boolean
  mode: AutopilotMode
  profile: Profile
  targetSpeed: number // m/s
  speedLimit: number | null // m/s at the car, from the road graph (or a class default)
  leadGap: number | null // m to the car ahead in our lane
  control: { kind: 'stop' | 'signal' | 'crosswalk'; dist: number; red: boolean; state?: 'red' | 'yellow' | 'green' | 'stop' | null; id?: string; dot?: number; lat?: number } | null // id, dot (signal dir . our heading), lat: debug
  nextTurn: { dir: 'left' | 'right' | 'straight'; dist: number; road: string } | null
  remaining: number | null // m to destination
  lastDisengage: { reason: DisengageReason; time: number } | null
  /** The driver is pressing the accelerator (pedal or the app's strip): FSD stays on and goes faster, no braking. */
  accelOverride: boolean
  /** What the app shows: 'leaving' while backing out of a spot, 'parking' during the arrival move, 'parked' after. */
  phase?: 'driving' | 'leaving' | 'parking' | 'parked' | null
  /** drive | maneuver (backing out, 3-point turn, back-in parking) | summon */
  activity?: 'drive' | 'maneuver' | 'summon'
  setSpeed?: number | null // m/s, TACC / Autosteer
  lane?: { index: number; count: number; changing?: { dir: 'left' | 'right'; reason: 'route' | 'pass' | 'merge' | 'return' | 'driver' | 'moveOver' | 'madMax' | 'evasion'; phase: 'signal' | 'moving' } }
  creeping?: boolean // "Creeping for visibility"
  waitingFor?: 'gap' | 'crossTraffic' | 'emergencyVehicle' | 'pedestrian' | null
  goAround?: boolean // going around a stopped car
  emergencyVehicle?: 'pullOver' | 'yield' | 'moveOver' | null
  schoolBus?: boolean
  phantomBrake?: boolean
  weather?: { rain: number; fog: number } | null
  maneuver?: { kind: string; step: number; total: number; dir: 1 | -1 } | null
  nag?: NagState
  /** Total damage of the car (BeamNG's own number); the practice runner scores hits with its growth. */
  damage?: number
  /**
   * Alert card: 'crash' (damage jump, FSD let go, hazards on: "Pull over immediately"),
   * 'takeover' (FSD > 80 mph where the limit is < 55), 'attention' (nag level 2+).
   * Red card + alarm for crash/takeover, blue for attention. Absent when there's nothing.
   */
  alert?: { kind: 'crash' | 'takeover' | 'attention' | 'lowConfidence' | 'degraded'; message: string; level: number; confidence?: number } | null
  /** FSD's confidence right now, 0..1. Under 55 % (for 1.5 s) it shows the 'lowConfidence' alert and keeps driving; tapping the accelerator then hands the car over. */
  confidence?: number
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
  t: 'route'; points: Vec3[]; length: number; openEnded?: boolean; arrival?: 'parking' | 'curb' | 'point'; /** just the street ahead while FSD has no route */ passive?: boolean
  /** FSD v14 style "P" pin: the parking spot it picked */
  parkingPin?: { pos: Vec3 }
}

/**
 * Parking spots near a point: sent once when FSD gets within 200 m of the destination, and on
 * { t: 'requestParkingSpots' }. Show them on the map; tapping one sends { t: 'autopark', spot: id }.
 */
export type ParkingSpots = {
  t: 'parkingSpots'
  near: [number, number]
  spots: { id: number; pos: Vec3; dir: [number, number]; free: boolean }[]
}

/** Relay -> app when the minimap image arrives. */
export type Minimap = { t: 'minimap'; url: string; offset?: number[]; size?: number[] }

export type EventKind =
  | 'disengage' | 'engaged' | 'reengaged' | 'arrived' | 'vehicleChanged' | 'levelLoaded' | 'levelUnloaded' | 'error' | 'settings' | 'wheelMedia' | 'wheelDial'
  // FSD behavior
  | 'stunt' | 'laneChange' | 'creeping' | 'nudge' | 'goAround' | 'emergencyVehicle' | 'schoolBus' | 'maneuver' | 'summon'
  | 'phantomBrake' | 'yellowHesitation' | 'collisionEvasion'
  // supervision
  | 'nag' | 'strike' | 'lockout'
  // active safety
  | 'fcw' | 'aeb' | 'rearCrossTraffic' | 'blindSpotWarning' | 'laneDeparture' | 'obstacleAwareAccel'
  // voice notes: the wheel button asks the app to start/stop recording; the relay confirms saving
  | 'voiceNote' | 'voiceNoteSaved'
  // driver + trip
  | 'turnRequest'      // paddle/stalk with no lane that way: FSD will turn at the next junction ({dir, dist} or {none})
  | 'notice'           // informational, e.g. "gear change ignored while FSD drives"
  | 'autoShift'        // Auto Shift out of Park picked a gear (detail: 'D' | 'R')
  | 'banish' | 'summonTo' // Banish / Smart Summon accepted
  | 'autopark'         // a tapped spot was accepted (detail: 'parking now' | 'parking at destination')
  | 'unresponsive'     // unresponsive driver: {action: 'pullOver' | 'park' | 'pulledOver' | 'parked' | 'cancelled'}
  | 'swerveAssist'     // manual driving: stabilizing a swerve (detail: 'stabilizing' | 'done')
  | 'collision'        // the car was hit (see autopilot.alert)
  | 'signalStuck'      // a red that never changed for 90 s, treated as an all-way stop
  | 'emergencyStop'    // "I'm not feeling well": FSD is stopping the car (detail from planner); with data.cancelled when called off
  | 'emergencyStopped' // stopped safely: detail 'parkingSpot' | 'roadside'. The app can call someone now
  | 'brain'            // the driving brain noticed something: detail says what (erratic car, tailgater, pedestrian, staleGreen, laneHold)
  | 'advice'           // the FSD Assistant's advice after a stuck FSD: detail 'wait|replan|creep|askDriver: why'
  | 'stuck'            // FSD stopped for no reason it can name: level 1 re-plan, 2 reset, 3 asks the driver
  | 'longRoute'        // a trip far longer than the straight line ({length, straight}), for debugging
  | 'arriving'         // point-to-point: the destination is close. data {dist, current, freeSpots, options: park|street|pullOver|driveway|takeOver|driveThru}; answer with {t:'arrivalChoice'}
  | 'arrivalChoice'    // the choice was applied
  | 'speedWarning'     // Speed Assist chime: over the limit (detail '47 in a 35')
  | 'autoHighBeams'    // auto high beams switched (detail 'on' | 'off')
  | 'confirmGo'        // trafficControl 'confirm': stopped at a stop sign / green light, waiting for the driver's go. data {what: 'stopSign' | 'light'}
  | 'pinRequired'      // PIN to Drive is locked and someone tried to drive
  | 'lightShow'        // detail: the show's name when it starts, 'end' when it finishes or is stopped (driving, or another command)
  | 'tripSummary'      // parked after a drive of 300 m+: detail = Safety Score, data {km, minutes, fsdPercent, hardBrakes, hardTurns, takeovers, tailgatePercent, topSpeed, score}
  | 'pullOver'         // P pressed while FSD drives: pulling over ({dist}); take over to cancel
  | 'monitoring'       // camera mode: detail 'cameraUnavailable' (using the wheel) | 'camera' (back)

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
  | 'toggleFSD' | 'toggleAutosteer' | 'toggleTACC' | 'toggleLKA' | 'disengage' | 'voiceNote' | 'nudge'
  | 'laneLeft' | 'laneRight' | 'profileNext' | 'profilePrev' | 'speedUp' | 'speedDown'
  | 'followCloser' | 'followFarther' | 'confirm' | 'autopark' | 'summonForward' | 'summonReverse' | 'summonStop' | 'park'
  | 'dialUp' | 'dialDown' | 'dialClick' // the G29 red dial: turn = up/down, click cycles what it controls (DIAL_MODES)
  | 'volumeUp' | 'volumeDown' | 'mute' | 'playPause' | 'nextTrack' | 'prevTrack' | 'assistant' // media keys: the relay tells the app ({t:'media'}), not the game

export const ACTIONS: { name: ActionName; label: string }[] = [
  { name: 'toggleFSD', label: 'Start / stop FSD' },
  { name: 'toggleAutosteer', label: 'Start / stop Autopilot (TACC)' },
  { name: 'toggleTACC', label: 'Start / stop cruise (TACC)' },
  { name: 'toggleLKA', label: 'Lane Keep Assist on / off' },
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
  { name: 'confirm', label: 'Confirm (go after a stop, in Traffic Control confirm mode)' },
  { name: 'autopark', label: 'Autopark' },
  { name: 'park', label: 'Park (FSD driving: pull over and park)' },
  { name: 'dialUp', label: 'Dial turn up (volume / follow distance / speed / profile)' },
  { name: 'dialDown', label: 'Dial turn down' },
  { name: 'dialClick', label: 'Dial button (cycles what the dial controls)' },
  { name: 'volumeUp', label: 'Volume up (media, on the iPad)' },
  { name: 'volumeDown', label: 'Volume down (media, on the iPad)' },
  { name: 'mute', label: 'Mute / unmute (media)' },
  { name: 'playPause', label: 'Play / pause (media)' },
  { name: 'nextTrack', label: 'Next track (media)' },
  { name: 'assistant', label: 'Talk to the voice assistant (push to talk)' },
  { name: 'prevTrack', label: 'Previous track (media)' },
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
/** rear = backup camera (in R); front = on request; left/right = side repeaters while signaling (setting camera.side) */
export type CamView = 'rear' | 'front' | 'left' | 'right'
export type CameraFrame = {
  t: 'camera'; view: CamView; off?: boolean
  seq?: number; mime?: string; data?: string; width?: number; height?: number; mirrored?: boolean
}

/**
 * Relay -> app on connect: the car cameras it can stream. Each one: ws://host/cam/<id> sends one
 * binary image (JPEG, or PNG if the game can't write JPEG) per message; GET /cam/<id>.jpg is the
 * latest frame (/cam/<id>.jpg). 'rear' only in R (or a preview); 'front' only on request ({t:'camera', on:true, view:'front'}); 'left'/'right' only while signaling
 * with camera.side on. A frame-rate governor drops or pauses the cameras when the game's fps falls (see state.camera).
 */
export type Cameras = { t: 'cameras'; cams: { id: CamView; width: number; height: number; fps: number }[] }

/** Relay -> app when a wheel button mapped to a media action is pressed (the G29's dial = volume). */
export type Media = { t: 'media'; action: 'volumeUp' | 'volumeDown' | 'mute' | 'playPause' | 'nextTrack' | 'prevTrack' | 'assistant' }

/** What the red dial controls; its button cycles through them. */
export const DIAL_MODES = ['volume', 'distance', 'speed', 'profile'] as const
export type DialMode = (typeof DIAL_MODES)[number]
/** Relay -> app: the dial's mode changed or it was turned (show a bubble: "Follow distance", etc.). */
export type Dial = { t: 'dial'; mode: DialMode; dir?: 'up' | 'down' }

export type GameMessage = Dial | Media | Cameras | State | Traffic | MapInfo | Route | Minimap | Event | Bridge | Hello | Pong | Debug | ButtonMap | WheelButton | CameraFrame | ParkingSpots

// ---------------------------------------------------------------------------
// App -> game
// ---------------------------------------------------------------------------

export type Command =
  | { t: 'gear'; gear: Gear }
  | { t: 'lights'; low?: boolean; high?: boolean; fog?: boolean }
  | { t: 'signal'; dir: SignalDir }
  | { t: 'horn'; on: boolean }
  | { t: 'door'; door: string; open: boolean }
  | { t: 'autopilot'; mode: AutopilotMode; profile?: Profile; fromPark?: boolean } // fromPark: Start Self-Driving from P (the car picks D/R and backs out itself)
  | { t: 'navigate'; to: Vec3 | { node: string }; stops?: Vec3[]; arrival?: Arrival }
  | { t: 'cancelRoute' }
  | { t: 'traffic'; count: number } // (practice runner) AI cars around the player, 0 removes them
  | { t: 'reloadMod'; vehicle?: boolean } // (update while playing) reload the bridge from disk (unpacked mod folder)
  | { t: 'teleport'; x: number; y: number; z?: number; hx: number; hy: number; flip?: boolean; repair?: boolean } // (testing) put the car somewhere
  | { t: 'throttleOverride'; value: number } // -1..1, resend at >= 5 Hz while held; lapses after 0.5 s
  | { t: 'wheel'; spring?: boolean; strength?: number; helper?: boolean; ownFfb?: boolean; rangeDeg?: number } // FFB wheel spring on/off, strength 0..1 (default on, 1.0); helper: the SDL wheel helper drives the wheel; rangeDeg: the wheel's rotation (default 900)
  | { t: 'settings'; quirks?: Partial<Quirks>; safety?: Partial<SafetySettings>; speedOffsetMph?: number | null; setSpeed?: number | null; followDistance?: number | null; laneChanges?: boolean; nags?: boolean; camera?: CameraSettings
      /** Auto Shift out of Park: press the brake in P and the car picks D or R (default off). */
      autoShift?: boolean
      /** Unresponsive driver: 'park' (default) = drive to a free spot within 500 m and park, else pull over; 'pullOver' = always just pull over. */
      unresponsive?: 'park' | 'pullOver'
      /**
       * Driver monitoring: 'off' (no nags), 'camera' (the iPad cabin camera; falls back to the
       * wheel with a 'monitoring' event when the camera stops), 'wheel' (hands-on-wheel nudges,
       * less often on highways and at low speed), 'auto' (default: camera while it reports).
       */
      nagMode?: 'auto' | 'camera' | 'wheel' | 'off'
      /** Paddles / shift bindings act as turn signals (left = shift down, right = shift up). Default on. */
      paddleSignals?: boolean
      /** Light on-line learning of your driving style (default on). */
      learning?: boolean
      /** FSD Assistant: a small local LLM (Ollama) may comment on a stuck FSD; advice only (default on; does nothing without a local model). Handled by the relay. */
      assistant?: boolean
      /** Nudge the speed caps by up to +-8% with the policy trained on your driving (rl/train_bc.py -> the game's settings/teslaBridgePolicy.json). Default off; needs the file. */
      policy?: boolean
      /** Confidence under which FSD asks you to take over (default 0.55). */
      confidenceFloor?: number
      /** Auto headlights (default on): on when it's dark or raining, off in daylight. */
      autoHeadlights?: boolean
      /** Auto high beams at night above 25 mph, dipped for cars ahead (default off). */
      autoHighBeams?: boolean
      /** Speed Assist: 'display' (default) highlights the limit, 'chime' also sends 'speedWarning' events, 'off'. */
      speedWarning?: 'off' | 'display' | 'chime'
      /** mph over the limit before the warning (default 5). */
      speedWarnOffset?: number
      /** While you drive: 'roll' (default, coast), 'creep' (moves off like an automatic), 'hold' (Vehicle Hold at a stop). */
      stoppingMode?: 'roll' | 'creep' | 'hold'
      /** Regenerative braking: lifting off the accelerator slows the car (one-pedal driving). Default off. */
      regen?: boolean
      /** Acceleration, for FSD and your own pedal: 'standard' (default), 'chill' (softer, eased in) or 'sport' (sharper pedal, harder pull). */
      accelMode?: 'standard' | 'chill' | 'sport'
      /** Steering feel under FSD: how early it steers and how fast the wheel moves. Default 'standard'. */
      steerFeel?: 'comfort' | 'standard' | 'sport'
      /** How hard you must turn the wheel to take over from FSD. A light touch only nudges the car; default 'normal'. */
      takeover?: 'light' | 'normal' | 'firm'
      /** Swerve Assist while you drive (default on). */
      swerveAssist?: boolean
      /** Furious profile only: a short handbrake-and-throttle drift through tight corners (experimental, untested in the real game; default on for Furious). Set false to turn it off. */
      drift?: boolean
      /** Traffic Light and Stop Sign Control: 'auto' (default) or 'confirm': after stopping FSD waits for your go (tap the accelerator, or the confirm button) before leaving a stop sign or a light that turned green. */
      trafficControl?: 'auto' | 'confirm'
      /** Regenerative braking strength, Tesla's Standard / Low (default standard). Only when `regen` is on and the car has no regen of its own. */
      regenLevel?: 'standard' | 'low'
      /** Fog lights come on by themselves in fog (default on). */
      autoFogLights?: boolean
      /** Steering Weight (Tesla: Controls > Dynamics): 'light' | 'standard' | 'heavy'. Scales the wheel's self-centering, friction and damping when the bridge drives the wheel's force feedback (FSD, or when the game can't). */
      steeringWeight?: 'light' | 'standard' | 'heavy'
      /** Hill Hold: stopped on a slope with your feet off the pedals, the brake stays on until you accelerate (default on). Best effort, needs a real game to verify. */
      hillHold?: boolean
      /** Road feel through the wheel while FSD drives (bumps and surface texture), 0..2, default 0 (off: it made the wheel shake). */
      roadFeel?: number
      /** Keep the bridge's own steering feel on the wheel after FSD instead of handing force feedback back to the game (use if the wheel goes dead after FSD; default off). */
      ownFfb?: boolean
      /** Valet Mode: self-driving off, gentle acceleration, top speed about 65 mph. */
      valet?: boolean
      /** Auto wipers from the weather (default on; best effort, depends on the car). */
      autoWipers?: boolean }
  | { t: 'attention'; state: 'ok' | 'phone' | 'eyesOff' | 'unknown' } // from the app's cabin camera, ~2-5 Hz
  | { t: 'nudge' } // "hands on wheel" (e.g. a button for keyboard players)
  | { t: 'summon'; dir: 'forward' | 'reverse' | null } // Dumb Summon (null stops)
  | { t: 'climate'; on?: boolean; driverTemp?: number; passengerTemp?: number; fan?: number; defrost?: boolean; precondition?: boolean; cabinOverheat?: boolean; keepOn?: boolean; dogMode?: boolean; campMode?: boolean; bioweapon?: boolean; seatHeat?: Record<string, number>; wheelHeat?: boolean; vents?: string } // foundation: stored and echoed in state.climate for future fan/heater hardware; the game itself has no cabin climate
  | { t: 'buttonGuard' } // relay -> game: a mapped wheel button was just pressed; undo what the game's own binding did with it (ignition)
  | { t: 'confirm' } // "go": answers a confirmGo event (also a wheel button / a tap on the accelerator)
  | { t: 'pinLock'; on: boolean } // PIN to Drive: on = the car stays in Park (and FSD refuses) until the app sends on:false after the PIN is entered
  | { t: 'lightShow'; name: 'welcome' | 'goodbye' | 'holiday' | 'strobe' | null } // choreographed headlights/fog/blinkers while parked (null stops it)
  | { t: 'arrivalChoice'; choice: 'park' | 'street' | 'pullOver' | 'driveway' | 'takeOver' | 'driveThru' } // answer to the 'arriving' event
  | { t: 'summonTo'; to?: [number, number] | [number, number, number]; back?: boolean } // Smart Summon: drive to a point (or back to where Banish started) and stop
  | { t: 'banish' } // drive off by itself to the nearest free parking spot and park
  | { t: 'autopark'; spot?: number } // spot: an id from parkingSpots (tapped on the map); none = the nearest free spot beside the car
  | { t: 'requestParkingSpots'; near?: [number, number]; radius?: number }
  /** "I'm not feeling well": FSD takes over (engaging if off), hazards on, and stops at the safer of a quick-to-reach free parking spot or the roadside. cancel:true calls it off ("I'm fine"). Events: emergencyStop, emergencyStopped. */
  | { t: 'emergencyStop'; cancel?: boolean }
  | { t: 'resetStrikes' }
  | { t: 'voiceNote'; audio: string; mime: string; durationSec?: number; text?: string } // base64 audio; saved by the relay
  | { t: 'action'; name: ActionName } // do what a wheel button would
  | { t: 'learnButton'; action: ActionName | null } // the next wheel button pressed gets this action (null cancels)
  | { t: 'setButton'; action: ActionName; button: number | null } // set / clear directly
  | { t: 'requestButtonMap' }
  | { t: 'hello'; app?: string; version?: string } // the app says hi on connect (logged by the relay)
  | { t: 'camera'; on?: boolean; view?: CamView } // show the backup camera for 15 s without shifting to R (a preview button); false hides it
  | { t: 'wheelButton'; button: number; down: boolean } // from the wheel companion
  | { t: 'companionHello'; name: string; buttons: number } // from the wheel companion
  | { t: 'requestMap' }
  /** The PC is about to restart the wheel. With `assist`, a car moving above 10 mph is held by FSD for `seconds` (default 8) until the wheel is back. */
  | { t: 'blackboxMark'; note?: string } // save the black box now (the iPad's Report button)
  | { t: 'blackboxNote'; file: string; note: string } // what went wrong, typed on the iPad after a black box
  | { t: 'blackboxStatus' }
  | { t: 'wheelReset'; assist?: boolean; seconds?: number }
  | { t: 'wheelRescan' }
  | { t: 'mediaKey'; action: 'volumeUp' | 'volumeDown' | 'mute' | 'playPause' | 'nextTrack' | 'prevTrack' } // the phone page's music buttons (relay hands them to the app)
  | { t: 'pullOver' } // assistant: pull over to the side of the road (starts FSD if needed); taking over cancels
  | { t: 'requestMinimap' }
  | { t: 'debug' }
  | { t: 'ping' }

/** Backup camera: on in R (default on), frames per second 1..10 (default 5), quality low 320x180 (default) / medium 480x270 / high 640x360. Higher costs more fps in the game. */
export type CameraSettings = { backup?: boolean; side?: boolean; fps?: number; quality?: 'low' | 'medium' | 'high' }
export type Quirks = { phantomBraking: boolean; yellowHesitation: boolean; wiggle: boolean; weather: boolean; creep: boolean }
export type SafetySettings = { fcw: 'early' | 'medium' | 'late' | 'off'; aeb: boolean; evasion: boolean; lda: boolean; lka: boolean; blindSpot: boolean; obstacleAware: boolean }

export const COMMAND_TYPES: ReadonlySet<Command['t']> = new Set([
  'gear', 'lights', 'signal', 'horn', 'door', 'autopilot', 'navigate', 'cancelRoute',
  'throttleOverride', 'wheel', 'settings', 'attention', 'nudge', 'summon', 'summonTo', 'banish', 'autopark', 'resetStrikes', 'voiceNote',
  'action', 'learnButton', 'setButton', 'requestButtonMap', 'wheelButton', 'companionHello', 'camera', 'hello',
  'requestMap', 'requestMinimap', 'debug', 'ping', 'teleport', 'traffic', 'reloadMod', 'requestParkingSpots', 'arrivalChoice', 'lightShow', 'pinLock', 'climate', 'confirm', 'buttonGuard', 'emergencyStop', 'pullOver', 'mediaKey', 'wheelReset', 'wheelRescan', 'blackboxMark', 'blackboxNote', 'blackboxStatus',
])

export const MPH = 0.44704
