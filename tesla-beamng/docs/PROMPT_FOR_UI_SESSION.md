# Prompt for the UI session (hub repo MRRDO/tesla-ui-atv): audio screen + PC music

You are the UI session for the Tesla iPad app (hub repo MRRDO/tesla-ui-atv). Follow the hub's AGENTS.md (read it and the top of CHANGELOG.md first, check issues for session:any / session:bridge-dev, comment on issue #18 when done, add a CHANGELOG line, no emojis in the app UI, never touch credentials, never play audio while testing without asking). Quentin (they/them) is a teen who likes casual talk; be concise and say what you did and did NOT verify.

## Context (what changed on the bridge side, done by the OptiPlex session, branch claude/review-feedback-gyfm2f of MRRDO/gta-x, folder tesla-beamng/)
The OptiPlex (Windows 10) runs the relay (bridge/relay.ts). Audio goes: game sound = Windows default device (the TV over HDMI), music = the back 3.5 mm jack. The relay writes the music EQ into Equalizer APO's `tesla-eq.txt`. Problems found in real use that the UI should now help with:
1. The EQ stacked boosts and clipped (+5.7 dB over full scale), then the sound card's limiter ducked the whole volume ("gets quieter when the bass hits"). The bridge now writes an automatic headroom `Preamp` (estimate of the summed filter peak, minus the preamp already in config.txt). The UI cannot see this.
2. A `Device:` line with the Windows name (with brackets) never matched Equalizer APO, so the EQ was silently not applied. The bridge no longer writes a Device line.
3. Dell/Waves MaxxAudio on the 3.5 mm output had its own equalizer on (+6 dB on 31 to 250 Hz) and "Speaker Size: Small", which cut the deep bass. Nothing in the UI tells the user this can happen.
4. The PC Apple Music player (Chrome window with its own profile, DevTools port 9223) answers 502 "Apple Music is not signed in / not loaded yet" until Quentin signs in inside THAT window; the UI shows no helpful message.

## What to build in the app
A. Audio screen (Settings > Controls > Audio > PC outputs):
 - Show the current music EQ: bands (freq, type lowshelf/peaking/highshelf, gain), the automatic headroom preamp in dB, and the estimated peak. Uses `GET /audio/eq` (already on the relay, commit 08d8580; response `{ ok, bands:[{freq,type,gain}], preampDb, peakDb, apoInstalled }`; if it returns 404 or an error, degrade gracefully and hide the readout; check the real response in bridge/relay.ts and bridge/audio.ts first).
 - Warn when the summed boosts leave less than about 1 dB headroom, and show "headroom: -X dB" next to the sliders. Do not clip silently.
 - Presets for the sliders (send them through the existing `POST /audio/eq {bands:[...]}`): "Latin" (low shelf 50 Hz +5, peaking 90 +3, 125 +3, 180 +2.5, 250 +3, 500 -1, 1k -1, 3.5k +1.5, high shelf 9k +3.5; approximation of Apple's Latin preset) and "Clean punch" (low shelf 45 +4, 65 +4, 100 +2.5, 140 +1.5, 250 +2, 350 -2, 600 -1, 1k -1, 3.5k +1.5, high shelf 9k +3.5), plus Flat. Max 10 bands per request.
 - The bass slider already maps to the low shelf; keep it, but make sure moving it rewrites the file through the same call so the headroom is recomputed.
 - A small "Sound doctor" note: a static tip card explaining Waves MaxxAudio can add its own EQ and a bass cut ("Speaker Size: Small") on the 3.5 mm output, and how to check it (Dell Audio app > Speaker / Headphone). If you want live detection, ask the OptiPlex session to add it to the bridge; do not guess.
 - Show which device is Game and which is Music (already in `GET /audio`) and the per-device volume. check bridge/relay.ts for the volumes the relay now returns (`POST /audio/volume {target:'game'|'music', value:0..1}` exists).
B. PC music (Apple Music on the PC, `GET /pc/status`, `POST /pc/play {id}`, `POST /pc/control {action,value}`):
 - States to show: PC player not available (no Chrome), "sign in on the PC": status returns 502 with `{error:"Apple Music is not signed in / not loaded yet"}` (tell the user to sign in in the player window on the PC; the player starts minimized, open it from the taskbar), ready, playing (position/duration/title if available), error. No raw JSON to the user.
 - Controls: play/pause, next, previous, seek, volume; they should keep working while the car talks (ducking: `POST /audio/duck {on}` lowers game+music volume and restores it, with a 30 s failsafe).
C. Keep the iPad screen awake while connected: request a Screen Wake Lock (navigator.wakeLock) when the app is connected to the relay and re-request it when the app returns to the foreground (iPadOS only gives it to the installed Home Screen app on recent versions); fall back to a tiny silent looping video if unavailable. Quentin's iPad screen keeps turning off.
D. App icon: the home-screen icon on the OptiPlex was replaced by hand with a stylised Tesla "T" (red on near-black) in dist-beamng: apple-touch-icon.png (180), pwa-192.png, pwa-512.png, favicon.png (64). Put the same images in the app's source assets so a rebuild does not undo it. The generator script is C:\car-mode-tools\Make-Tesla-Icon.ps1 on the OptiPlex (copy it from there; it uses System.Drawing).

## Acceptance
- Change the UI only; build; run the app's own tests; confirm in the browser with the relay on the OptiPlex (https tunnel link or http://192.168.0.200:8765/?token=...). Report what you ran and what you could not run (no real iPad, no sound).
- Do not change the bridge yourself except by asking the OptiPlex session; list exactly which endpoints you still need in your issue #18 comment.
