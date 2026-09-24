# BeamNG ⇄ Tesla UI bridge

The iPad app shows and drives a car in **BeamNG.drive**. There are three parts:

```
BeamNG.drive (PC)                         relay (PC, Node)                 iPad
┌──────────────────────────────┐  TCP     ┌─────────────────────┐  Wi-Fi  ┌──────────────┐
│ teslaBridge   (GE extension) │◀───────▶│ bridge/relay.ts      │◀──────▶│ Tesla UI app │
│  map, traffic, signals,      │ 127.0.0.1│  ws + http :8765     │   ws   │  or test page│
│  route planner (10 Hz)       │   :8766  │  test page, minimap  │        └──────────────┘
│ teslaAutopilot (vehicle ext) │          │  pairing token, QR   │
│  state 20 Hz, commands,      │          └─────────────────────┘
│  driving via player inputs   │
└──────────────────────────────┘
```

## Status

**Built without the game.** Everything here was written and tested in a
cloud container against a fake BeamNG (`beamng/test/harness.lua`). The
harness runs the real mod Lua with stubbed game APIs, a simple car model and
a simulated G29 (motor, gear friction, the game's own centering force),
talking to the real relay.

- Unit tests: 29 driving + 14 wheel, all passing.
- End-to-end: 38/38, also with a backwards motor, backwards car steering,
  and no wheel.

The API names come from the game's docs and from BeamMP's source (BeamMP is
a multiplayer mod built for BeamNG 0.39). The parts I'm least sure of are
wrapped so a mismatch turns off that one feature instead of crashing the
mod, and the **Diagnostics** button reports what your game version exposes.
Expect a round or two of fixes after the first real run.

## Setup (Quentin)

You need Node 20+ on the PC. The PC and the iPad must be on the same Wi-Fi.

1. **Install:** in this folder, run `npm install`.
2. **Build the mod:** run `npm run mod`. This writes `beamng/dist/tesla_bridge.zip`.
3. **Install the mod:** copy the zip into the BeamNG user folder's `mods/`
   folder. To find it: BeamNG launcher → *Manage User Folder* → *Open in
   Explorer*. Usually it's `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods`.
   Don't unzip it.
4. **Start the game:** load **West Coast USA** and spawn any car. Open the
   console with the `~` key. You should see `teslaBridge: listening on
   127.0.0.1:8766`, then `map west_coast_usa: … nodes`.
5. **Start the relay:** run `npm run bridge`. It prints the addresses, a
   pairing token and a QR code. If Windows Firewall asks, allow Node on
   **private** networks.
6. **Test page:** open `http://localhost:8765/` on the PC, or scan the QR
   code with the iPad. The QR link includes the `?token=`, which the iPad
   needs. The token is saved in `bridge/.token`; delete that file to get a
   new one.
7. **First thing:** click **Run diagnostics** → **Copy**, and send me the
   output. It shows what this BeamNG version's Lua has: input functions,
   gearbox type, door controllers, traffic-signal API, map link fields, and
   the force-feedback code.

### Logitech G29 (or any force-feedback wheel)

While the autopilot drives, the mod takes over the wheel's force-feedback
motor and pulls the physical wheel to the car's steering angle. When it
disengages, the game's normal force feedback comes back.

1. **Logitech G HUB** (or Logitech Gaming Software):
   - Operating range: **900°**.
   - **Turn off the centering spring** ("Use Special Centering Spring" /
     centering spring in FFB games). It fights the autopilot.
   - Force-feedback strength: 100%.
2. **BeamNG → Options → Controls:**
   - Use the default G29 profile, with force feedback **on** for steering.
   - Leave the steering lock at 1:1. If you change it, the mod learns the
     wheel-to-car ratio from your own driving before you engage.
   - Keep the pedals on separate axes (the G29 default). A brake-pedal
     takeover needs a real brake axis.
3. **Bind a wheel button to FSD** (optional): Options → Controls → Bindings →
   **Tesla UI Bridge** → *Toggle FSD* (and *Toggle Autosteer*). One press
   engages, the next disengages, like the stalk.
4. **Strength:** the test page's *Steering wheel* card has an on/off toggle
   and a strength slider (default 60% of the wheel's max force). The force
   ramps up over 0.8 s when you engage.
5. **Taking over:** turn the wheel against the autopilot (hold it more than
   about 45° away from where it's pulling for 0.35 s). It disengages with
   `steer: wheel grabbed` and hands the motor back. Resting your hands on it
   while it turns is fine.
6. **First turn of a session:** if the motor pushes the wrong way (some
   drivers or settings invert it), the mod notices within about 0.1 s,
   flips, and remembers the direction. The test page shows `calibrated`
   once it's proven.

How it works: the game's `hydros.lua` owns the wheel motor and keeps the
device id in a local called `FFBID`. The mod finds it with
`debug.getupvalue`, sets it to −1 while engaged (so the game stops sending
forces), and drives the motor itself with `obj:sendForceFeedback(id,
force)`. That's a position spring with damping, `force = Kp·(target − wheel)
− Kd·speed`, capped at 60% of the device max. On disengage it sends 0 and
gives the id back. This matches the game's `hydros.lua` as of the last
public copy (2020). If a newer version renamed things, the wheel card says
`unavailable` with the reason, the diagnostics list `hydros`' contents, and
the autopilot still drives (the wheel just doesn't move).

### Wiring the app

`bridge/app/` is the app-side connector. Copy it and `bridge/protocol.ts`
into the app. They need only React + zustand, which the app already has.

```ts
import { connectBeamNG, disconnectBeamNG, syncBeamNGToApp, useBeamNG, bridge, MPS_TO_MPH } from './bridge/app'
import { useVehicleStore } from '@/store'
import { useSimStore } from '@/sim/drive'
import { useNavStore } from '@/nav/store'

// "Vehicle source: BeamNG" turned on (stop useDriveSim first so it doesn't fight):
connectBeamNG('ws://192.168.1.20:8765/?token=ab12cd34') // or connectBeamNG() to use ?bridge= / the relay host / the saved URL
const stopSync = syncBeamNGToApp({ vehicle: useVehicleStore, sim: useSimStore, nav: useNavStore })
// turned off:
stopSync(); disconnectBeamNG()
```

**What `syncBeamNGToApp` does:**
- **Game → app, 20 Hz:**
  - vehicle store: gear, `speedMph`, doors FL/FR/RL/RR, frunk/trunk, `chargePercent`, headlights/fog
  - sim store: `heading`, `signal`, `control`, `lead`, `fsd`, `autopilot`
  - nav store: `position [lat, lon]`, `heading`, `route.coords`
- **App → game:** when the existing UI changes gear, doors, frunk, trunk,
  headlights or fog in the vehicle store, the command goes to the game, and
  the game's state then confirms it.
- **Field names** follow the handoff. If the app names something
  differently, edit the three small functions at the top of `appSync.ts`.
  Fields a store doesn't have are skipped.

**Other controls** go through the client, for example
`bridge()?.autopilot('fsd', 'standard')`:

| UI control | Client call |
|---|---|
| FSD button | `autopilot('fsd', profile)` |
| Autopilot off | `autopilot('off')` |
| Turn signal stalk | `setSignal('left')` |
| Horn | `horn(true)` / `horn(false)` |
| Accelerator strip | `holdThrottle(v)` while held, `releaseThrottle()` on release. With FSD on it speeds up and stays engaged. |
| Nav destination | `navigate(lngLatToWorld(lon, lat, originFor(level), map))` |
| Cancel route | `cancelRoute()` |
| Wheel spring | `wheel({ strength: 0.6 })` |

**For the map** (`geo.ts`):
- `roadsGeoJSON(map)`, `routeGeoJSON(route)` and `trafficGeoJSON(cars)` give
  MapLibre sources.
- `worldToLatLon`, `worldToLngLat` and `lngLatToWorld` convert coordinates.
  Each level is pinned near a real place (West Coast USA sits by the Bay
  Area), so the map tiles look plausible.
- `worldToDriveView` converts to the driving view's `(X = −east, Z = north)`
  meters.

**Reading state in components:**
`useBeamNG((s) => s.state?.autopilot.nextTurn)` and similar. Pick small
slices, because the store updates at 20 Hz.

`npm run e2e` also runs `bridge/app/selftest.ts`, which hooks this connector
to stand-in copies of the app's stores and drives the fake game through it
(19 checks).

### Connecting the real app (for the UI session)

- WebSocket: `ws://<pc-ip>:8765/?token=<token>`. Message types are in
  `bridge/protocol.ts`.
- **Mixed content:** the live app is served over `https://…workers.dev`, and
  Safari blocks `ws://` from an https page. The fix is to have the relay
  serve the built app over plain http on the LAN:
  `npm run bridge -- --app ../dist`, then open
  `http://<pc-ip>:8765/app/?token=…` on the iPad. Service workers won't
  register over http, but the app still runs.
- `--no-auth` turns the token check off. Connections from the PC itself
  never need the token.

## Testing in the game (the acceptance list)

Try **a stock sedan, a pickup, a mod EV and a manual-transmission car**.

| Check | How |
|---|---|
| State at 20 Hz | The test page header shows `20 Hz`, and the relay prints the rate every 5 s. |
| Every command | Use the P/R/N/D, lights, signal, horn and door buttons, plus the accelerator strip (hold it). |
| Multi-turn route | Click a destination a few blocks away on the map, then press **FSD**. It should stay in the right lane, slow for curves and turns, signal about 60 m before turns, stop at stop signs (2 s) and red lights, follow traffic, then pull over or park and shift to P. |
| Wheel turns in the car | Use the cockpit camera while FSD drives. The test page wheel icon shows the same angle. |
| Takeover | While engaged, steer or brake. It disengages within about 0.15 s and the page logs `disengage: steer/brake`. Pressing the gas instead speeds it up and it stays on. |
| Switching vehicles, reloading the level | Switch cars (autopilot turns off, the new car reports within about 2 s). Reload the level (the map is re-exported, and the log shows `map …`). |
| FFB wheel (G29) | Engage FSD: the physical wheel should turn with the car through every turn (the wheel card shows wheel vs target). Turn it hard against the autopilot: it disengages with `steer: wheel grabbed`. |
| Wheel button | Bind *Toggle FSD* to a G29 button, then press it once to engage and again to disengage. |

When something's off, send me: the diagnostics output, what the car did,
and the BeamNG console lines that start with `teslaBridge` or
`teslaAutopilot`.

## How the autopilot works

- **Planning (GE, 10 Hz).** A* on the level's road graph (`map.getMap()`).
  It respects one-way roads, avoids undrivable links and U-turns, and routes
  leg by leg through `stops`. The centerline gets arcs at corners, is offset
  into the right lane (`min(radius/2, 1.8 m)`, centered on one-way roads, and
  blended over about 24 m where the road type changes), then resampled every
  2 m. Speed caps per point come from:
  - the posted limit or a class default (25/35/45/65 mph by road width) plus
    the profile offset
  - `sqrt(a_lat / curvature)`
  - a 2.5 m/s² braking pass backwards along the path
  - 3 m/s over the last 40 m before arrival

  With no destination, FSD and autosteer follow the straightest road ahead,
  and the path is re-extended as the car drives.
- **Every 0.1 s the GE sends the car a 300 m window.** The window has the
  lane points, the speed caps, the next stop point (a stop sign not yet
  served, a red light, or a yellow it can stop for), the car ahead in our
  lane (or a crossing or oncoming car, treated as stopped), and the turn
  signal to show.
- **Driving (vehicle, every frame).**
  - *Steering:* pure pursuit, look-ahead `clamp(2 + 0.7·v, 4, 30)` m. This is
    shorter than the handoff's `4 + 0.9·v`, because the simulator cut
    corners by about 2 m with the longer one. Plus a small lane-centering
    integral, rate-limited to 1.5 full locks per second (3 below 6 m/s).
  - *Self-calibrating:* it measures how much the car actually turns per
    unit of steering input, per speed band. If the car turns the wrong way
    for 0.4 s, it flips the steering sign. So it needs no per-car wheelbase
    or steering-angle data.
  - *Speed:* a PI loop to throttle or brake, never both. Throttle is capped
    at 0.6 (0.9 on Mad Max) and brake at 0.8. It follows lead cars with a
    time gap (3 s Sloth … 1.2 s Mad Max, 6 m minimum) and brakes to a stop
    2 m before the stop line.
  - *Inputs:* everything goes through `input.event(..., FILTER_DIRECT, …,
    'teslaAP')`, the same path the player's controller uses, so the steering
    wheel animates. While FSD is engaged, the player's `local` source is
    turned off for steering, throttle, brake and parking brake. In autosteer,
    only steering is turned off.
  - *Gearbox:* automatics in *arcade* mode switch to *realistic* while
    engaged, because arcade mode shifts into reverse when you hold the brake
    at a stop. The same trick BeamMP uses. The setting is restored on
    disengage.
- **Takeover.** `input.event` is wrapped to record the player's own events
  (source `local`) separately from ours. Only events after engaging count.
  - Steering moves more than 0.15 from where it was when you engaged, for
    150 ms. For a wheel, that means you turned it.
  - Brake over 0.1, for 150 ms.
  - The app's accelerator strip below −0.1 counts as braking.
  - The **accelerator doesn't disengage** (like a Tesla). Your pedal or the
    app's strip makes the car go faster while held and never brakes (the
    state shows `accelOverride`). Let go and it eases back to the set
    speed.
- **Arrival.**
  - *Parking Lot*, *Parking Garage* or unset, with a parking spot within
    60 m: it curves into the spot.
  - *Street*, *Curbside* (or no spot nearby): it pulls toward the right edge
    over the last 30 m with the right signal on.
  - *Driveway*: it stops on the point.

  Then it shifts to P, disengages with `arrived`, and sends an `arrived`
  event.

## Known gaps / next steps

1. **Force-feedback wheel:** built against the last public copy of
   `hydros.lua` (2020), then tested with a simulated G29 in the harness:
   - normal
   - a backwards motor
   - backwards car steering
   - no wheel at all

   The first real-game run confirms the rest. If the wheel card says
   `unavailable`, send the diagnostics (the `ffb` block).
2. **Traffic lights:** the probe tries `core_trafficSignals`
   `getSignalsDict/getSignals/getValues` and reads states by name
   (red/yellow/green). If the page shows `signals: 0` or lights never go
   red, send me the diagnostics.
3. **Stop signs:** these come from the signal system and from level props
   whose shape name has `stop_sign` in it. At 4-way stops it can stop a
   second time for the cross street's sign; later signs within 25 m after a
   stop are ignored to limit that.
4. **Cross traffic at junctions** is only handled when a crossing car is in
   our lane. There are no lane changes.
5. **Parking spots:** read from `gameplay_parking` or `BeamNGParking`
   objects. The spot's facing direction is best-effort.
6. **Minimap image:** read from the level's `info.json`. Its placement on
   the test map is a guess, so toggle it off if it doesn't line up.
7. **Manual cars:** P = neutral + parking brake. They drive in arcade
   gearbox mode (auto-clutch), and stops hold with the brake plus the
   parking brake.

## Protocol additions vs. the handoff

All of these are in `bridge/protocol.ts`:

- `state.parkingbrake`, `state.wheel` (force-feedback wheel status),
  `autopilot.accelOverride`
- command `wheel` (spring on/off, strength)
- `route` (the planned path, for the nav map)
- `minimap` (image URL on the relay)
- `bridge` (relay ⇄ game link status)
- `hello`, `debug`, `pong`
- commands `requestMinimap`, `debug`, `ping`
- disengage reason `app`
- event kind `error`

`steeringWheelDeg` is positive when turned right.

## Files

```
beamng/mod/                         the mod (npm run mod zips it)
  scripts/tesla_bridge/modScript.lua
  lua/ge/extensions/teslaBridge.lua      TCP server, map/traffic/signals, planner, commands
  lua/vehicle/extensions/teslaAutopilot.lua  state, commands, input driving, takeover
  lua/common/teslaBridge/pathing.lua     A*, lane path geometry, speed profile (pure Lua)
  lua/common/teslaBridge/control.lua     the driver: pure pursuit + speed PI + self-calibration
  lua/common/teslaBridge/wheel.lua       force-feedback wheel spring, grip detection, motor-direction learning
  lua/ge/extensions/core/input/actions/teslaBridge.json   bindable "Toggle FSD / Autosteer" controls
beamng/test/test_driving.lua        unit + closed-loop tests      (npm test, needs luajit)
beamng/test/test_wheel.lua          wheel spring vs a G29 model   (npm test)
beamng/test/harness.lua             fake BeamNG                   (npm run harness)
bridge/relay.ts                     relay                         (npm run bridge)
bridge/protocol.ts                  message types for the app
bridge/test.html                    test page served at /
bridge/e2e.ts                       harness + relay + fake app    (npm run e2e)
bridge/buildMod.ts                  zips the mod
```

The harness and e2e test need `luajit`, `lua-socket` and `lua-dkjson` (on
Debian/Ubuntu: `apt install luajit lua-socket lua-dkjson`). They're for
development; you don't need them to play.
