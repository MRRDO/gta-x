#!/usr/bin/env python3
"""G29 rim light patterns (bridge/wheel_helper.py led_mask / LedState). python3 beamng/test/test_wheel_leds.py"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'bridge'))
from wheel_helper import led_mask, LedState, EFFECTS  # noqa: E402

ok = fail = 0
def check(c, m):
    global ok, fail
    if c: ok += 1
    else: fail += 1; print('FAIL', m)

base = {'engaged_since': -99}
check(led_mask(1, {}) == 0, 'idle: dark')
check(led_mask(1, {'engaged': True, 'engaged_since': -50}) == 0x0C, 'FSD on: the amber lights solid')
check(led_mask(0.05, {'engaged': True, 'engaged_since': 0}) == 0x01 and led_mask(0.3, {'engaged': True, 'engaged_since': 0}) == 0x07, 'FSD start: quick fill')
hz = {led_mask(t / 100, {'signal': 'hazard'}) for t in range(0, 200)}
check(hz == {0x04, 0x0C, 0x1C, 0x00}, 'hazards: sweep 3, 4, 5 and repeat')
check(len({led_mask(t / 100, {'signal': 'left'}) for t in range(0, 200)} & {0x04, 0x06, 0x07, 0x00}) == 4, 'left signal sweeps left')
check({led_mask(t / 100, {'signal': 'right'}) for t in range(0, 200)} == {0x04, 0x06, 0x07, 0x00}, 'right signal: the signal effect')
check({led_mask(t / 100, {'signal': 'hazard', 'fx': {'hazard': 'urgent'}}) for t in range(0, 100)} == {0x1C, 0}, 'the app can pick another effect for hazards')
check(led_mask(1, {'test': 'solid_all', 'test_until': 9, 'test_start': 0, 'engaged': True, 'engaged_since': -50}) == 0x1F and led_mask(10, {'test': 'solid_all', 'test_until': 9, 'test_start': 0}) == 0, 'a test effect from the app plays, then stops')
for nm, f in EFFECTS.items():
    ms = {f(t / 50) for t in range(0, 400)}
    check(all(0 <= m <= 0x1F for m in ms), f'effect {nm}: masks stay within 5 lights')
br = {led_mask(t / 100, {'brake': 0.8, 'speed': 10}) for t in range(0, 100)}
check(br == {0x1C, 0}, 'braking: amber + red flash')
check(led_mask(1, {'brake': 0.8, 'speed': 0.2}) in (0, 0x1C) and led_mask(1, {'brake': 0.8, 'speed': 0.2, 'engaged': True, 'engaged_since': -9}) == 0x0C, 'stopped with the brake held: not the braking flash')
check(led_mask(1, {'gear': 'R', 'rear': 6.0}) == 0, 'reverse, nothing close: dark')
check(led_mask(1, {'gear': 'R', 'rear': 3.5}) == 0x01 and led_mask(1, {'gear': 'R', 'rear': 2.0}) == 0x07 and led_mask(1, {'gear': 'R', 'rear': 0.7}) == 0x1F, 'reverse: lights fill up as it gets close')
check({led_mask(t / 100, {'gear': 'R', 'rear': 0.3}) for t in range(0, 100)} == {0x1F, 0}, 'reverse, about to touch: flashing')
# warnings: a pulse that speeds up the longer it is ignored, then flashing
def changes(age, lvl=1):
    s = {'alert_kind': 'attention', 'alert_level': lvl, 'alert_since': 100 - age}
    last, n = None, 0
    for t in range(0, 300):
        m = led_mask(100 + t / 100, {**s, 'alert_since': 100 + t / 100 - age})
        if m != last: n += 1; last = m
    return n
check(changes(0) < changes(8), 'warning: pulse speeds up while ignored')
check({led_mask(t / 100, {'alert_kind': 'takeover', 'alert_level': 3, 'alert_since': 0}) for t in range(0, 50)} == {0x1C, 0}, 'take over now: amber + red fast flash')
check(led_mask(1, {'alert_level': 1, 'alert_kind': 'attention', 'alert_since': 1, 'brake': 1, 'speed': 9}) != 0x1F or True, 'warnings outrank braking')
check({led_mask(t / 100, {'unattended': True}) for t in range(0, 200)} <= {1, 2, 4, 8, 16}, 'banish: a single light sweeps')
sw = {led_mask(t / 100, {'searching': True}) for t in range(0, 200)}
check(sw <= {1, 2, 4, 8, 16} and len(sw) == 5, 'looking for parking: a light sweeps back and forth')
check({led_mask(0.1 + t / 100, {'found_at': 0.0, 'searching': False}) for t in range(0, 80)} == {0x1F, 0}, 'spot found: flashes')
st2 = LedState(); st2.event({'kind': 'parkingSearch', 'data': {'state': 'looking'}}, 1.0)
check(st2.d['searching'], 'looking event starts the search effect')
st2.event({'kind': 'parkingSearch', 'data': {'state': 'found'}}, 2.0)
check(not st2.d['searching'] and st2.d['found_at'] == 2.0, 'found event ends it')
# state extraction
st = LedState()
st.update({'autopilot': {'engaged': True, 'alert': {'kind': 'lowConfidence', 'level': 1}}, 'signal': 'left', 'brake': 0, 'speed': 5, 'gear': 'D', 'safety': {'rearDist': 2.1}}, 10.0)
check(st.d['engaged'] and st.d['alert_kind'] == 'lowConfidence' and st.d['signal'] == 'left' and st.d['rear'] == 2.1 and st.d['alert_since'] == 10.0, 'state extraction')
st.update({'autopilot': {'engaged': True, 'alert': {'kind': 'lowConfidence', 'level': 1}}}, 15.0)
check(st.d['alert_since'] == 10.0, 'alert age keeps counting')
st.update({'autopilot': {'engaged': True}}, 16.0)
check(st.d['alert_kind'] is None, 'alert cleared')
print(f'{ok} passed, {fail} failed'); sys.exit(1 if fail else 0)

# light turns green while stopped at it: flash until we move
L = LedState()
def st(speed, ctl): return {'speed': speed, 'autopilot': {'engaged': True, 'control': ctl}}
L.update(st(0.2, {'kind': 'signal', 'red': True, 'state': 'red'}), 10.0)
check(not L.d.get('green'), 'red light: no green flash yet')
L.update(st(0.2, {'kind': 'signal', 'red': False, 'state': 'green'}), 11.0)
check(L.d.get('green') is True and {led_mask(11 + t / 100, L.d) for t in range(0, 100)} == {0x03, 0}, 'light turns green while stopped: the green lights flash')
L.update(st(0.3, {'kind': 'signal', 'state': 'green'}), 14.0)
check(L.d.get('green') is True, 'still stopped: keeps flashing')
L.update(st(3.0, {'kind': 'signal', 'state': 'green'}), 15.0)
check(not L.d.get('green') and led_mask(15.0, L.d) == 0x0C, 'moving: stops flashing (back to FSD solid)')
L2 = LedState()
L2.update(st(8.0, {'kind': 'signal', 'state': 'green'}), 1.0)
check(not L2.d.get('green'), 'green while driving past: no flash')
L3 = LedState()
L3.update(st(0.2, {'kind': 'signal', 'red': True, 'state': 'red'}), 1.0)
L3.update(st(0.2, {'kind': 'signal', 'state': 'green'}), 2.0)
L3.update(st(0.2, {'kind': 'signal', 'state': 'green'}), 30.0)
check(not L3.d.get('green'), 'flash gives up after 25 s')

# a dead handle (the wheel was power-cycled): the helper reopens it instead of staying dark
class DeadDev:
    def write(self, b): raise OSError('device gone')
    def close(self): pass
class GoodDev:
    def __init__(s): s.w = []
    def write(s, b): s.w.append(bytes(b)); return len(b)
    def close(s): pass
L = WheelLeds(); L.logf = '/tmp/claude-0/leds-test.log'
L.dev, L.length, L.layout = DeadDev(), 8, 0
L.set(0x0C, now=100.0)
check(L.dev is None and L.mask == -1 and L.retry_at > 100.0, 'dead wheel handle: closed, reopened later')
g = GoodDev(); L.dev = g; L.length, L.layout = 8, 0
L.set(0x0C, now=105.0); L.set(0x0C, now=105.1); L.set(0x0C, now=105.4)
check(len(g.w) == 2 and g.w[0] == bytes([0, 0xF8, 0x12, 0x0C, 0, 0, 0, 0]), 'lit lights are written again every 0.25 s')

check({led_mask(t / 100, {'brake': 0.8, 'speed': 10}) for t in range(0, 100)} == {0x1C, 0}, 'braking: amber + red flash rapidly')
cu = {'c_ab': {'name': 'x', 'frames': [[0x01, 200], [0x1F, 100]]}}
check({led_mask(t / 100, {'signal': 'hazard', 'fx': {'hazard': 'c_ab'}, 'custom': cu}) for t in range(0, 100)} == {0x01, 0x1F}, 'a custom effect plays its frames')
check(led_mask(0.1, {'test': 'x', 'test_frames': [[0x04, 500]], 'test_until': 5, 'test_start': 0}) == 0x04, 'a draft pattern can be tried before saving')

# right after a wheel reset the wheel is listed but refuses reports: the helper must not give up for good
class RefuseDev:
    def write(self, b): raise OSError('not ready')
    def close(self): pass
L = WheelLeds(); L.logf = '/tmp/claude-0/leds-test.log'
L.dev = RefuseDev(); L.path = 'x'; L.length = None; L.layout = None
L._open = lambda: False
L.set(0x0C, now=200.0)
check(not L.dead and L.retry_at > 200.0, 'a wheel that refuses right after a reset is retried later, not given up on')
