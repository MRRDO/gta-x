# Handoff for Cowork: install, set up and test the Tesla ⇄ BeamNG bridge

You're on Quentin's Windows laptop (Ryzen 7 4700U, 24 GB, integrated graphics; BeamNG runs on
Low at ~30 fps). Your job:
1. install everything
2. set it up
3. make the Tesla Model X mod's doors openable
4. test it all in the game
5. send Quentin a report

Talk to Quentin casually (a teen who likes slang, humor, and being asked questions).

## Run by yourself, and email Quentin

Quentin won't be watching. Run straight through Parts 1-6 without waiting for a reply in chat.
Everything that needs them goes by **email to quentincpullum@gmail.com** (Gmail connector, or
whatever mail tool you have). If you can't send email at all, write each message to
`Desktop\tesla-bridge-status.txt` (newest at the top) and keep going.

Send an email:

| When | Subject | Say |
|---|---|---|
| You start | `Tesla bridge: started` | What you're about to do and roughly how long it takes |
| **You need Quentin** | `Tesla bridge: needs you` | Exactly what to do, in numbered steps: plug in the G29, approve a Windows admin (UAC) prompt, set G HUB, scan the QR, press a wheel button, hold the wheel for a test. Say whether you're waiting or moved on. |
| **You're stuck** | `Tesla bridge: stuck` | The step, the exact error (short), what you tried, and what you need from them |
| Setup finished, ready to test with them | `Tesla bridge: ready` | "Open BeamNG and the Tesla Bridge shortcut is ready", plus which checks still need them |
| You're done | `Tesla bridge: done` | The Part 5 pass/fail summary (one line each) and where the report is; attach `tesla-bridge-report.zip` if you can |

**When you count as stuck:** the same step fails twice after a real fix attempt, or you've
been blocked on one thing for ~10 minutes. Email once, then **skip that step and carry on**
with everything that doesn't depend on it. Don't loop on it.

**When you need Quentin:** email once, batch everything you need into that one email,
continue with the checks you can do alone (keyboard driving, test page), then come back to
theirs at the end. Check the inbox for their reply every ~10 minutes if you can read email.
If there's no answer in 30 minutes, mark those checks "needs Quentin" in the report and
finish.

At most one email per ~15 minutes, apart from "done". Keep them short, plain and friendly.

**Ground rules**
- Don't change BeamNG's graphics or quality settings, or anything that changes what's on the
  laptop screen (camera views, windows, resolution).
- Don't edit the bridge's code (`tesla-beamng/beamng/mod`, `tesla-beamng/bridge`). If
  something is broken, write it in the report. The dev session fixes code. The one exception
  is the Tesla_X mod in Part 4, which you do edit.
- Keep a copy of anything before you change it.
- You can drive BeamNG yourself with the keyboard for the tests. Anything that needs the G29
  wheel or the iPad needs Quentin: send a `needs you` email (above).

## Part 1: get the code

Either:
- the handoff zip's `tesla-beamng/` folder, copied to `C:\Users\<you>\tesla-beamng`, or
- `git clone -b claude/review-feedback-gyfm2f https://github.com/MRRDO/gta-x.git`, then use
  its `tesla-beamng/` folder (private repo: needs Quentin's GitHub login).

The Tesla UI app's own repo should already be on the laptop at `~/tesla-ui-atv`. Setup builds
its BeamNG version for the relay to serve.

## Part 2: install (automatic)

PowerShell, in the `tesla-beamng` folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

It:
- installs Node.js LTS, Python 3.12 and cloudflared with winget if missing
- runs `npm install`, builds the mod and copies it into BeamNG's mods folder
  (`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods` on current versions)
- builds the app (`~/tesla-ui-atv` → `npm run build:beamng`)
- installs the wheel companion's pip packages
- adds a firewall rule (it pops a Windows admin prompt: if you can't approve it, email
  `needs you` and carry on; the relay still works on this PC)
- puts a **Tesla Bridge** shortcut on the desktop
- runs `npm run doctor`

If something fails:
- **BeamNG user folder not found:** launcher → *Manage User Folder* → *Open in Explorer* shows
  it. Run again with `-BeamNGUserFolder "<that folder>"`.
- **No winget:** install Node LTS (nodejs.org), Python 3.12 (python.org, tick "Add to PATH")
  and cloudflared by hand, then run it again.
- **Any ❌ line in `npm run doctor`:** fix it and run doctor again. ⚠️ lines are fine until
  BeamNG and the relay are running.

## Part 3: setup that needs Quentin

1. Wi-Fi set to **Private**: Settings → Network → Wi-Fi → the network.
2. **Logitech G HUB**, with the G29 selected:
   - operating range **900°**
   - **centering spring off**
   - force feedback 100%
3. **BeamNG → Options → Controls → the G29:**
   - force feedback **on** for steering
   - steering lock 1:1
   - pedals on separate axes
4. Start BeamNG → **West Coast USA** → any car. Then double-click **Tesla Bridge** on the
   desktop. It opens:
   - the relay window, with the QR code
   - a minimised "Wheel buttons" window
   - the app, at `http://localhost:8765/`

   The test page is at `http://localhost:8765/test`.
5. **Wheel buttons:** test page → *Wheel buttons*. For each action Quentin wants (start/stop
   FSD, voice note, lane changes, faster/slower...), click **Set**, then have them press the
   wheel button. Avoid buttons BeamNG already uses for something else.
6. **iPad:** Quentin scans the QR in the relay window. It opens the Tesla UI app over https,
   already connected. It's a new code on every start. Allow the camera (attention check) and
   the mic (voice notes).

## Part 4: the Tesla Model X mod (make its doors openable)

The app's 3D car came from this mod: `~/Downloads/tesla-model-x.zip` (it has
`vehicles/Tesla_X/`). Its doors, frunk and trunk are welded shut: they're held by *latch
beams* that only let go in a crash. The fix is to turn each latch into an **advanced
coupler**, the way stock cars do it. The bridge already looks for couplers with these names:
`doorFLCoupler`, `doorFRCoupler`, `doorRLCoupler`, `doorRRCoupler`, `hoodLatchCoupler`,
`tailgateCoupler`.

1. **Install it unpacked.**
   - Copy the zip somewhere safe as a backup.
   - Extract it into `<BeamNG user folder>\mods\unpacked\tesla-model-x\`, so that
     `...\unpacked\tesla-model-x\vehicles\Tesla_X\` exists. Don't also leave the zip in
     `mods\`, or you get duplicates.
   - Start BeamNG and spawn the Tesla_X once to check it works as it is. It should still
     drive fine on the newest BeamNG. If it errors, note the errors from the console (`~`).
2. **Find the stock pattern to copy.** The mod is built on the Vivace. In the BeamNG install
   folder, open `content\vehicles\vivace.zip` (read-only; copy files out). Look at:
   - its `*_doors_*.jbeam`, `*_hood.jbeam` and `*_tailgate.jbeam` (how the latch couplers
     are written in this game version)
   - `lua\vehicle\controller\advancedCouplerControl.lua` in the game files (the parameter
     names)

   **Follow the stock files over this doc if they differ.**
3. **The latch beams in the mod.** These are breakGroup → node pairs (door node → body node).
   - Front left, `X_doors_F.jbeam`, `door_FL_latch`: d6l-p3l, d6l-p4l, d6l-p5l, d6l-p6l,
     d9l-p5l, d9l-p6l, d9l-p3l, d9l-p4l, d14l-p3l, d14l-p5l
   - Front right: the same with `r`
   - Rear left (Falcon Wing), `X_doors_R.jbeam`, `door_RL_latch`: d19l-q4l, q1l-d19l,
     d19l-f9l, d22l-q1l, d22l-q7l, d22l-q2l, d22l-f9l, d28l-f9l
   - Rear right: the same with `r`
   - Hood (frunk), `X_hood.jbeam`, `hoodlatch`: h4r-f15, h4-f15, h4l-f15, h4r-f13rr,
     h4l-f13ll
   - Tailgate, `X_tailgate.jbeam`, `tailgatelatch`: t5-r4, t5-r2, t5-r4rr, t5-r4ll, t4-r4,
     t4-r4rr, t4-r4ll, t4rr-r4rr, t4ll-r4ll, t3ll-r4ll, t3rr-r4rr
4. **Per part:**
   1. Keep one central pair as the coupler (e.g. `d9l`→`p5l`, `h4`→`f15`, `t5`→`r4`).
      Remove the other latch beams, or leave them with no breakGroup at very low strength.
   2. Add the controller to the part, matching the stock syntax. For example:
      ```
      "controller": [["fileName"], ["advancedCouplerControl", {"name":"doorFLCoupler"}]],
      "doorFLCoupler": {
        "groupType": "autoCoupling",
        "couplerNodes": [
          ["cid1","cid2","autoCouplingStrength","autoCouplingRadius","autoCouplingLockRadius","autoCouplingSpeed","couplingStartRadius","breakGroup"],
          ["d9l","p5l", 40000, 0.01, 0.005, 0.2, 0.1, "door_FL_latch"]
        ],
        "openForceMagnitude": 60, "openForceDuration": 0.4,
        "closeForceMagnitude": 250, "closeForceDuration": 1.2
      }
      ```
      The close force pulls a door back shut (Model X doors are powered). The open force pops
      it open.
   3. Do the hood and tailgate first: they're the simplest. Then the front doors, then the
      Falcon Wings.
   4. JBeam is picky JSON: commas, brackets, no trailing junk. After each file, reload the
      car in game (Ctrl+R) and check the console for errors.
5. **Test the doors.** Spawn the Tesla_X in P, open `http://localhost:8765/test`, and tap FL,
   FR, RL, RR, trunk and hood in *Doors*. Each should:
   - open
   - stay open
   - close on the second tap
   - show the right state on the page (and in the app on the iPad)

   Rules the bridge enforces:
   - doors only open when the car is stopped
   - in D, it shifts to P first
   - while moving it refuses (the log says so)
6. If a part won't cooperate after a fair try, leave it with its original latch, note it, and
   move on.
   - The Falcon Wings swinging like normal doors is a known mod limit. Leave it.
   - Keep the edited mod in `mods\unpacked\`, and zip a copy to
     `Desktop\tesla-model-x-doors.zip` for Quentin.

## Part 5: test it in the game

Use the test page (`/test`). Try **three cars**: a stock sedan (e.g. Covet or Vivace), a stock
pickup (D-Series), and the Tesla_X. Keep BeamNG on Low.

For each check, write pass/fail plus a short note in the report, and note how the game felt
(fps). Checks marked (Quentin) need them: batch them into one `needs you` email, do the rest
first, and do theirs at the end.

| # | Check | How | Pass when |
|---|---|---|---|
| 1 | Diagnostics | Test page → **Run diagnostics** → **Copy** | Save the text (it goes in the report) |
| 2 | State | Watch the header | ~20 Hz, speed, gear, steering all move |
| 3 | Commands | P/R/N/D, lights, signals, horn, doors | The car does each one |
| 4 | FSD route | Click a destination a few blocks away, press **FSD** | Drives there: stays in lane, signals, stops at stop signs/red lights, parks or pulls over, then P |
| 5 | In-car wheel | Cockpit camera during 4 | The steering wheel turns |
| 6 | G29 (Quentin) | During 4 | The physical wheel turns by itself; the *Steering wheel* card shows `active` and a `method` |
| 7 | Takeovers | Brake / turn the wheel hard / press gas | Brake and wheel disengage; gas speeds up and stays on |
| 8 | Accidental bump (Quentin) | Above 25 mph, bump the wheel briefly and let go | Disengage, then `reengaged` in the log |
| 9 | Start from Park | In a parking spot facing in, destination behind, press brake + FSD | Backs out by itself, then drives |
| 10 | Backup camera | Shift to R | Small rear view on the test page; note the fps drop, if any |
| 11 | Attention | Test page, *camera says: on phone* | Nag 1 → 2 → 3, then stops with hazards (a strike) |
| 12 | Safety | FSD off, drive at a stopped car | Warning, then braking or a swerve |
| 13 | Wheel buttons | Press the mapped buttons | Each does its action |
| 14 | iPad app (Quentin) | Scan the QR | App opens and shows the car live; the gear strip, FSD and a map destination control the game |
| 15 | Switch car / reload level | Ctrl+E car switch, reload the level | Keeps working |

If the G29 doesn't move in check 6 and the card says `unavailable`:
1. close "Wheel buttons"
2. turn BeamNG's force feedback **off** for the G29
3. run `bridge\wheel_helper.bat` (the backup)
4. repeat check 6; the card should say `helper`
5. afterwards, turn BeamNG's FFB back on and close the helper

## Part 6: the report

Make `Desktop\tesla-bridge-report\` with:
- `report.md`: the Part 5 table with pass/fail and notes, fps notes, the Part 4 door results,
  and anything weird (short and plain)
- `diagnostics.txt`: the test page diagnostics output
- `doctor.txt`: `npm run doctor` output
- `beamng-log.txt`: the lines of
  `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\beamng.log` that mention `teslaBridge`,
  `teslaAutopilot`, `Tesla_X` or `error` (the last run is enough)
- `relay-log.txt`: copy the relay window's text
- any voice notes: `tesla-beamng\bridge\feedback\`
- `tesla-model-x-doors.zip`, if Part 4 worked

Zip the folder to `Desktop\tesla-bridge-report.zip`, then send the `Tesla bridge: done` email to
quentincpullum@gmail.com with the zip attached (if attaching fails, say where it is).
Quentin gives that zip to the dev session, which fixes whatever failed.

## Start prompt (Quentin pastes this into Cowork once)

```
Open the Tesla BeamNG handoff (tesla-beamng-handoff.zip from my email, or
C:\Users\<me>\Downloads) and follow COWORK_HANDOFF.md from start to finish by yourself.
Don't wait for me in chat: email me at quentincpullum@gmail.com when you start, whenever
you're stuck or need me, and when it's done with the report.
```
