# Black box: what happened in the last 90 seconds

When FSD does something wrong, save the black box. Three ways, all do the same thing:

- **Ctrl+Alt+B** on the PC (works inside the game, two beeps and a toast).
- **Save black box now** on the iPad: Settings > Hardware Bridge > Black box.
- (the relay endpoint `POST /blackbox/mark`, for scripts)

Right after, a card pops up on the iPad: **"What went wrong? (optional)"**. Type a few words and press Send. The note is added to the file (and uploaded with it). Dismiss it if you do not want to write anything; it goes away by itself.

The relay keeps the last 90 s in memory (about 10 samples a second, a few hundred KB, nothing is written until you save). The file has speed, pedals, wheel angle, gear, signal, the lead gap, the road ahead (stop/signal), what the planner was doing (the `ai` column: maneuver, lane change and why, waiting, turn ahead, alerts, last disengage reason) and the events around it with their data (for parking: how far off the lines, which stall).

The file is saved on the PC in `%USERPROFILE%\.tesla-beamng\blackbox\mark-<time>.json`.

## Upload to GitHub (so Claude can read it from anywhere)

Do this once. Nobody types the token for you; it only ever lives on the game PC.

1. **Make a token.** github.com > your picture > Settings > Developer settings > Personal access tokens > Fine-grained tokens > Generate new token.
   - Name: `Tesla black box`. Expiration: 90 days or longer.
   - Repository access: **Only select repositories** > `MRRDO/tesla-ui-atv`.
   - Permissions > Repository permissions > **Contents: Read and write**. Nothing else.
   - Generate token and copy it (it starts with `github_pat_`).
2. **Give it to the PC.** On the game PC open the folder `tesla-beamng-auto` (the launcher service folder; Ctrl+Alt+U updates put the script there). Right-click `Setup-BlackBoxUpload.ps1` > Run with PowerShell. Paste the token when it asks (nothing shows while you paste) and press Enter. The script checks the token can write to the repo and saves it to `%USERPROFILE%\.tesla-beamng\github-token.txt` (readable by your user only).
   - By hand instead: save the token as a single line in that file, or set the `TESLA_GH_TOKEN` environment variable.
3. **Test.** Press Ctrl+Alt+B. The toast and the iPad card say **uploaded**, and the file shows up in the repo under `blackbox/`. No restart needed.

Another repo or folder: `%USERPROFILE%\.tesla-beamng\blackbox-upload.json` with `{"repo": "owner/name", "dir": "blackbox", "branch": "main"}`.

If it says "not uploaded": no token file (step 2), the token expired, the repository access does not include the repo, or Contents is not Read and write. The message names which. The file is always saved on the PC either way. The upload is a plain HTTPS request from the relay to api.github.com; the token is never logged or sent anywhere else.
