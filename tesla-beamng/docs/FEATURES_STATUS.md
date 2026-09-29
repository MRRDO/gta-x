# Feature status (Quentin's picks, 2026-09-29)

Legend: **done+sim** = built and covered by the simulator tests (`npm test`, `npm run e2e`); **done, unverified** = built but depends on BeamNG behavior the simulator can't check, needs the laptop retest (issue #14 on MRRDO/tesla-ui-atv); **app** = the app session (issue #13); **not done** = not built, with the reason.

| Pick | What | Status |
|---|---|---|
| 2 | Navigate on Autopilot: keeps right, passes on the left, hurry/Max/furious live in the fast lane at speed | done+sim (lane rules, passing, merges, moving over, route lane prep). Highway exit/interchange signage is not read; it follows the planned route |
| 3 | Lane change suggestions and moving over for merging traffic | partly: FSD changes lanes by itself and moves over for emergency vehicles; there is no on-screen "suggest and confirm" prompt (app) |
| 4 | Speed limit sign reading | **not done**: BeamNG signs aren't exposed; the road's speed limit from the map is used (state.speedLimit) |
| 5 | Emergency Lane Departure Avoidance | done+sim (existed: steers back from the road edge, `laneDeparture` emergency events) |
| 6 | Rear Cross Traffic Alert + reverse braking | done+sim (`safety.rearWarn`, event `rearCrossTraffic`, brakes) |
| 8 | Front and side cameras | done, unverified: front (on request) and side repeaters (on signal, `camera.side`), one screenshot at a time with an fps governor (docs/WHEEL_AND_CAMERAS.md). The D3D11 flash is still unverified; all cameras are off by default |
| 10 | Traction modes, Slip Start, Track, Launch, Drift | **not done** except `accelMode: 'sport'` and the furious profile (see below). BeamNG's traction control is per-car and has no common API |
| 12 | Vehicle Hold with parking brake on slopes | done, unverified: `hillHold` brakes when stopped on a slope; stopping mode `hold` existed |
| Wheel | Light turn nudges FSD, firm turn takes over | done+sim (`takeover: light|normal|firm`), feel needs the G29 |
| Steering | Feels like a real Tesla + steering/accel settings | done+sim (`steerFeel`, `accelMode`), which one feels right needs the G29 |
| Regen | Mods with their own regen | done, unverified: detects regen keys on the car's motors/electrics and stands down |
| 15, 17 | Valet Mode, PIN to Drive | done+sim on the game side (`valet`, `pinLock`); the screens and the PIN check are the app's |
| 20 | Bioweapon / Dog / Camp / Keep Climate On | app (screens); `climate` command stores and echoes settings |
| 21 | Climate foundation | done: `{t:'climate'}` stored and echoed in `state.climate`; nothing in the game reacts |
| 22 | Auto wipers | done, unverified: tries the wiper controls a car exposes; debug shows `wiperKeys`. Auto-dimming mirrors: **not done** (no game API) |
| 24 | Mirrors tilt in reverse / auto fold | **not done** (no game API) |
| 26 | Adaptive headlights, welcome/goodbye animations | welcome/goodbye done+sim (light shows); headlights that swivel: **not done** (BeamNG lights can't) |
| 31 | OTA update screen | app |
| 34 | Real Tesla light shows, retire the old ones | done+sim as choreographed shows (welcome, goodbye, holiday, strobe) with lights, fog and blinkers only. They are not the real Tesla shows (those move windows and mirrors and use licensed music). The app should retire its old ones |
| 35 | Themes by model / time of day | app |
| N1 | Green-light chime | already existed (Quentin said we have it) |
| N2 | Hazards on hard braking | done+sim |
| N3 | Slow for curves | already existed; **speed bumps and school zones: not done** (no bump data, only the map's speed limit) |
| N4 | Roundabouts | **not done**: BeamNG's road graph has no roundabout concept; curve speed limits apply |
| N5 | Passing on two-lane roads | passing exists for same-direction lanes; it never uses the oncoming lane on purpose |
| N6 | Follow distance 1 to 7 + red dial cycling | done+sim (dial: volume, follow distance, speed, profile) |
| N7 | Weather-aware driving + "FSD degraded" | done+sim |
| N8 | Trip summary + Safety Score | done+sim |
| N9 | Road feel in the wheel (heavy) | done, unverified (`roadFeel` 0..2 while FSD holds the wheel; while you drive, the game's own force feedback is untouched) |
| N11 | UI sounds, wind sounds | app |
| Max | Hold Max = cuts in and speeds; Furious in service mode | profile `furious`: done+sim (cut-ins, tailgating, +15 mph, hard braking, no rolling through reds). **Drifting and stunts: not done** (need real-car tuning in the game) |
| Later | Voice commands, Model X/S HUD | noted, not started |
