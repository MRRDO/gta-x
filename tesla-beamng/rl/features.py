"""Turns the relay's driving log (~/.tesla-beamng/logs/drive-*.jsonl, written with `--record`)
into training rows. The observation layout here is the contract with
beamng/mod/lua/common/teslaBridge/policy.lua: keep OBS_NAMES in sync with it.

Phase 1 is longitudinal only (how hard to accelerate / brake): the log has speed, the limit, the
gap to the car ahead and what the driver did with the pedals. Steering needs path features
(lateral offset, heading error, curvature ahead) that the planner has but the log does not, see
docs/AI_COMPUTE_PLAN.md phase 3.
"""
import glob
import json
import os

OBS_NAMES = ["v", "limit", "gap", "gap_closing", "ctl_dist", "ctl_red", "accel"]
OBS_SCALE = [30.0, 30.0, 60.0, 10.0, 80.0, 1.0, 4.0]  # divide by these, then clip to [-1.5, 1.5]


def log_files(root=None):
    root = root or os.path.join(os.path.expanduser("~"), ".tesla-beamng", "logs")
    return sorted(glob.glob(os.path.join(root, "drive-*.jsonl")))


def read_states(path):
    """Yield the state lines of one log (dicts), skipping event lines and bad lines."""
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("k") == "s" and d.get("v") is not None:
                yield d


def _clip(x):
    return max(-1.5, min(1.5, x))


def observation(cur, prev):
    """One observation vector (list of floats, same order as OBS_NAMES) from a state line and the previous one."""
    v = cur["v"] or 0.0
    lim = cur.get("lim") or 0.0
    gap = cur.get("gap")
    gap = 60.0 if gap is None else min(gap, 60.0)
    dt = (cur["t"] - prev["t"]) if prev and cur.get("t") is not None and prev.get("t") is not None else 0.0
    acc = (v - (prev["v"] or 0.0)) / dt if dt > 1e-3 else 0.0
    pgap = 60.0 if (prev is None or prev.get("gap") is None) else min(prev["gap"], 60.0)
    closing = (pgap - gap) / dt if dt > 1e-3 else 0.0
    ctl = cur.get("ctl") or {}
    raw = [v, lim, gap, closing, min(ctl.get("d") or 80.0, 80.0), 1.0 if ctl.get("s") == "red" else 0.0, acc]
    return [_clip(x / s) for x, s in zip(raw, OBS_SCALE)]


def action(cur):
    """What the driver did with the pedals: throttle - brake, -1..1."""
    return (cur.get("thr") or 0.0) - (cur.get("brk") or 0.0)


def human_rows(paths=None, min_speed=1.0):
    """(obs, action) rows from stretches where the HUMAN was driving (FSD off, moving, not in a menu)."""
    X, Y = [], []
    for p in paths or log_files():
        prev = None
        for s in read_states(p):
            if not s.get("fsd") and (s["v"] or 0) > min_speed and s.get("lim"):
                X.append(observation(s, prev))
                Y.append(action(s))
            prev = s
    return X, Y


def reward(cur, prev, took_over=False):
    """Reward for reinforcement learning (phase 4). Progress at a sensible speed, comfort, no takeovers."""
    v = cur["v"] or 0.0
    lim = cur.get("lim") or 0.0
    r = 0.0
    if lim > 0:
        r += 0.1 * min(v, lim) / lim               # progress, capped at the limit
        r -= 0.3 * max(0.0, v - lim * 1.1) / lim   # speeding
    gap = cur.get("gap")
    if gap is not None and v > 3:
        r -= 0.2 * max(0.0, 1.0 - gap / (1.5 * v))  # tailgating (gap in metres vs 1.5 s)
    if prev is not None and cur.get("t") is not None and prev.get("t") is not None and cur["t"] > prev["t"]:
        jerk = abs((cur.get("thr") or 0) - (prev.get("thr") or 0)) + abs((cur.get("brk") or 0) - (prev.get("brk") or 0))
        r -= 0.05 * jerk                             # smoothness
    if took_over:
        r -= 5.0                                     # the human had to step in: worst outcome
    return r
