# Practice runner

`Tesla FSD Practice` (Start menu -> `~/tesla-beamng-auto/practice/Practice Start.bat`) starts the game small (640x360, below-normal priority) if it is not running, then loops until stopped (Ctrl-C or `Practice Stop.bat`).

Scenarios (8 categories; weak ones get picked more): park near / aisle / far from random poses around random spots, point-to-point to Street / Parking Lot / Curbside / Driveway with random profiles, and leaving a spot (park, then drive away with fromPark).

Learning: a hill-climb on `settings.apTune` (rmin, fwdSpeed, revSpeed, tail). 8 episodes with the current best, then 8 with one knob changed; kept only if clearly better and not arriving less often. It is not a neural network. Traffic (spawned AI cars) is not part of it yet.

Persistence: `~/.tesla-beamng/practice/state.json` (best knobs, per-category scores, history), `episodes.jsonl` (every run). The laptop service (`auto.mjs`) pushes `state.json`'s best knobs to the game whenever it connects, so what it learned is used in normal play.
