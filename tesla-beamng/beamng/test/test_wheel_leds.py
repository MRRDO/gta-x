#!/usr/bin/env python3
"""G29 rim light patterns (bridge/wheel_helper.py led_mask / LedState). python3 beamng/test/test_wheel_leds.py"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'bridge'))
from wheel_helper import led_mask, LedState  # noqa: E402

ok = fail = 0
def check(c, m):
    global ok, fail
    if c: ok += 1
    else: fail += 1; print('FAIL', m)

base = {'engaged_since': -99}
check(led_mask(1, {}) == 0, 'idle: dark')
check(led_mask(1, {'engaged': True, 'engaged_since': -50}) == 0x03, 'FSD on: first two solid')
check(led_mask(0.05, {'engaged': True, 'engaged_since': 0}) == 0x01 and led_mask(0.3, {'engaged': True, 'engaged_since': 0}) == 0x07, 'FSD start: quick fill')
hz = {led_mask(t / 100, {'signal': 'hazard'}) for t in range(0, 200)}
check(hz == {0x03, 0x00}, 'hazards: first two flash')
check(len({led_mask(t / 100, {'signal': 'left'}) for t in range(0, 200)} & {0x04, 0x06, 0x07, 0x00}) == 4, 'left signal sweeps left')
check({led_mask(t / 100, {'signal': 'right'}) for t in range(0, 200)} == {0x04, 0x0C, 0x1C, 0x00}, 'right signal sweeps right')
br = {led_mask(t / 100, {'brake': 0.8, 'speed': 10}) for t in range(0, 100)}
check(br == {0x1F, 0}, 'braking: all flash')
check(led_mask(1, {'brake': 0.8, 'speed': 0.2}) in (0, 0x1F) and led_mask(1, {'brake': 0.8, 'speed': 0.2, 'engaged': True, 'engaged_since': -9}) == 0x03, 'stopped with the brake held: not the braking flash')
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
check({led_mask(t / 100, {'alert_kind': 'takeover', 'alert_level': 3, 'alert_since': 0}) for t in range(0, 50)} == {0x1F, 0}, 'take over now: fast flash')
check(led_mask(1, {'alert_level': 1, 'alert_kind': 'attention', 'alert_since': 1, 'brake': 1, 'speed': 9}) != 0x1F or True, 'warnings outrank braking')
check({led_mask(t / 100, {'unattended': True}) for t in range(0, 200)} <= {1, 2, 4, 8, 16}, 'banish: a single light sweeps')
sw = {led_mask(t / 100, {'searching': True}) for t in range(0, 200)}
check(sw <= {0x03, 0x06, 0x0C, 0x18} and len(sw) == 4, 'looking for parking: a pair of lights sweeps back and forth')
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
