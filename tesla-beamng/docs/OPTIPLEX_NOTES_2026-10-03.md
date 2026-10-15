# Notes for the other (laptop) session, from the OptiPlex session, 2026-10-03/04

## Lua test failures (upstream, not caused by the OptiPlex changes)
Branch claude/review-feedback-gyfm2f at f47e05d, `luajit beamng/test/test_behaviors.lua` (LuaJIT 2.1 from winget DEVCOM.LuaJIT, Windows 10):
- `FAIL: parallel to the road, heading 11.7`
- `FAIL: comfort: gentle braking, no lurch (max 3.07 m/s^2)`
- `256 passed, 2 failed`. Same numbers on 4 runs in a row (deterministic, not the known flaky signal-light check).
- Same two failures with the unmodified upstream teslaAutopilot.lua, so they come from the merged laptop tuning (tamer Furious / maneuver clearance / planner ray fix), not from the OptiPlex gearbox change.
- All other suites pass: browse 31, assistant 8, voice 9, audio 16, localtls 6, driving 32, wheel 41, maneuver 12, score 11, lightshow 10, camgov 11, steerfeel 9 (counts approximate, see the run log).

## Bridge bugs found and fixed on the OptiPlex (branch optiplex-merge, 4 commits on top of f47e05d, NOT pushed: needs Quentin's GitHub sign-in)
- bridge/audio.ts: the `Device:` line in tesla-eq.txt used Windows' name with brackets ("Speakers / Headphones (Realtek Audio)") and never matched Equalizer APO's naming, so EQ was silently not applied. Now no Device line (APO only processes the ticked device) and an automatic headroom Preamp from the estimated peak (minus config.txt's own preamp), because stacked boosts reached +5.7 dB over full scale (clipping, then Waves' limiter ducked the volume).
- bridge/pcplayer.ts: player Chrome starts minimized with background-throttling flags.
- teslaAutopilot.lua: always forces the realistic gearbox.
- Kit script note: Install-VoiceAudio.ps1 asks GitHub for the "latest" whisper.cpp release, which currently has no Windows files attached (v1.9.4); it should take the newest release that has `whisper-bin-x64.zip` (b5130 worked). It also never sets TESLA_LLM_MODEL (bridge default is llama3.2:1b) and Ollama must be CPU-only: with the Radeon's Vulkan backend (Ollama default here) llama3.2:3b produced garbage; set OLLAMA_VULKAN=0.
- Windows: programs started from the Claude app inherit a virtualised AppData (BeamNG shader cache and settings broke). Use a scheduled-task launcher (scripts\Run-Outside.ps1).

## Wheel
- The G29 flips between PC mode (046D:C24F, BeamNG ships a map) and PS4 mode (046D:C260, no BeamNG map, and Windows shows a driver Error) after being moved/replugged. At the time of writing it is in PS4 mode again (status Error), so the wheel helper finds no controller.
- Measured on the OptiPlex (West Coast USA, D-Series pickup, 1280x720 low, FSD driving): Intel and Radeon are both near the 60 FPS cap in places but the user sees about 13 FPS at times; the bridge's `fps` field disagrees with the on-screen counter, so PresentMon is the reference. Low FPS is the likely cause of the wheel shake, which f47e05d's frame-rate compensation addresses (needs verifying on the real wheel).

## Needs Quentin
- Push the branch (sign in to GitHub), restore the 15 laptop mods from the private release, re-copy two truncated zips on the USB (`24Model3_xNME_v2.5 2.zip`, `Tesla Model S_modland.zip`: both start correctly but have no end-of-archive record).
