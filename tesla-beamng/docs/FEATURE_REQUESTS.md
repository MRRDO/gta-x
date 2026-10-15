# Feature wishlist for the Tesla bridge / car mode (from Quentin, 2026-10-03)

Where this goes: the GitHub repo (MRRDO/gta-x, branch claude/review-feedback-gyfm2f, folder tesla-beamng/docs/) and the hub.
Nothing here is built yet. A copy is in C:\gta-x-clone\tesla-beamng\docs\FEATURE_REQUESTS.md, ready to commit when Quentin signs in to GitHub.

## 1. iPad screen keeps turning off
- Problem: the iPad locks its screen while the Tesla app is open.
- Ideas, easiest first:
  1. Quick fix, no code: iPad Settings > Display & Brightness > Auto-Lock > Never (turn back on after driving).
  2. In the app: request a Screen Wake Lock (navigator.wakeLock) while connected. Works for the installed Home Screen app on recent iPadOS; has to be re-requested after the app returns to the foreground. Needs a change in the app (hub repo tesla-ui-atv).
  3. Fallback: a silent looping video element (the old "no-sleep" trick) if Wake Lock is not available.
- Needs a real iPad to verify: not testable from the PC.

## 2. Faster BeamNG start
- Facts so far: first launch spent about 15 minutes compiling shaders (now cached); with the cache, loading West Coast USA on this PC takes about 90 seconds on the Radeon, the Intel chip is slower.
- Ideas: start the game and load the level in one step (the -level launch argument failed: "No entry point for level found", the right path format is still unknown), keep the shader cache folder, add the BeamNG folder to Defender exclusions (Windows-Tune step 6), disable unused mods and launcher splash, keep the game on the SSD (it is), and consider a smaller test map for quick checks.
- Measure first: time from clicking the desktop icon to a drivable car, for each change.

## 3. Sign in to a Tesla account to pull data
- Goal: show real data from Quentin's Tesla in the app.
- Must use Tesla's official sign-in (OAuth through Tesla's own page, with the Fleet API); Quentin signs in themselves, the bridge never sees or stores the password, only the token Tesla issues, kept in a git-ignored file.
- Open questions: which data (battery, location, charging, climate), whether to use the official Fleet API (needs a developer app and a key) or a third-party service, and read-only vs commands. Read-only first.

## Noted, not to be fixed yet
- Alt-tabbing into BeamNG makes the screen flash black (likely the game switching the display resolution in exclusive fullscreen). Quentin asked to leave it for now.

## 4. Wheel shaking is back (reported 2026-10-03)
- The G29 shakes / oscillates in the game (force feedback). It had been fixed once, then returned.
- To check: the wheel mode (the PC mode C24F vs the PS4 mode C260 changed the game's bindings), G HUB force settings vs BeamNG's own force coefficient/smoothing in the G29 map (forceCoef 300, smoothing 150), and whether the mod's wheel control (wheel.lua / steerfeel.lua) fights the game's force feedback.

## 5. Wheel is not accurate, turns in random ways (reported 2026-10-03)
- The wheel and the car do not agree: the car steers in unexpected ways. Possibly related to item 4.
- To check: steering angle (900 degrees in the G29 map vs G HUB's setting), G HUB profile still active, leftover bindings, and whether FSD (steering takeover) is engaged.

## 6. Done on 2026-10-03 (for the record)
- FSD mod now keeps the gearbox on "realistic" at all times (never arcade).
- Apple Music player window starts minimized (takes effect the next time the bridge launches it).

## 7. Requirements to add (Quentin, 2026-10-03)
- **Car mods from the laptop**: Quentin's own BeamNG car mods (vehicle zips from the laptop's BeamNG user folder, mods\ and mods\unpacked) are not in this repo and are not on the OptiPlex yet. They need to be collected (list names + versions), copied to the OptiPlex, and checked in the game. BeamNG online features are currently OFF on the OptiPlex (privacy default), so repository-subscribed mods will not sync until Quentin turns them on and signs in to their BeamNG account themselves.
- **Backup of the whole BeamNG user folder** (laptop: %LOCALAPPDATA%\BeamNG\BeamNG.drive\current, including settings, inputmaps, mods, screenshots, saves) is a requirement: make one backup before any change, keep it off the laptop (USB / OneDrive), and restore from it on the OptiPlex. The OptiPlex kit currently only carries settings.json, game-settings.json, postfx and the G29 inputmap.
- The wheel problems (items 4 and 5) are known to the project: shaking and inaccurate steering.

## 8. Faster BeamNG start: findings (2026-10-03, prepared, not yet timed)
- BeamNG's own command-line argument is `-level <level folder name>` with no path (from lua/ge/client/parseArgs.lua), e.g. `-level west_coast_usa`. Earlier attempts used a full path and were ignored. `-vehicle` and `-vehicleConfig` also exist.
- Added desktop launchers "BeamNG QUICK (Intel)" and "BeamNG QUICK (Radeon)" (C:\car-mode-tools\BeamNG-Quick.ps1): start the game straight into West Coast USA, skipping the main menu, level picker and vehicle picker. NOT TESTED yet (the game was in use). To measure: time from double-click to a drivable car, versus the normal icon plus menus.
- Not done: Defender exclusion for the BeamNG folders (needs an admin prompt), keeping the shader cache (it persists now), trimming unused mods.

## 9. App UI: audio screen should match what the bridge now does (Quentin asked to track this, 2026-10-03)
- The audio backend changed on the OptiPlex (no `Device:` line, automatic headroom Preamp, see commit "Audio EQ: drop the Device line ...") but the app's Settings > Controls > Audio screen was NOT changed. It still works because the /audio and /audio/eq calls are unchanged, but:
  - The app cannot show the current EQ or the automatic headroom: the relay only has POST /audio/eq. Add GET /audio/eq (bands + the preamp the bridge wrote + the peak estimate) and show it.
  - Warn in the UI when the boosts sum above 0 dB without headroom, and show "headroom: -X dB".
  - Presets for the sliders, e.g. a Latin-style curve (strong lows, mid scoop, bright top) and a "clean punch" curve (bass without the 180 to 350 Hz mud) as tuned on the OptiPlex.
  - Detect and explain the Dell/Waves MaxxAudio effects that colour the sound (its own equalizer and the "Speaker Size: Small" bass cut hid the bass for hours).
  - Show which device is the music output and whether Equalizer APO is installed on it.
- The UI lives in the private hub repo (tesla-ui-atv), so this needs Quentin to hand it over; nothing was changed there.

## 10. Using two GPUs (2026-10-03)
- The OptiPlex now has two identical Radeon R5 340X cards (one in the x16 slot, one at x8) plus the Intel HD 530. BeamNG renders on one adapter only (no multi-GPU support), so the second card does not add frames. A useful use of a Radeon is to give it the monitor (render and display on the same card), which avoids the Radeon-to-Intel copy.

## 11. In-game updates from the app (note from Quentin, 2026-10-03, quoted)
> "let's also make a way to update in game so i don't have to restart every time. maybe when u push an update it'll show on the screen, i tap it, then it updates the bridge and car and stuff. i'll have it push the stuff somehow. i'll have it serve as an artifact. it made a thing so i can play music thru the optiplex on a separate output than the tv and also made it so AM runs on the optiplex but shows the ui on the ipad."
- Wanted: an update prompt on the iPad screen when a new version is available; one tap updates the bridge, the BeamNG mod and the car-side pieces without restarting by hand.
- Ideas: the relay checks a version file (for example a release or a manifest) and tells the app; the app shows a banner; the tap calls a relay endpoint that pulls the update, rebuilds the mod zip (npm run mod), copies it into the BeamNG mods folder, and restarts the relay and tunnel. The game itself still has to reload the mod (Ctrl+L reloads Lua in BeamNG; a full game restart is not always needed). Updates must be signed or come from a repo Quentin controls, and the relay must never run code from an unauthenticated source. The pairing token already protects the relay's endpoints.
- Quentin will arrange how updates are pushed (they said the package is served as an artifact).
- Already working today (what the note refers to): music plays from the OptiPlex on its own output (the 3.5 mm jack) separate from the TV, and Apple Music runs on the OptiPlex while its controls show on the iPad.
