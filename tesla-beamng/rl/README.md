# rl/: learn from Quentin's driving

See `docs/AI_COMPUTE_PLAN.md` for the plan. Quick start:

1. Run the bridge with the driving log on: `npx tsx bridge/relay.ts --record` (or `TESLA_RECORD=1`).
2. Drive normally for a while (FSD off is what it learns from). Logs: `~/.tesla-beamng/logs/`.
3. `pip install numpy` then `python rl/train_bc.py` -> `policy.json`.
4. `policy.json` is loaded by `beamng/mod/lua/common/teslaBridge/policy.lua` (phase 2 wires it in; today it drives nothing).

`features.py` is the contract: `OBS_NAMES` / `OBS_SCALE` must match what the game feeds `policy.lua`.
