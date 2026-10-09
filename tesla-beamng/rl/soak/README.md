# FSD soak test

FSD drives itself for hours on random roads, everything is recorded, the car is reset every `SOAK_RUN_MIN` minutes (default 12) with a new start, route and speed profile (standard, chill, hurry, madmax in turn), and a short report is uploaded to GitHub when the black box token is set up.

- Start: `rl\soak\Soak Start.bat` (needs the relay and BeamNG running with a car). Stop: `Soak Stop.bat`, or it ends by itself after `SOAK_HOURS` (default 6).
- Driver monitoring is turned off for the run so nothing pulls over for a missing driver. FSD that switches itself off is switched on again after a pause, and counted.
- Windows is kept awake while it runs.
- Read first: `final.md` (a table per run plus counts of what went wrong and why FSD switched off). Then `incidents.json` (6 s before and after every hard brake, damage, swerve burst, disengage, stuck spell, lane change without signal, error). Raw: `runs/run-NN.jsonl.gz` (10 Hz arrays, columns in `summary.json`), `events.jsonl`.
- Local folder: `%USERPROFILE%\.tesla-beamng\soak\<stamp>\`. Upload folder in the repo: `soak/<stamp>/`.
- Metrics: km, engaged %, average and max speed, hard brakes (over 4 m/s2 with the brake on), steering reversals per km at speed (swerving), sideways acceleration p95 and max, lane changes and how many had no signal, long signals with no lane change, stuck seconds, damage jumps.

## Practice pictures and highway runs (newest)
- Every 3rd run is a highway run (big roads, long trips). Every lane change is logged as an incident with the planner's note.
- A collision with damage ends the run (no automatic FSD re-engage).
- Damage jumps take a JPEG screenshot, uploaded next to the incident.
- Parking practice (`rl/practice`) now draws a top-down picture per episode (blue = forward, orange = reverse), counts adjusting moves (back in, pull forward, repeat) and does not punish them. Reports and the worst 3 and best 1 pictures upload every 10 episodes to `practice/<stamp>/`. `PRACTICE_HOURS` auto-stops.
