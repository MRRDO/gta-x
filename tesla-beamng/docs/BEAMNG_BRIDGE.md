# BeamNG ⇄ Tesla UI bridge

The iPad app shows and drives a car in **BeamNG.drive**, and our own FSD
(Supervised)–style autopilot drives it through the player's inputs, so the
in-car steering wheel and a real force-feedback wheel (G29) turn with it.

```
BeamNG.drive (PC)                           relay (PC, Node)                 iPad
┌────────────────────────────────┐  TCP     ┌─────────────────────┐  Wi-Fi  ┌──────────────┐
│ teslaBridge    (GE extension)  │◀───────▶│ bridge/relay.ts      │◀──────▶│ Tesla UI app │
│  map, traffic, signals, weather│ 127.0.0.1│  ws + http :8765     │   ws   │  or test page│
│  planner 10 Hz, safety 20 Hz   │   :8766  │  test page, minimap  │        └──────────────┘
│ teslaAutopilot (vehicle ext)   │          │  voice notes, token  │
│  state 20 Hz, commands, driving│          └──────────▲──────────┘
│  via player inputs, FFB wheel  │                     │ ws (optional)
│ teslaBeacon (nearby cars)      │          ┌──────────┴──────────┐
│  emergency lightbars           │          │ bridge/wheel_helper │ backup: turns the
└────────────────────────────────┘          │  SDL spring (G29)   │ wheel via SDL
                                            └─────────────────────┘
```

## Status

**Built without the game.** Everything was written and tested in a cloud
container against a fake BeamNG (`beamng/test/harness.lua`) that runs the real
mod Lua with stubbed game APIs, a bicycle-model car, a simulated G29 (motor,
gear friction, the game's own centering force) and the real relay.

| Suite | Checks |
|---|---|
| `npm test` (pure Lua) | driving 29, wheel 14, maneuvers 12, **FSD behaviors 80** |
| `npm run e2e` (harness + relay + fake app) | 66 (incl. wheel-button mapping), also with a backwards motor, backwards car steering, config-only FFB (all 66) and no wheel (55) |
| app connector self-test | 27 |
| `npm run test:helper` (backup wheel helper) | 11 |
| `npm run doctor` | setup check (installed? running? mapped?) |

API names come from the game's docs, BeamMP's source (a multiplayer mod for
BeamNG 0.39) and the Advanced Steering mod. Anything unsure is wrapped so a
mismatch switches that one feature off instead of crashing, and
**Run diagnostics** reports what your game version exposes. Expect a round or
two of fixes after the first real run.

## Setup (Quentin)

**Easiest:** have Cowork do it with [`COWORK_HANDOFF.md`](COWORK_HANDOFF.md), or run it yourself:

1. In this folder, in PowerShell: `powershell -ExecutionPolicy Bypass -File .\setup.ps1`.
   It installs Node/Python if missing, builds the mod, and copies it into BeamNG's mods
   folder. It also adds the firewall rule and puts a **Tesla Bridge** shortcut on the
   desktop. Run it again after updates.
2. Start BeamNG (**West Coast USA**, any car), then double-click **Tesla Bridge**. That
   starts the relay (QR code for the iPad), the wheel-buttons companion, and the test page.
3. `npm run doctor` checks everything and says how to fix what's missing.
4. First thing: test page → **Run diagnostics** → **Copy**, and send it over.

The PC and the iPad must be on the same Wi-Fi, set to *Private* in Windows.

Manual route: `npm install` → `npm run mod` → copy `beamng/dist/tesla_bridge.zip`
(don't unzip it) into `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods` (launcher →
*Manage User Folder*) → `npm run bridge` → `http://localhost:8765/`.

### Wheel buttons (Settings)

Map **any** button on the wheel in the test page's **Wheel buttons** card (or the app's
settings, via `learnButton`): click **Set** next to an action, then press the button.
The mapping is saved in `bridge/buttons.json`, and ▶ tries an action.

The buttons are read by the wheel companion (`wheel_helper.py --buttons`, started by
`start.bat`), so they don't need to be bound in BeamNG. Don't pick buttons BeamNG already
uses for something else, or both will happen.

Actions:
- start/stop **FSD**, **Autosteer** or **TACC**, and autopilot off
- **voice note** (iPad mic) and hands-on **nudge**
- lane change left/right
- faster/slower (in FSD this picks the speed profile, like v14), next/previous profile
- follow closer/farther
- autopark, and summon forward/reverse/stop

Without the companion, BeamNG's own bindings still work: Options → Controls → Bindings →
*Tesla UI Bridge* has Toggle FSD, Toggle Autosteer, Voice note and Hands-on nudge.

### Logitech G29 (or any force-feedback wheel)

While FSD or Autosteer drives, the mod takes over the wheel motor and pulls
the physical wheel to the car's steering angle. On disengage the game's own
force feedback comes back.

1. **G HUB:** operating range **900°**, **centering spring off**, FFB 100%.
2. **BeamNG → Options → Controls:** default G29 profile, force feedback
   **on** for steering, steering lock 1:1 (otherwise the mod learns the ratio
   from your driving), pedals on separate axes.
3. **Strength:** the test page's *Steering wheel* card has on/off and a
   strength slider (default 60%). The force ramps in over 0.8 s.
4. **Taking over:** turn it against FSD (≈45° away from where it's pulling,
   for 0.35 s). It disengages with `steer` (detail `wheel grabbed`). Hands
   resting on it are fine, and small pushes count as "hands on" for the nag.
5. **Wrong direction?** If the motor pushes the wrong way, the mod notices in
   about 0.1 s, flips and remembers. The card shows `calibrated` once proven.

**How the mod gets the motor even though the game owns it** (researched from
BeamMP and the game's `hydros.lua`): two routes, tried in order.

1. **Upvalue:** `hydros` keeps the device id in a local `FFBID`. The mod finds
   it with a recursive `debug.getupvalue` scan, sets it to −1 while engaged (the
   game stops sending forces), and drives the motor itself with
   `obj:sendForceFeedback(id, force)`: a damped position spring. On disengage
   it sends 0 and puts the id back.
2. **Config (BeamMP's way):** keep the FFB config `hydros` was given (hooking
   `hydros.onFFBConfigChanged`, or finding the stored config table), then
   `hydros.enableFFB = false` + re-apply the config to make the game let go, and
   the reverse on disengage.

The card shows which one it used (`method`). If neither works, it says
`unavailable` with the reason, FSD still drives, and you can use the helper:

### Backup wheel helper (if the wheel doesn't move)

`bridge/wheel_helper.py` turns the wheel from outside the game with SDL haptics
(DirectInput underneath, same as the game).

1. Once: `pip install pysdl2 pysdl2-dll websocket-client`.
2. In BeamNG, turn **force feedback off** for the wheel (two programs fighting
   over the motor feels awful).
3. With the relay running: double-click `bridge/wheel_helper.bat` (or
   `npm run helper`). `--list` shows wheels, `--invert` if it turns the wrong
   way, `--strength 0.8` for a firmer wheel.

It tells the car the helper owns the wheel (card: `helper`), then holds a
spring centred on FSD's steering angle, with a light speed-based centring
when FSD is off. Takeover works against FSD's angle (≈90° off for 0.3 s).
Ctrl+C / closing the window hands the wheel back to the mod.

### Wiring the app

`bridge/app/` is the app-side connector. Copy it and `bridge/protocol.ts` into
the app (it needs only React + zustand).

```ts
import { connectBeamNG, disconnectBeamNG, syncBeamNGToApp, startVoiceNotes, useBeamNG, bridge } from './bridge/app'
import { useVehicleStore } from '@/store'
import { useSimStore } from '@/sim/drive'
import { useNavStore } from '@/nav/store'

// "Vehicle source: BeamNG" on (stop useDriveSim first so it doesn't fight):
connectBeamNG('ws://192.168.1.20:8765/?token=ab12cd34') // or connectBeamNG() for ?bridge= / relay host / saved URL
const stopSync = syncBeamNGToApp({ vehicle: useVehicleStore, sim: useSimStore, nav: useNavStore })
const stopNotes = startVoiceNotes()  // the wheel's voice-note button records on the iPad
// cabin camera → FSD attention, 2–5×/s while driving:
setInterval(() => bridge()?.attention(onPhone ? 'phone' : eyesOnRoad ? 'ok' : 'eyesOff'), 250)
// off:
stopSync(); stopNotes(); disconnectBeamNG()
```

**What `syncBeamNGToApp` does**
- **Game → app, 20 Hz:** vehicle store (gear, `speedMph`, doors, frunk/trunk,
  `chargePercent`, headlights/fog), sim store (`heading`, `signal`,
  `control`, `lead`, the FSD switch, profile, `autopilot`), nav store
  (`position [lat, lon]`, `heading`, `route.coords`).
- **App → game:** the existing UI already controls the game:
  - **gear shifter** (vehicle `gear`), doors, frunk, trunk, headlights, fog
  - **FSD switch** in the sim store (`fsd`, or `fsdEngaged` / `fsdOn` /
    `fsdActive` / `autopilotEngaged`, whichever is a boolean) → engage/disengage,
    with the store's **profile** (`profile` / `fsdProfile` / `speedProfile`;
    'Mad Max' or 'madmax' both work)
  - **destination** and **stops** in the nav store (`[lat, lon]`,
    `{lat, lon}` or `{coords: [lon, lat]}`) → route in the game, with the sim
    store's `arrivalPark` as the arrival choice; clearing it cancels the route
- Field names follow the handoff; if the app differs, edit the MAP section at
  the top of `appSync.ts`. Fields a store doesn't have are skipped.

**Other controls** (`bridge()?.…`):

| UI control | Client call |
|---|---|
| FSD / Autosteer / TACC / off | `autopilot('fsd' \| 'autosteer' \| 'tacc' \| 'off', profile?)` |
| Profile | `setProfile('hurry')` |
| Turn signal stalk (lane change while FSD is on) | `setSignal('left')` |
| Accelerator strip | `holdThrottle(v)` while held, `releaseThrottle()` on release |
| Nav destination | `navigate(lngLatToWorld(lon, lat, originFor(level), map), { stops, arrival })` |
| Cabin camera | `attention('ok' \| 'phone' \| 'eyesOff')` |
| "Hands on" button | `nudge()` |
| Summon / Autopark | `summon('forward' \| 'reverse' \| null)`, `autopark()` |
| FSD settings | `settings({ quirks, safety, speedOffsetMph, followDistance, laneChanges, nags })` |
| Voice note | `voiceNote(blob)` (done for you by `startVoiceNotes`; `useVoiceNote` has `recording` for a mic badge) |
| Wheel spring | `wheel({ strength: 0.6 })` |
| Settings → Wheel buttons | `learnButton(action)` then the user presses a button; `setButton(action, null)` clears; the map is in `useBeamNG(s => s.buttonMap)`, the last press in `s.lastButton`; `ACTIONS` (protocol) has the labels |
| Any wheel action from the UI | `action('toggleFSD' \| 'speedUp' \| ...)` |

**Map helpers** (`geo.ts`): `roadsGeoJSON`, `routeGeoJSON`, `trafficGeoJSON`,
`worldToLatLon` / `worldToLngLat` / `lngLatToWorld`, `worldToDriveView`. The
route message has `parkingPin` (the spot FSD picked) for the **P** pin.

**Events for the UI** (`useBeamNG(s => s.events)`, newest first; `detail` is a
short string, `data` has the fields): `engaged`, `disengage` (detail = reason),
`reengaged`, `arrived`, `laneChange`, `creeping`, `nudge`, `goAround`,
`emergencyVehicle`, `schoolBus`, `maneuver`, `summon`, `phantomBrake`,
`yellowHesitation`, `fcw`, `aeb`, `collisionEvasion`, `laneDeparture`,
`blindSpotWarning`, `obstacleAwareAccel`, `nag`, `strike`, `lockout`,
`voiceNote`, `voiceNoteSaved`, `settings`, `vehicleChanged`, `levelLoaded`,
`error`.

### Connecting the real app (for the UI session)

- WebSocket `ws://<pc-ip>:8765/?token=<token>`; types in `bridge/protocol.ts`.
- **Mixed content:** Safari blocks `ws://` from the https live app. Serve the
  built app from the relay: `npm run bridge -- --app ../dist`, then open
  `http://<pc-ip>:8765/app/?token=…`. The iPad mic (voice notes) and camera
  need a secure page on Safari, so for those use the PC's `localhost` page or
  an https tunnel to the relay.
- `--no-auth` turns the token off; the PC itself never needs it.

## FSD features

Modes: **FSD** (everything below), **Autosteer** (lane keeping + TACC),
**TACC** (cruise only, you steer). Profiles: Sloth, Chill, Standard, Hurry,
Mad Max (speed offset −2/0/+2/+5/+8 mph, gap, how eager it is to pass).

**Driving**
- **Lanes** from the road width (up to 4 per direction, 5 on one-ways);
  drives in the right lane, keeps lanes through turns.
- **Lane changes:** for the route (well before a turn), merges, passing slow
  cars (by profile), moving over for stopped emergency vehicles, Mad Max
  keep-left, returning right. Signals 1.2 s, checks the gap and the blind
  spot, then moves. The signal stalk asks for one.
- **Stop signs:** stops at the line, waits 2 s, **creeps for visibility**,
  peeks for cross traffic, goes. Sometimes a little go-stop-go.
- **Traffic lights:** stops for red; yellow: goes or stops by distance, with
  the occasional hesitation.
- **Unprotected lefts:** waits for a gap in oncoming traffic, keeps checking
  until it commits.
- **Nudging** around parked cars / bikes in the lane edge, and **going
  around** a stopped car when the other lane is clear.
- **Emergency vehicles** (lightbar on, or police/ambulance/fire cars):
  pulls over and stops for one coming up behind, yields at junctions, moves
  over for stopped ones.
- **School bus:** slower and more careful near a stopped one.
- **Speed limits** from the map (class defaults otherwise) + profile offset.
- **Accelerator** speeds it up and never disengages it; **brake** or
  **steering** takes over.
- **Accidental takeover:** a small wheel bump (under ≈110°) above 22.5 mph that
  settles back to FSD's line, with no pedals, turns FSD back on after ~1 s
  (`reengaged` event), at most once every 10 s.

**Parking and low speed**
- **Better spot choice + P pin:** picks a free parking spot near the
  destination and shows it; **backs in** to perpendicular spots.
- **Remembers your arrival choice** per destination.
- **Start from Park:** backs out of a spot when the road is behind you;
  **3-point turn** when the route goes the other way on a narrow road.
- **Dumb Summon:** ~12 m forward/back at walking pace, stops for obstacles.
- **Autopark** into the nearest free spot beside you.
- Maneuvers stop and hand back if they drift over 3 m off their path; the
  accelerator cancels them.

**Active safety (on even when you drive)**
- **FCW** (early 2.8 s / medium 2.2 s / late 1.6 s / off), **AEB**.
- **Automatic Collision Evasion:** if a crash is coming and braking alone
  won't do it, it takes over and **steers** into free space (checks the blind
  spot), then brakes.
- **Lane departure avoidance** (40–90 mph, no signal), stronger toward a car
  in the blind spot.
- **Blind spot** warnings; **obstacle-aware acceleration** (flooring it at a
  wall/car from a stop is limited).

**Supervision** (the cabin camera from the app + wheel nudges)
- Camera: looking away or on your phone for 2.5–5 s (by profile; phone is
  30% quicker) → **1** "Pay attention to the road" → **2** beeping →
  **3** "Take over immediately", 5 s each. No camera: a wheel nudge every
  20–45 s.
- Ignored at 3 → slows to a stop with hazards, FSD off, **strike**. 5 strikes
  → locked out for the drive (`resetStrikes` for testing).

**Quirks** (each can be turned off in settings): phantom braking (rare; more
likely under bridges), yellow-light hesitation, a little low-speed steering
wiggle after pulling away, slowing down in rain and fog.

**Voice notes:** the wheel button opens the iPad mic; the relay saves the
audio plus what the car was doing (position, speed, FSD state, last 30
events) in `bridge/feedback/`. Browse them at `http://localhost:8765/feedback`.

## Testing in the game (the acceptance list)

Try **a stock sedan, a pickup, a mod EV and a manual-transmission car**.

| Check | How |
|---|---|
| State at 20 Hz | Header shows `20 Hz`. |
| Every command | P/R/N/D, lights, signals, horn, doors, accelerator strip. |
| Multi-turn route | Click a destination, press **FSD**: right lane, signals + lane changes before turns, creeps at stop signs, stops for reds, follows traffic, parks (P pin) or pulls over, shifts to P. |
| App controls | The app's gear shifter, FSD switch, profile and map destination drive the game. |
| Wheel | Cockpit camera: the in-car wheel turns. G29: the physical wheel follows (card: wheel vs target, `method`). Grab it → `disengage: steer`. |
| Accidental bump | Above 25 mph, knock the wheel briefly and let go: `disengage` then `reengaged`. |
| Takeovers | Brake / keyboard / gamepad trigger → disengage. Gas → faster, stays on. |
| Attention | Test page *camera says: on phone* → nag 1→2→3 → stops with hazards, strike. |
| Safety | Drive at a stopped car yourself with FSD off: FCW, then AEB or an evasive swerve. Drift over a lane line at 45+ mph: it steers back. |
| Parking | Start in a parking spot facing it, destination behind you: it backs out. Try **Summon** and **Autopark**. |
| Emergency vehicle | Spawn a police car with lights on behind you (traffic): it pulls over. |
| Voice note | Press the bound button, talk, press again → `voiceNoteSaved`, file in `bridge/feedback/`. |
| Vehicles / level | Switch cars (FSD off, new car reports in ~2 s); reload the level (map re-sent). |

When something's off, send: the diagnostics output, what the car did, and the
console lines starting with `teslaBridge` / `teslaAutopilot`.

## How it works

- **Planner (GE, 10 Hz, `planner.lua`).** A* on the level's road graph,
  leg by leg through stops. Lane-shifted path with arcs at corners, speed caps
  (limit + offset, curvature, braking pass, stops). Each tick it looks at the
  traffic around the path (150 m behind to 300 m ahead) and decides lane
  changes, stops, creeping, gaps, nudges, emergency vehicles, quirks and
  supervision, then sends the car a **plan window**: points, speed caps, stop
  point, lead car, signal, direction (forward/reverse), hazards.
- **Safety (GE, 20 Hz, `safety.lua`).** Predicts our path (constant turn
  rate) against every car, gets time-to-collision, and raises FCW / AEB /
  evasion / lane departure / blind spot / throttle cap. Sent to the car as
  `assist` when active; evasion hands a sideways "bump" to the planner.
- **Driver (vehicle, every frame, `control.lua`).** Pure pursuit steering
  (look-ahead `clamp(2 + 0.7·v, 4, 30)` m, shorter in reverse), speed PI,
  self-calibrating steering sign and gain (only from steering it applied).
- **Inputs.** Everything goes through `input.event(…, FILTER_DIRECT, …,
  'teslaAP')`, the player's own path, so the wheel animates. The player's
  `local` source is switched off for what FSD controls. `input.event`,
  `kbdSteer`, `padAccelerateBrake` and `toggleEvent` are wrapped to see the
  player's own inputs (keyboard and gamepad skip `input.event`).
- **Takeover:** steering > 0.15 from where it was for 150 ms (without FFB),
  a wheel grip against the spring (with FFB), brake > 0.1 for 150 ms, or the
  app's strip below −0.1.
- **Gearbox:** arcade automatics switch to realistic while engaged (arcade
  reverses when you hold the brake at a stop), restored after.

## Known gaps / next steps

1. **FFB wheel:** both routes are tested only against simulated `hydros`. If
   the card says `unavailable`, send the diagnostics (`ffb` block) and use the
   helper meanwhile.
2. **Traffic lights / stop signs:** from `core_trafficSignals` and stop-sign
   props; if lights never go red, send diagnostics.
3. **Emergency vehicles:** detected by the `lightbar` electric (our beacon
   extension in nearby cars) or the car's name. Mod police cars with a
   different electric name only count by name.
4. **Weather:** read from the rain object and `core_environment` fog; if it
   never slows down in rain, send diagnostics.
5. **Raycasts** (walls for obstacle-aware acceleration, bridges for phantom
   braking) use `castRayStatic` if the game has it; otherwise those two only
   use cars.
6. **Parking spots** come from the level's parking objects; facing direction
   is best effort.
7. **Manual cars:** P = neutral + parking brake; they drive in arcade
   (auto-clutch).
8. **iPad mic/camera** need a secure page in Safari (see *Connecting the real
   app*).

## Protocol additions vs. the handoff

All in `bridge/protocol.ts`:
- modes `tacc`; disengage reasons `app`, `attention`, `summon`, `switch`
- `state.parkingbrake`, `state.wheel`, `state.safety`, `autopilot.accelOverride`,
  `activity`, `setSpeed`, `lane`, `creeping`, `waitingFor`, `goAround`,
  `emergencyVehicle`, `schoolBus`, `phantomBrake`, `weather`, `maneuver`, `nag`
- traffic `emergency` / `schoolBus`; `route` (+ `parkingPin`), `minimap`,
  `bridge`, `hello`, `debug`, `pong`; events with `data`
- commands `wheel` (spring, strength, helper), `settings`, `attention`,
  `nudge`, `summon`, `autopark`, `resetStrikes`, `voiceNote`,
  `requestMinimap`, `debug`, `ping`

`steeringWheelDeg` is positive when turned right. `PROTOCOL = 2`.

## Files

```
beamng/mod/                                   the mod (npm run mod zips it)
  scripts/tesla_bridge/modScript.lua
  lua/ge/extensions/teslaBridge.lua           TCP server, map/traffic/signals/weather, runs planner + safety, commands
  lua/vehicle/extensions/teslaAutopilot.lua   state, commands, input driving, takeover, FFB wheel, assists
  lua/vehicle/extensions/teslaBeacon.lua      nearby cars report emergency lights
  lua/common/teslaBridge/pathing.lua          A*, lanes, path geometry, speed profile
  lua/common/teslaBridge/planner.lua          FSD brain: lane changes, stops, creep, lefts, EVs, maneuvers, quirks
  lua/common/teslaBridge/safety.lua           FCW, AEB, evasion, LDA, blind spot, obstacle-aware
  lua/common/teslaBridge/nag.lua              attention, nags, strikes
  lua/common/teslaBridge/maneuver.lua         back out, 3-point turn, back-in parking
  lua/common/teslaBridge/control.lua          driver: pure pursuit + speed PI + self-calibration
  lua/common/teslaBridge/wheel.lua            FFB spring, grip detection, motor direction
  lua/ge/extensions/core/input/actions/teslaBridge.json   bindable wheel buttons
beamng/test/                                  test_*.lua (npm test), world.lua (sim), harness.lua (fake BeamNG),
                                              test_wheel_helper.py (npm run test:helper)
bridge/relay.ts          relay (npm run bridge)          bridge/protocol.ts    message types
bridge/test.html         test page at /                  bridge/e2e.ts         npm run e2e
bridge/app/              the app connector               bridge/wheel_helper.py/.bat  backup wheel helper
bridge/buildMod.ts       zips the mod                    bridge/feedback/      voice notes (git-ignored)
```

The harness and e2e need `luajit`, `lua-socket`, `lua-dkjson` (Debian/Ubuntu:
`apt install luajit lua-socket lua-dkjson`). Development only.
