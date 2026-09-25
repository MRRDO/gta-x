# Handoff for Cowork: install and set up the Tesla ⇄ BeamNG bridge

You're setting this up on Quentin's Windows laptop (Ryzen 7 4700U, 24 GB, integrated
graphics; BeamNG runs on Low at ~30 fps). Nothing here needs a GPU: the mod is CPU-light
Lua, the relay is a small Node program. **Don't change BeamNG's graphics settings, and
don't set anything that changes what's on the laptop screen.**

Talk to Quentin casually (a teen who likes slang, humor, and being asked questions).
Ask before anything you're unsure about.

## What this is

- A **BeamNG.drive mod** (`beamng/dist/tesla_bridge.zip`): our own FSD-style autopilot,
  active safety, and the link to the app.
- A **relay** (`npm run bridge`): connects the game to the iPad app over Wi-Fi and serves
  a test page at `http://localhost:8765/`.
- A **wheel companion** (`bridge/wheel_helper.py --buttons`): reads the Logitech G29's
  buttons so they can be mapped in Settings. It can also act as a backup force-feedback
  driver if needed.
- Full docs: `docs/BEAMNG_BRIDGE.md`.

## Get the code

Either:
- the handoff zip's `tesla-beamng/` folder, copied to e.g. `C:\Users\<you>\tesla-beamng`, or
- `git clone -b claude/review-feedback-gyfm2f https://github.com/MRRDO/gta-x.git` and
  use its `tesla-beamng/` folder (private repo: needs Quentin's GitHub login).

Use a path with no special characters (OneDrive-synced folders are fine but slower).

## Install (automatic)

In PowerShell, in the `tesla-beamng` folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

It installs Node.js LTS, Python 3.12 and cloudflared (the https tunnel for the iPad app)
with winget if they're missing, then runs
`npm install`, builds the mod, and copies it into BeamNG's mods folder. That folder is
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods` on current versions; older ones used
`%LOCALAPPDATA%\BeamNG.drive\<version>\mods`. It then installs the wheel companion's pip
packages, adds a Windows Firewall rule for Node on private networks (it asks for admin),
puts a **Tesla Bridge** shortcut on the desktop, and runs the setup check.

- If BeamNG's user folder is somewhere else, find it with launcher → *Manage User Folder*
  → *Open in Explorer*, then run again with `-BeamNGUserFolder "<that folder>"`.
- If winget is missing, install Node LTS from nodejs.org and Python 3.12 from python.org
  (tick "Add to PATH"), then run it again.
- Re-run `setup.ps1` any time the code is updated. It also refreshes the mod.

Check the result at any time with `npm run doctor` (read-only). ❌ lines must be fixed;
⚠️ lines are fine until BeamNG and the relay are running.

## Setup that needs Quentin (walk them through it)

1. **Wi-Fi set to Private** (Settings → Network → Wi-Fi → the network → *Private*). Without
   it the iPad can't reach the laptop.
2. **Logitech G HUB**: select the G29 and set:
   - operating range **900°**
   - **centering spring off** (it fights the autopilot)
   - force-feedback strength 100%
3. **BeamNG → Options → Controls → the G29**: force feedback **on** for steering (the mod
   drives the wheel motor itself while FSD is on). Leave the steering lock at 1:1.
4. **Start it:** open BeamNG → **West Coast USA** → spawn any car, then double-click
   **Tesla Bridge** on the desktop. It opens:
   - the relay window, with the QR code for the iPad
   - a minimised "Wheel buttons" window
   - the test page
   
   If Windows asks about the firewall, allow **Private**.
5. **Map the wheel buttons:** test page → *Wheel buttons*. For each action Quentin wants
   (Start/stop FSD, Voice note, lane changes, faster/slower, ...), click **Set**, then press
   the button on the wheel. Saved automatically; the ▶ button tries an action.
   - Don't use buttons BeamNG already uses for something else, or both will happen. Either
     unbind them in BeamNG's controls or pick free ones.
   - Alternative without the companion: BeamNG → Controls → Bindings → *Tesla UI Bridge*.
6. **iPad**: the relay window shows an `https://…trycloudflare.com` address and a QR code.
   Scanning it on the iPad opens the Tesla UI app already connected to the game.
   - It's a **new code every start** (a free Cloudflare quick tunnel).
   - Allow the iPad's camera and mic when asked: the camera checks attention, the mic does
     voice notes.
   - If there's no tunnel (cloudflared missing), the relay shows a Wi-Fi QR instead.
7. **Backup camera**: shift to R in the game. A small rear view shows on the test page
   (and in the app once the UI session adds it). The laptop screen doesn't change.
   Settings has its quality and fps. Note whether the game gets choppy while reversing.

## The Tesla UI app

The relay serves the app itself at `http://<pc>:8765/` (and through the tunnel QR). `setup.ps1`
builds it from `~/tesla-ui-atv` (`npm run build:beamng`) if that folder exists. The test page is
at `/test`. `npm run doctor` says whether the build was found.

## First test (with Quentin driving)

On the test page:
1. **Run diagnostics → Copy**, and save the text to a file for the next dev session.
2. Click a destination on the map a few blocks away, then press **FSD**. Watch:
   - Does the in-car steering wheel turn?
   - Does the G29 turn by itself? The *Steering wheel* card shows `active` and a `method`.
   - Does it stay in lane, stop at stop signs and red lights, and signal?
3. Try the takeovers: brake (disengages), gas (goes faster and stays on), and turning the
   wheel hard (disengages).
4. If the G29 doesn't move and the card says `unavailable`:
   - close the "Wheel buttons" window
   - turn **BeamNG's force feedback off** for the wheel
   - run `bridge\wheel_helper.bat` (the backup: buttons + force feedback)

   The card should say `helper`.

## What to send back to the dev session

- the diagnostics text
- `npm run doctor` output
- the BeamNG console lines starting with `teslaBridge` / `teslaAutopilot` (`~` opens the
  console; `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\beamng.log` has everything)
- what the car did vs what it should have done (a short phone video helps)
- any voice notes: `tesla-beamng\bridge\feedback\` (audio + a .json with the car's state)

## Don'ts

- Don't change BeamNG's graphics/quality settings, or anything that changes the view on
  the laptop screen.
- Don't unzip the mod zip in the mods folder.
- Don't commit `bridge/.token`, `bridge/buttons.json` or `bridge/feedback/` (personal files).
- Don't run `wheel_helper.py` without `--buttons` while BeamNG's force feedback is **on**:
  two programs would fight over the motor.
