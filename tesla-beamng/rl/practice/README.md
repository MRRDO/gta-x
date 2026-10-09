# Practice runner

`Tesla FSD Practice` (Start menu -> `~/tesla-beamng-auto/practice/Practice Start.bat`) starts the game small (640x360, below-normal priority) if it is not running, then loops until stopped (Ctrl-C or `Practice Stop.bat`).

Scenarios (8 categories; weak ones get picked more): park near / aisle / far from random poses around random spots, point-to-point to Street / Parking Lot / Curbside / Driveway with random profiles, and leaving a spot (park, then drive away with fromPark).

Learning: REINFORCE on a linear Gaussian policy. 7 features of where the car is relative to the spot (distance, bearing, position along/across the spot axis, heading) -> the autopark knobs (rmin, fwdSpeed, revSpeed, tail). Reward = episode score / 100 with a running baseline, exploration noise decays to a floor. The same weights are evaluated in planner.lua (`settings.apPolicy`, `apFeatures` must match `features()` in practice.mjs). The low-level driving stays classical; it learns how to plan the parking. Traffic (spawned AI cars) is not part of it yet.

Persistence: `~/.tesla-beamng/practice/state.json` (best knobs, per-category scores, history), `episodes.jsonl` (every run). The laptop service (`auto.mjs`) pushes `state.json`'s policy weights to the game whenever it connects, so what it learned is used in normal play.

Added later: damage from curb/wall hits (the state's `damage`) reduces the reward and a hard hit fails the run; a `margin` knob (extra clearance on the path checks) is learned too. Every parking episode goes to a random lot on the map, P2P episodes start at random road nodes, and `furious:drift` episodes drive Furious Max with the drift stunt on: its timing/limits (`driftTune`: kick, slideMax, vMin, kMin, yawBail) are a second REINFORCE policy rewarded for arriving cleanly plus handbrake kicks with a real slide. The service pushes `apPolicy` and `driftTune`, and turns `drift` on for the Furious profile.

Traffic and stunts: the `traffic` command spawns AI cars on the road graph around the player (GE `setTraffic`; untested against 0.39 until it is run, it reports what it did as a notice). Episodes `p2p:traffic` and `furious:traffic` use 3-10 cars. Furious Max stunts (planner.lua, `settings.stunts`): on a clear straight stretch with nothing within 70 m it weaves (3 swings) or darts across its lane, inside the lane only; the weave amplitude, spacing and frequency are learned (`driftTune.weaveAmp/weaveGap/stuntEvery`). Resource limits: the game runs at Idle priority on half the cores in a 640x360 window.
