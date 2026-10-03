# Prompt for the laptop session: build the OptiPlex USB (paste this whole file)

You are the **cowork-laptop** session on Quentin's Windows laptop (`C:\Users\qcp20`). Quentin has a **bootable
Windows 10 installer USB plugged in** and an OptiPlex 5040 (i7, Radeon R5 340X with no HDMI) that will become the
BeamNG + FSD "car". Goal: when he boots the USB and Windows is installed, **a folder of tools opens by itself**.

Do this once, carefully, then report. Read `MRRDO/tesla-ui-atv` AGENTS.md + top of CHANGELOG.md first (house rules:
never enter credentials, never modify git config, never change the laptop's screen/graphics/BeamNG settings,
no audio while testing, no emojis in the UI). Pull `MRRDO/gta-x` branch `claude/review-feedback-gyfm2f`.

## What Quentin decided (from his email reply, Oct 2)
- A script that **collects facts and benchmarks** by itself (and can optimise): built (`Benchmark.ps1`).
- Windows tuning list C is **done by script**, but: sleep and hibernate stay **available** and never trigger **automatically**; **do not touch** transparency/animations (#37), notifications/Focus assist (#38), restore points (#40). Auto-login is not set (needs his password).
- BeamNG settings: **copy the laptop's current settings** to the OptiPlex, with the **FPS cap at 60**.
- Idle-only training (#61/#65): runs only when he switched it on **and** the PC is idle (built: `Train-WhenIdle.ps1`).
- Apps to auto-install: Chrome, AnyDesk, Claude and a few others (built: `Install-Apps.ps1`).
- iPad stays the Tesla screen, monitor = the game. A **Cloudflare tunnel runs on the OptiPlex** so the iPad gets https and therefore camera/mic (the bridge already does this with `--tunnel`; needs `cloudflared`).

## Safety rules for the USB (non-negotiable)
1. **Never format, repartition, clean or delete anything on the USB.** Only ADD files. Before writing, list the USB's top level and confirm it is a Windows 10 installer (`sources\install.wim` or `install.esd`, `setup.exe`, `bootmgr`). If it is not, stop and ask Quentin.
2. Find the USB by looking for those files, do not guess a drive letter. Show Quentin the drive letter and free space and **ask before the first write**.
3. Do not create an `autounattend.xml` that touches disks. The install must stay interactive: **he** chooses the disk.
4. Do not run `Windows-Tune.ps1`, `Apply-BeamNG-Settings.ps1`, `Install-*.ps1` or `Train-WhenIdle.ps1` on the laptop. They are for the OptiPlex. (`Collect-Facts` / `Benchmark.ps1` without switches are read-only and are fine to run as a test.)

## Steps
1. **Get the kit**: `tesla-beamng/optiplex-kit/` in the gta-x branch has `OptiPlexTools/` (the folder) and `usb/` (boot helpers).
2. **Test the scripts here** (nobody has run them on Windows yet): parse every `.ps1` with
   `powershell -NoProfile -Command "[void][scriptblock]::Create((Get-Content -Raw '<file>'))"`, run `Benchmark.ps1` (no switches) and `Collect-Facts.ps1`, run `node scripts\fps-sample.mjs --seconds 5` against the bridge if it is up. Fix real bugs in the scripts (commit to the gta-x branch, small commits, add a CHANGELOG line in the hub).
3. **Lay out the USB** (additions only):
   - `<USB>\OptiPlexTools\` = the kit's `OptiPlexTools\`
   - `<USB>\sources\$OEM$\$1\OptiPlexTools\` = the same folder (Windows Setup copies it to `C:\OptiPlexTools`)
   - `<USB>\sources\$OEM$\$$\Setup\Scripts\SetupComplete.cmd` = kit `usb\SetupComplete.cmd`
   - `<USB>\Find-Tools.cmd`, `<USB>\USB-README.txt` from `usb\`
   If `$OEM$` already exists, merge, do not overwrite; say what you skipped.
4. **Fill the folder** (check free space; skip and report anything that does not fit):
   - `OptiPlexTools\car-mode\` = a copy of `tesla-beamng\` (no `node_modules`, no `.git`) inside a `tesla-beamng` folder, plus the app's BeamNG build (`tesla-ui-atv\dist-beamng`, run `npm run build:beamng` in the hub repo) at `car-mode\tesla-ui-atv\dist-beamng` so the relay finds it. The relay looks for `..\..\tesla-ui-atv\dist-beamng` or `~\tesla-ui-atv\dist-beamng`: keep that layout, and tell me if `setup.ps1` expects something else.
   - `OptiPlexTools\installers\` = offline installers for Chrome, AnyDesk, Git, Node LTS, Python 3.12, cloudflared, 7-Zip, HWiNFO, Tailscale (official download pages only; verify the publisher signature with `Get-AuthenticodeSignature`; record version + SHA256 in `installers\MANIFEST.txt`). Winget is the fallback if something is missing.
   - `OptiPlexTools\beamng-settings\` = a **copy** of the laptop's BeamNG `settings` folder (find it under `%LOCALAPPDATA%\BeamNG\...`), with the **frame rate cap set to 60** in the COPY only (find the right key by reading the file; **do not change the laptop's own settings**). Remove anything that is machine specific or personal (account tokens, cloud IDs, saved paths). Write `beamng-settings\README.txt` saying what you changed.
5. **Verify**: list the final USB tree, check hashes of the copied scripts against the repo, confirm `START-HERE.cmd` and `sources\$OEM$\...` exist, and eject-safe (flush) the drive.
6. **Report**: a hub issue comment (labelled `session:bridge-dev`) with: drive letter used, what was added, what did not fit, script bugs found/fixed, anything unverified. Then **email Quentin** (quentincpullum@gmail.com and 013244@cm201u.org) the same summary, as he asked.

## What Quentin will see (so the result matches)
Boot USB -> normal Windows 10 Setup (he picks the disk) -> first sign-in -> File Explorer opens on `C:\OptiPlexTools` ->
double-click `START-HERE.cmd` -> menu: facts+benchmark, Windows setup, install apps, install Car Mode, BeamNG settings, training on/off.

## Known limits to mention honestly
- Scripts were written without a Windows machine; winget ids (esp. `Anthropic.Claude`, `LizardByte.Sunshine`) are from memory.
- "Render on the Radeon, show on the processor's graphics" should work on Windows 10 1803+ but is not verified on that PC.
- Windows 10 no longer gets free security updates (Oct 14, 2025).
- The bridge's overnight scenario runs and scenario library (#73/#74) are bridge-dev work, not part of this USB.
