# rl/: learn from Quentin's driving

See `docs/AI_COMPUTE_PLAN.md` for the plan. Quick start:

1. The driving log is ON by default now (turn it off with `--no-record` or `TESLA_RECORD=0`). Let the game's own AI drive for a few hours (BeamNG's AI mode, car on traffic/random routes) as the baseline, or drive yourself.
2. Drive normally for a while (FSD off is what it learns from). Logs: `~/.tesla-beamng/logs/`.
3. `pip install numpy` then `python rl/train_bc.py` -> `policy.json`.
4. `policy.json` is loaded by `beamng/mod/lua/common/teslaBridge/policy.lua` (phase 2 wires it in; today it drives nothing).

`features.py` is the contract: `OBS_NAMES` / `OBS_SCALE` must match what the game feeds `policy.lua`.
