#!/usr/bin/env python3
"""Black box helper.  python3 bridge/bbtool.py map mark-*.json      -> mark-*.svg, the track and the lidar points on a plan view  python3 bridge/bbtool.py summary mark-*.json   -> one page: what the car did, damage, lidar, stuck spots
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
        if e['kind'] in ('disengage', 'error', 'collision', 'arrived', 'notice', 'maneuver', 'parkingSearch', 'stuck', 'missedDest', 'longRoute', 'uturn', 'arriving', 'reengaged'):
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

def svg(p, out=None, size=900):
    """python3 bridge/bbtool.py map mark-*.json  -> mark-*.svg: the car's track (blue) with the lidar points in world coordinates (red solid, grey curb height),
    FSD stretches thick, crash spots as black dots. Opens in any browser. Plain SVG, no libraries."""
    j, S, E = load(p)
    pts, track = [], []
    for i, s in enumerate(S):
        track.append((s['pos'][0], s['pos'][1], s['fsd'], s.get('dmg')))
        if s.get('pts'):
            h = heading(S, i)
            if not h: continue
            # car frame -> world: forward = h, left = (-h.y, h.x); the fan origin is at the nose (about 2.3 m ahead of the centre)
            cx, cy = s['pos'][0] + h[0] * 2.3, s['pos'][1] + h[1] * 2.3
            for f, l, k in s['pts']:
                pts.append((cx + h[0] * f - h[1] * l, cy + h[1] * f + h[0] * l, k))
    xs = [t[0] for t in track] + [q[0] for q in pts]
    ys = [t[1] for t in track] + [q[1] for q in pts]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    sc = size / max(x1 - x0, y1 - y0, 1)
    X = lambda x: (x - x0) * sc + 10
    Y = lambda y: (y1 - y) * sc + 10
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{(x1-x0)*sc+20:.0f}" height="{(y1-y0)*sc+20:.0f}" style="background:#111">']
    for x, y, k in pts:
        o.append(f'<circle cx="{X(x):.1f}" cy="{Y(y):.1f}" r="1.3" fill="{"#ff4d4d" if k else "#777"}"/>')
    for a, b in zip(track, track[1:]):
        o.append(f'<line x1="{X(a[0]):.1f}" y1="{Y(a[1]):.1f}" x2="{X(b[0]):.1f}" y2="{Y(b[1]):.1f}" stroke="#4f8cff" stroke-width="{3 if a[2] else 1.2}"/>')
    prev = None
    for t in track:
        if prev is not None and t[3] is not None and prev > 0 and t[3] - prev > 150:
            o.append(f'<circle cx="{X(t[0]):.1f}" cy="{Y(t[1]):.1f}" r="6" fill="#fff" stroke="#000"/>')
        prev = t[3] if t[3] is not None else prev
    o.append(f'<text x="14" y="22" fill="#ccc" font-size="13" font-family="sans-serif">{p.split("/")[-1]}  {x1-x0:.0f} x {y1-y0:.0f} m</text></svg>')
    out = out or p.rsplit('.', 1)[0] + '.svg'
    open(out, 'w').write('\n'.join(o))
    print('wrote', out)

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    for f in sys.argv[2:]:
        {'summary': summary, 'lidar': lidar, 'map': svg}.get(cmd, lidar)(f)
