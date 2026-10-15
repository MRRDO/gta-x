# FSD "brain": how the AI grows, and what hardware it needs

Written 2026-09-30 (bridge-dev). Facts about the OptiPlex / R5 340X below are from memory and worth a
2-minute check of the exact model before buying anything.

## What exists today (no GPU, no training)

| Layer | File | What it does | Cost |
|---|---|---|---|
| Reasoning | `brain.lua` | Belief a car is a real threat (in lane? oncoming? other level?), reads swerving / cut-in / hard braking / parked badly / tailgating / pedestrians heading for the road | ~4 us a tick with 30 cars |
| Judgement | `judge.lua` | Commitment (no flip-flopping lanes), confusion detector (stopped, can't say why -> re-plan -> reset -> ask driver) | a few compares a tick |
| Memory | `learn.lua` | Speed/gap style per road type + places where he took over ("go gentler here") | one table lookup |
| Foundation | `recorder.ts`, `rl/`, `policy.lua` | Log his driving, train a tiny net on it, run it in the game (not driving yet) | see below |

All of it is plain logic on the CPU. A frame is ~16,000 us; this is ~10 us. It cannot cost FPS.

## My take on the OptiPlex 5040 i7 + Radeon R5 340X idea

Quentin's idea: game on the "APU", AI on the GPU. Two problems, one good news.

1. **The 5040's i7 (Skylake, e.g. i7-6700) has no APU-class graphics**, just Intel HD 530 (~0.4 TFLOPS). The
   R5 340X (old GCN 1.0 "Oland", 320 shaders, ~0.6 TFLOPS) is only a little faster. BeamNG is heavy: expect
   low settings, 720p-1080p, 20-40 fps on either. So **the game should get the discrete card**, not the
   iGPU, and the iGPU does nothing useful for AI.
2. **The R5 340X can't do machine learning in practice**: no CUDA, no ROCm (GCN 1.0 is unsupported), so
   PyTorch/TensorFlow won't use it (DirectML might, slowly, not worth the pain).
3. **Good news: we don't need a GPU for this.** The policy is ~400 numbers (7-16-16-1). It trains on the CPU
   in under a minute (numpy, `rl/train_bc.py`) and runs in ~2 us. Even the later RL step is a small net; the
   slow part of RL is **simulating driving** (the game), not the network maths.

So: buy it for BeamNG if the price is right (better than the ProBook's Vega iGPU? check), but don't count on
it for AI. A GPU only matters if we ever train something big (camera / vision), which we don't need.
The i7's 4 cores / 8 threads are what training will use, and the laptop can train too.

## A small LLM ("FSD Assistant")

Setting `assistant` (Settings > Autopilot > FSD Assistant, **on by default**). An LLM is far too slow for the
20 Hz driving loop (a 1B model makes a few tokens a second on a CPU, less on an old GPU), so it is NOT a driver.
What it can do: comment on rare, slow situations. Today: when FSD is stuck at level 2+ (it has re-planned and
reset and still cannot say why), the relay (`bridge/assistant.ts`) sends the scene to a local model and shows
its advice in the app: wait / replan / creep / ask the driver, plus a few words why. **Advice only, the car does
not act on it.** With no local model running it does nothing and costs nothing, so on-by-default is safe.
To try it: install Ollama, `ollama pull llama3.2:1b` (~1 GB); `TESLA_LLM_URL` / `TESLA_LLM_MODEL` override.
It runs on the CPU (24 GB of RAM is plenty); the R5 340X can't help. Later ideas: voice commands, explaining
what FSD is doing ("slowing for a pedestrian"), reading signs the map lacks.

## Phases

**Phase 1: done (foundation).**
`node bridge/relay.ts --record` (or `TESLA_RECORD=1`) appends his driving to
`~/.tesla-beamng/logs/drive-DATE.jsonl` (10 Hz, ~25 MB a day, local only; events for takeovers / AEB / lane
changes). `python rl/train_bc.py` clones how he uses the pedals (speed vs limit, gap, lights, acceleration)
into `policy.json`. `policy.lua` runs it and matches numpy exactly (tested). **It does not drive anything yet.**

**Phase 2: advisory speed policy (wired, off by default).**
Done: `settings {policy:true}` + a trained `settings/teslaBridgePolicy.json` in the game's user folder nudges the speed caps by at most +-8% (smoothed, 5 Hz). Still to do: the offline check against held-out days and the A/B takeover-rate comparison below. Original plan:
Load `policy.json` in the GE, blend its suggestion into the planner's speed (max +-10%, never above the limit
offset, safety layer always wins), behind a setting. Check offline first: how often would it have matched
him on held-out days. Then A/B by takeover rate (learn.lua already counts takeovers).

**Phase 3: steering + lane decisions.**
The relay log lacks path features. Add a GE-side recorder that writes the planner's view (lateral error,
heading error, curvature ahead, lead car, lane options, what FSD did and what he did). Clone lane-change
timing and steering feel from him. This is what makes it drive "like a person".

**Phase 4: reinforcement learning, when idle.**
- **When:** an idle detector (no wheel / pedal / key input for ~5 min, or a "Train now" toggle). Any input
  stops training and hands back the car. It cannot run *while he plays*: RL must control the car to explore,
  which is not safe or fun during normal driving. What can run while he drives is Phase 1-3 (learning by
  watching), and it costs nothing.
- **How:** a Gym-style env over the relay (`rl/env.py`, reward already in `rl/features.py`), episodes on a
  fixed set of routes with random traffic, `resetVehicle` on a crash, sim speed raised if the game allows it
  (unverified). Small PPO/SAC net on CPU (stable-baselines3), exported to `policy.json`.
- **Safety:** the learned policy only *suggests*. The brain / safety / speed-limit layers still decide, and a
  new policy is only adopted if it beats the current one on the fixed evaluation routes (fewer takeovers /
  hard brakes / collisions).
- **When he switches to FSD:** FSD uses the trained policy plus all the rule-based logic; training stops.

**Phase 5: compute placement.**
Best: game on the PC with the better GPU; trainer on any CPU (same PC when idle, or the laptop). No GPU
needed. Revisit only if we add vision.

## Least-harm decisions (Quentin: illegal but logical is fine)

`safety.lua` no longer only swerves when there is a free lane. When braking cannot stop in time it scores every
way out and takes the one that hurts least, even an illegal one: into the oncoming lane, onto the verge,
sideswiping a parked car. Harm: pedestrian 100, car 2 + impact speed^2 / 8, wall or pole 30, verge / oncoming
lane a few points; straight ahead counts what full braking leaves of the speed. It only swerves when that is
clearly better (< 60% of the harm of braking straight), so a bump it can nearly stop for is braked, not swerved.
Limits: a swerve needs about a second and a metre or two of sideways room, so it cannot save what is already
inside ~0.7 s; and it only knows about what the game reports as cars (pedestrians are the small ones).

## Honest limits

- Nothing here has been driven in the real game yet; the reasoning layer and judge are tested in the
  fake-game harness only.
- Imitation of one person's driving copies his habits (good and bad); RL can find odd shortcuts, hence the
  fixed evaluation routes and the "suggest only" rule.
- I don't know that BeamNG retail allows faster-than-real-time simulation with stable physics; that decides
  how useful overnight RL is.
