# Practice runner

`Tesla FSD Practice` (Start menu shortcut -> `~/tesla-beamng-auto/practice/Practice Start.bat`) starts the game if it is not running, then loops until stopped:

- Autopark episodes: random spot and start pose around it (teleported), scored on arrival, alignment and time.
- Every 4th episode a point-to-point trip (150-400 m, random arrival type).
- Every 6 autopark episodes it moves one knob of `settings.apTune` (rmin, fwdSpeed, revSpeed, tail) and keeps the change only if the next 6 episodes score better.

Logs: `~/.tesla-beamng/practice/episodes.jsonl`, the best knobs in `state.json`. Stop: Ctrl-C or `Practice Stop.bat`.
It uses the normal level (east_coast_usa); a dedicated hidden map is a later step. No wheel is needed.
