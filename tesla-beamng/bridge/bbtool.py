#!/usr/bin/env python3
"""Black box helper.  python3 bridge/bbtool.py summary mark-*.json   -> one page: what the car did, damage, lidar, stuck spots
                      python3 bridge/bbtool.py lidar mark-*.json     -> replay the lidar rules on the recorded points (would it have braked? where?)
The json is what Ctrl+Alt+B writes (samples at 10 Hz with pos/speed/gear/planner note/lidar info + lidar points 3x a second, events, tags)."""
import json, math, sys

def load(p):
    j = json.load(open(p))
    return j, j.get('samples', []), j.get('events', [])

def heading(S, i):
    # direction of travel from the position track (the black box has no heading), None when standing
    a = S[max(0, i - 3)]['pos']; b = S[min(len(S) - 1, i + 3)]['pos']
    dx, dy = b[0] - a[0], b[1] - a[1]
    l = math.hypot(dx, dy)
    return (dx / l, dy / l) if l > 0.3 else None

def summary(p):
    j, S, E = load(p)
    t1 = S[-1]['at']
    rel = lambda t: round((t - t1) / 1000)
    print(f"# {p}\nnote: {j.get('note')}\nlevel: {j.get('level')}  samples: {len(S)}  window: {j.get('seconds')} s")
    fsd = sum(1 for s in S if s['fsd']) * 100 // max(1, len(S))
    print(f"FSD on {fsd}%, top speed {max((s['v'] or 0) for s in S) * 2.237:.0f} mph, damage {S[0].get('dmg')} -> {S[-1].get('dmg')}")
    # stopped stretches while FSD is on (stuck?)
    run = None
    for s in S:
        stopped = s['fsd'] and (s['v'] or 0) < 0.3
        if stopped and run is None: run = s
        if (not stopped or s is S[-1]) and run is not None:
            d = (s['at'] - run['at']) / 1000
            if d >= 6: print(f"  stuck {d:.0f} s at {run['pos'][:2]} ({rel(run['at'])} s): {run.get('ai')}")
            run = None
    for e in E:
        if e['kind'] in ('disengage', 'error', 'collision', 'arrived', 'notice', 'maneuver', 'parkingSearch', 'stuck', 'missedDest'):
            print(f"  {rel(e['at']):>5} s  {e['kind']:<14} {str(e.get('detail'))[:100]}")

def lidar(p, halfW=0.9):
    # what the current rules would do on the recorded points, straight along the direction of travel
    j, S, E = load(p)
    n = acts = 0
    worst = []
    for i, s in enumerate(S):
        if not s.get('pts') or (s['v'] or 0) < 2.0: continue
        h = heading(S, i)
        if not h: continue
        n += 1
        # points are in the car frame [forward, left, solid]; the car frame here is the fan's, so use them directly
        near = [pt[0] for pt in s['pts'] if pt[2] == 1 and pt[0] >= 0.3 and abs(pt[1]) < halfW]
        if near:
            gap = min(near)
            v = s['v']
            if gap < max(14, v * v / 5 + 6):
                acts += 1
                worst.append((gap, v, s['pos'][:2], s.get('ai')))
    print(f"{p}: {n} moving samples with points, lidar would act on {acts}")
    for g, v, pos, ai in sorted(worst)[:5]: print(f"   gap {g:.1f} m at {v * 2.237:.0f} mph, {pos}  {ai}")

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    for f in sys.argv[2:]:
        (summary if cmd == 'summary' else lidar)(f)
