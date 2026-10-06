# Black box: what happened in the last 90 seconds

Press **Ctrl+Alt+B** on the PC (anywhere, also inside the game) when FSD does something wrong. You hear two beeps and a small toast says where the file went and whether it was uploaded.

The relay keeps the last 90 s in memory (about 10 samples a second, a few hundred KB, nothing is written until you press the key). The file has speed, pedals, wheel angle, gear, signal, the lead gap, the road ahead (stop/signal), what the planner was doing (`ai` column: maneuver, lane change and why, waiting, turn ahead, alerts, last disengage reason) and the events around it.

Where the file is: `%USERPROFILE%\.tesla-beamng\blackbox\mark-<time>.json`.

## Auto-upload to GitHub (so it can be read from anywhere)

Needs a GitHub token that only you put on the PC. Nobody else types it in.

1. GitHub > Settings > Developer settings > Fine-grained tokens > Generate new token. Repository access: **only** `MRRDO/tesla-ui-atv`. Permission: **Contents: Read and write**. Short expiry is fine.
2. Save the token as one line in `%USERPROFILE%\.tesla-beamng\github-token.txt` (create the folder if it is missing). Or set the `TESLA_GH_TOKEN` environment variable.
3. Press Ctrl+Alt+B. The toast says `uploaded`; the file appears in the repo under `blackbox/`.

Another repo or folder: `%USERPROFILE%\.tesla-beamng\blackbox-upload.json` with `{"repo": "owner/name", "dir": "blackbox", "branch": "main"}`.

Without a token the file just stays on the PC and the toast says so. The upload happens inside the relay (a plain HTTPS request to api.github.com); the token is never logged.

Tell Claude what happened (a few words) after you press it: the file does not have a note box any more because the input box stole the focus from the full-screen game.
