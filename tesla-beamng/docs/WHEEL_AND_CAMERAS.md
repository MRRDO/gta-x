# Wheel feel and cameras

## Wheel feel (research + what was built)
Sources: EPS (electric power steering) control literature and patents found by search (self-aligning torque from the tyre model, speed-dependent assist, friction, damping and inertia compensation, active return), and Tesla's owner's manual (Controls > Dynamics > **Steering Weight**: Light / Standard / Heavy; older cars said Comfort / Standard / Sport). I could not test any of this on a real wheel.

What a real EPS wheel does, and what `common/teslaBridge/steerfeel.lua` does about each:
- **Self-aligning torque**: the wheel pulls back to centre, stiff near centre, levelling out with angle; heavier with speed and with cornering load. Built: stiffness `a/(a+0.18)`, scaled by speed and lateral acceleration.
- **Friction**: a steady drag against movement; tyre scrub is noticeable when parked. Built: Coulomb friction, stronger at parking speed.
- **Damping**: the wheel resists being flicked, more at speed. Built.
- **On-centre**: no knife-edge at zero; forces fade in over the first few degrees. Built.
- **Road texture**: a light buzz with speed and bumps from vertical acceleration (`roadFeel` 0..2, default 0 (off): it made the wheel shake; `wheel.roadTexture`).
- **Steering Weight** `steeringWeight: light | standard | heavy` scales all of it (0.75 / 1 / 1.35).

Where it applies: the bridge only drives the wheel's force feedback while FSD is driving, or when the game can't drive it (the "own" fallback). In those cases the fallback now uses this model once the wheel's direction is confirmed. **While you drive by hand, BeamNG's own force feedback is untouched** (it already models tyre forces); replacing it would need the bridge to compute real tyre forces, which it doesn't have, so I left it. If the game's own feel is what feels wrong, the fix is BeamNG's steering settings (force feedback strength, smoothing, a 900 degree lock in the wheel driver).
FSD's own steering motion has `steerFeel` (comfort / standard / sport): how early it steers and how quickly the wheel moves.

## Cameras
Views: `rear` (backup, in R), `front` (on request), `left` / `right` (side repeaters while signaling, setting `camera.side`). Everything is off by default; the D3D11 white flash from off-screen rendering is still unverified on the laptop.

Frame-rate protection, in `common/teslaBridge/camgov.lua` (tested):
- one screenshot at a time, round-robin between views, one reused named render view per camera (no new views per frame);
- low resolution (320x180) and 3 fps per view by default;
- never more than a sixth of the game's current fps in total;
- a governor watches the game's fps: under 30 for a second it halves the camera rate, again for a quarter, under 18 it pauses them; it only speeds up after 4 s of 45+ fps, and a paused camera retries after 8 s at a quarter rate. `state.camera` says which views stream and whether they're slowed or paused, and a notice event is sent on each change.
It can't measure the actual cost of a screenshot, only the resulting fps, so the first real test decides whether the defaults are low enough. If you still see dips, drop `camera.fps` to 1-2 or `quality: 'low'`.
