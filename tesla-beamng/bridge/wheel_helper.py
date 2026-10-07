#!/usr/bin/env python3
"""Wheel companion for the Tesla BeamNG bridge. Two jobs:

1. **Buttons** (always): reads every button on your wheel and sends presses to the relay,
   so the app's Settings > Wheel buttons can map any button (start FSD, voice note, lane
   change, speed...), whether or not BeamNG has it bound.
2. **Backup force feedback** (unless --buttons): turns the wheel (Logitech G29 etc.) with
   FSD using an SDL spring, for when the mod can't drive the wheel motor from inside BeamNG
   (the wheel card on the test page says "unavailable", or the wheel doesn't move). It tells
   the car the helper owns the wheel, and holds a spring centred where FSD steers. Grab the
   wheel past the spring and FSD hands over, same as always. With FSD off: a light
   speed-dependent centring spring so the wheel isn't dead.

Setup (once):
    pip install pysdl2 pysdl2-dll websocket-client
    For job 2 only: in BeamNG, Options > Controls > your wheel > Force feedback: OFF (two
    programs fighting over the motor feels awful).
Run (with the relay running):
    python bridge/wheel_helper.py --buttons      buttons only (start.bat runs this for you)
    python bridge/wheel_helper.py                buttons + backup force feedback
    python bridge/wheel_helper.py --list         show wheels SDL can see
    python bridge/wheel_helper.py --invert       the wheel turns the wrong way
    python bridge/wheel_helper.py --strength 0.8 --url ws://127.0.0.1:8765/
Ctrl+C stops it and hands the wheel back to the mod.
"""

from __future__ import annotations

import argparse
import os
import json
import signal
import sys
import threading
import time
from dataclasses import dataclass

# ----------------------------------------------------------------------------- logic (no SDL)


@dataclass
class Spring:
    """What the wheel motor should do: pull toward `center` (-1..1 of full lock)."""
    center: float = 0.0
    coeff: float = 0.0       # 0..1 stiffness
    saturation: float = 0.0  # 0..1 max force
    damper: float = 0.0      # 0..1
    on: bool = False


def clamp(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


class Controller:
    """Turns relay state messages into a Spring. Pure logic, testable without a wheel."""

    def __init__(self, strength: float = 0.6, invert: bool = False):
        self.strength = clamp(strength, 0.05, 1.0)
        self.sign = -1.0 if invert else 1.0
        self.last_state_t = 0.0
        self.state: dict | None = None

    def on_state(self, s: dict, now: float) -> None:
        self.state = s
        self.last_state_t = now

    def spring(self, now: float) -> Spring:
        s = self.state
        if s is None or now - self.last_state_t > 1.0:
            return Spring()  # game paused / gone: let go of the wheel
        ap = s.get('autopilot') or {}
        w = s.get('wheel') or {}
        speed = abs(float(s.get('speed') or 0.0))
        if ap.get('engaged') and ap.get('mode') != 'tacc':
            ratio = float(w.get('ratio') or 1.0) or 1.0
            target = w.get('target')
            if target is None:
                target = float(s.get('steering') or 0.0) / ratio
            return Spring(center=clamp(self.sign * float(target), -1, 1), coeff=self.strength,
                          saturation=self.strength, damper=0.15 * self.strength, on=True)
        # FSD off: the game's own force feedback centres the wheel (the mod gave it back)
        return Spring()
        # FSD off: light centring that firms up with speed, like the game's own FFB
        k = clamp(0.06 + speed * 0.012, 0.06, 0.4) * self.strength / 0.6
        return Spring(center=0.0, coeff=clamp(k, 0, 1), saturation=clamp(k * 1.5, 0, 1), damper=0.1, on=True)


# ----------------------------------------------------------------------------- SDL backend


WHEEL_WORDS = ('wheel', 'g29', 'g920', 'g923', 'racing', 'fanatec', 'thrustmaster', 'moza', 'simagic', 'logitech')


class SDLWheel:
    def __init__(self, device: str | None, haptics: bool = True):
        import ctypes
        import sdl2
        self.sdl2, self.ctypes = sdl2, ctypes
        sdl2.SDL_SetHint(b'SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS', b'1')  # BeamNG has the focus
        if sdl2.SDL_Init(sdl2.SDL_INIT_JOYSTICK | (sdl2.SDL_INIT_HAPTIC if haptics else 0)) != 0:
            raise RuntimeError('SDL init failed: ' + sdl2.SDL_GetError().decode())
        self.joy = self.haptic = None
        self.spring_id = self.damper_id = -1
        self.sent: Spring | None = None
        idx = self.pick(device, haptics)
        if idx is None:
            raise RuntimeError(('no force-feedback wheel' if haptics else 'no wheel or controller') + ' found (plugged in? try --list)')
        self.joy = sdl2.SDL_JoystickOpen(idx)
        self.name = sdl2.SDL_JoystickName(self.joy).decode(errors='replace')
        self.nbuttons = max(0, sdl2.SDL_JoystickNumButtons(self.joy))
        if not haptics:
            return
        self.haptic = sdl2.SDL_HapticOpenFromJoystick(self.joy)
        if not self.haptic:
            raise RuntimeError(f'{self.name}: cannot open haptics: {sdl2.SDL_GetError().decode()}')
        q = sdl2.SDL_HapticQuery(self.haptic)
        if not q & sdl2.SDL_HAPTIC_SPRING:
            raise RuntimeError(f'{self.name}: no spring effect support')
        if q & sdl2.SDL_HAPTIC_AUTOCENTER:
            sdl2.SDL_HapticSetAutocenter(self.haptic, 0)
        if q & sdl2.SDL_HAPTIC_GAIN:
            sdl2.SDL_HapticSetGain(self.haptic, 100)
        self.has_damper = bool(q & sdl2.SDL_HAPTIC_DAMPER)

    @staticmethod
    def list_devices() -> list[tuple[int, str, bool]]:
        import sdl2
        sdl2.SDL_Init(sdl2.SDL_INIT_JOYSTICK | sdl2.SDL_INIT_HAPTIC)
        out = []
        for i in range(sdl2.SDL_NumJoysticks()):
            name = (sdl2.SDL_JoystickNameForIndex(i) or b'?').decode(errors='replace')
            j = sdl2.SDL_JoystickOpen(i)
            out.append((i, name, bool(j and sdl2.SDL_JoystickIsHaptic(j) == 1)))
            if j:
                sdl2.SDL_JoystickClose(j)
        return out

    def pick(self, device: str | None, haptics: bool = True) -> int | None:
        devs = self.list_devices()
        if device is not None:
            for i, name, _ in devs:
                if device.isdigit() and int(device) == i or device.lower() in name.lower():
                    return i
            return None
        pool = [d for d in devs if d[2]] if haptics else devs
        # prefer something that looks like a wheel
        for i, name, _ in pool:
            if any(k in name.lower() for k in WHEEL_WORDS):
                return i
        return pool[0][0] if pool else None

    def buttons(self) -> list[bool]:
        return [self.sdl2.SDL_JoystickGetButton(self.joy, i) == 1 for i in range(self.nbuttons)]

    def _condition(self, kind, center: float, coeff: float, sat: float):
        sdl2 = self.sdl2
        e = sdl2.SDL_HapticEffect()
        e.type = kind
        c = e.condition
        c.type = kind
        c.length = sdl2.SDL_HAPTIC_INFINITY
        c.direction.type = sdl2.SDL_HAPTIC_CARTESIAN
        c.direction.dir[0] = 1
        c.right_sat[0] = c.left_sat[0] = int(clamp(sat, 0, 1) * 0xFFFF)
        c.right_coeff[0] = c.left_coeff[0] = int(clamp(coeff, 0, 1) * 0x7FFF)
        c.deadband[0] = 0
        c.center[0] = int(clamp(center, -1, 1) * 0x7FFF)
        return e

    def apply(self, sp: Spring) -> None:
        sdl2, ctypes = self.sdl2, self.ctypes
        if not self.haptic:
            return
        if not sp.on:
            self.stop()
            return
        prev = self.sent
        if prev and prev.on and abs(prev.center - sp.center) < 0.002 and abs(prev.coeff - sp.coeff) < 0.01 and abs(prev.damper - sp.damper) < 0.01:
            return
        eff = self._condition(sdl2.SDL_HAPTIC_SPRING, sp.center, sp.coeff, sp.saturation)
        if self.spring_id < 0:
            self.spring_id = sdl2.SDL_HapticNewEffect(self.haptic, ctypes.byref(eff))
            if self.spring_id < 0:
                # the game may be holding the device for a moment: say so once in a while and try again next tick
                if time.monotonic() - getattr(self, '_warned', 0) > 5:
                    self._warned = time.monotonic()
                    print('wheel helper: spring effect not created yet:', sdl2.SDL_GetError().decode(), flush=True)
                self.sent = None
                return
            sdl2.SDL_HapticRunEffect(self.haptic, self.spring_id, 1)
        else:
            sdl2.SDL_HapticUpdateEffect(self.haptic, self.spring_id, ctypes.byref(eff))
        if self.has_damper:
            d = self._condition(sdl2.SDL_HAPTIC_DAMPER, 0, sp.damper, 1)
            if self.damper_id < 0:
                self.damper_id = sdl2.SDL_HapticNewEffect(self.haptic, ctypes.byref(d))
                if self.damper_id >= 0:
                    sdl2.SDL_HapticRunEffect(self.haptic, self.damper_id, 1)
            else:
                sdl2.SDL_HapticUpdateEffect(self.haptic, self.damper_id, ctypes.byref(d))
        self.sent = sp

    def stop(self) -> None:
        if self.haptic:
            self.sdl2.SDL_HapticStopAll(self.haptic)
            for i in (self.spring_id, self.damper_id):
                if i >= 0:
                    self.sdl2.SDL_HapticDestroyEffect(self.haptic, i)
        self.spring_id = self.damper_id = -1
        self.sent = None

    def pump(self) -> None:
        self.sdl2.SDL_JoystickUpdate()

    def axis(self) -> float:
        return self.sdl2.SDL_JoystickGetAxis(self.joy, 0) / 32768.0

    def close(self) -> None:
        self.stop()
        if self.haptic:
            self.sdl2.SDL_HapticClose(self.haptic)
        if self.joy:
            self.sdl2.SDL_JoystickClose(self.joy)
        self.sdl2.SDL_Quit()


class FakeWheel:
    """--fake: no device, prints what it would do (for testing the connection).
    --fake-press "3@2.0,3@5.5" presses button 3 at 2.0 s and 5.5 s (0.2 s each)."""
    name = 'fake wheel'
    nbuttons = 12

    def __init__(self, presses: str = ''):
        self.sent: Spring | None = None
        self.log: list[Spring] = []
        self.t0 = time.monotonic()
        self.presses = []
        for p in filter(None, presses.split(',')):
            b, at = p.split('@')
            self.presses.append((int(b), float(at)))

    def buttons(self) -> list[bool]:
        t = time.monotonic() - self.t0
        state = [False] * self.nbuttons
        for b, at in self.presses:
            if at <= t < at + 0.2:
                state[b] = True
        return state

    def apply(self, sp: Spring) -> None:
        if self.sent != sp:
            self.log.append(sp)
        self.sent = sp

    def pump(self) -> None: ...
    def axis(self) -> float: return 0.0
    def stop(self) -> None: self.sent = None
    def close(self) -> None: ...


# ----------------------------------------------------------------------------- rim light patterns

# bit 0 = left-most light ... bit 4 = right-most (3 green, 2 amber on a G29)
ALL = 0x1F


def _blink(t: float, hz: float, on: int, off: int = 0) -> int:
    return on if int(t * hz * 2) % 2 == 0 else off


def _steps(t: float, hz: float, steps: list[int]) -> int:
    return steps[int(t * hz * len(steps)) % len(steps)]


def led_mask(t: float, s: dict) -> int:
    """Which rim lights to show. `s` is what the car reports (see LedState.update). Highest priority first:
    FSD warnings (pulse, faster the longer they are ignored, then flashing), emergency, braking (all flash), reverse parking
    distance (lights fill up only when close), hazards, turn signals (a sweep to that side), Banish/Summon (scanner), speed warning,
    FSD on (first two lights solid, with a short fill when it starts)."""
    lvl = s.get('alert_level', 0)
    kind = s.get('alert_kind')
    if kind or lvl:
        age = max(0.0, t - s.get('alert_since', t))
        if kind in ('crash', 'takeover') or lvl >= 3:
            return _blink(t, 8, ALL)                       # "take over now": all lights flash fast
        if lvl >= 2 or age > 12:
            return _blink(t, 3.5, ALL)                      # ignored a while: all flash
        # a pulse that speeds up the longer it is ignored (1.2 Hz, up to 4 Hz after 12 s)
        return _steps(t, min(4.0, 1.2 + 0.25 * age), [0x04, 0x0E, ALL, 0x0E, 0x04, 0x00])
    if s.get('emergency'):
        return _blink(t, 3, 0x15, 0x0A)                    # pulling over for you: alternating
    if s.get('brake', 0) > 0.3 and s.get('speed', 0) > 1.5:
        return _blink(t, 7, ALL)                            # braking: all flash rapidly
    rear = s.get('rear')
    if s.get('gear') == 'R' and rear is not None and rear < 4.0:
        if rear < 0.5:
            return _blink(t, 10, ALL)                       # about to touch
        n = max(1, min(5, int((4.0 - rear) / 0.8) + 1))     # 3.2 m: 1 light ... under 0.8 m: all 5
        return (1 << n) - 1
    sig = s.get('signal')
    if sig == 'hazard':
        return _blink(t, 1.6, 0x03)                         # first lights flash with the hazards
    if sig == 'left':
        return _steps(t, 1.5, [0x04, 0x06, 0x07, 0x00])
    if sig == 'right':
        return _steps(t, 1.5, [0x04, 0x0C, 0x1C, 0x00])
    found = s.get('found_at')
    if found is not None and 0 <= t - found < 1.0:
        return _blink(t - found, 3, ALL)                    # a spot was found: three quick flashes
    if s.get('searching'):
        pos = int(t * 5) % 8                                # looking for parking: a pair of lights sweeping back and forth
        return 0x03 << (pos if pos < 4 else 7 - pos)
    if s.get('unattended'):
        pos = int(t * 7) % 8                                # Banish / Summon: a light sweeping back and forth
        return 1 << (pos if pos < 5 else 8 - pos)
    if s.get('speed_warn'):
        return _blink(t, 1.2, 0x18)                         # over the limit: the two amber lights
    if s.get('engaged'):
        since = t - s.get('engaged_since', t - 99)
        if since < 0.6:
            return (1 << min(5, int(since / 0.12) + 1)) - 1  # a quick fill when FSD starts
        return 0x03                                         # FSD on: first two lights solid
    return 0


class LedState:
    """What the lights need from the car, taken from each `state` message the relay sends."""

    def __init__(self) -> None:
        self.d: dict = {}
        self._kind = None
        self._eng = False

    def event(self, m: dict, now: float) -> None:
        """Relay events: looking for parking / spot found."""
        k = m.get('kind')
        data = m.get('data') or {}
        if k == 'parkingSearch':
            st = data.get('state') or m.get('detail')
            if st == 'looking':
                self.d['searching'] = True
            elif st == 'found':
                self.d['searching'] = False
                self.d['found_at'] = now
        elif k in ('arrived', 'disengage', 'cancelRoute'):
            self.d['searching'] = False

    def update(self, m: dict, now: float) -> None:
        ap = m.get('autopilot') or {}
        al = ap.get('alert') or {}
        kind, lvl = al.get('kind'), int(al.get('level') or 0)
        if kind in ('attention', 'lowConfidence', 'degraded', 'takeover', 'crash') or lvl:
            if self._kind != (kind, lvl // 3):
                self.d['alert_since'] = now if self._kind is None else self.d.get('alert_since', now)
            self._kind = (kind, lvl // 3)
            self.d['alert_kind'], self.d['alert_level'] = kind, lvl
        else:
            self._kind = None
            self.d['alert_kind'], self.d['alert_level'] = None, 0
        # nag levels ramp the same way even without an alert card
        nag = ap.get('nag') or {}
        if not kind and int(nag.get('level') or 0) >= 1 and ap.get('engaged'):
            self.d['alert_kind'], self.d['alert_level'] = 'attention', int(nag['level'])
            if self._kind is None:
                self.d['alert_since'] = now
            self._kind = ('attention', int(nag['level']) // 3)
        eng = bool(ap.get('engaged'))
        if eng and not self._eng:
            self.d['engaged_since'] = now
        self._eng = eng
        self.d['engaged'] = eng
        self.d['signal'] = m.get('signal')
        self.d['brake'] = float(m.get('brake') or 0)
        self.d['speed'] = abs(float(m.get('speed') or 0))
        self.d['gear'] = m.get('gear')
        self.d['rear'] = (m.get('safety') or {}).get('rearDist')
        self.d['unattended'] = bool(ap.get('unattended'))
        self.d['emergency'] = bool(ap.get('pullingOver') or (ap.get('phase') == 'parking' and ap.get('pullOver')))
        self.d['speed_warn'] = bool(m.get('speedWarning'))


# ----------------------------------------------------------------------------- G29 rev lights


class WheelLeds:
    """The row of lights on a Logitech G29 / G920 rim. Native mode takes an output report `f8 12 <mask> 00 00 00 00` (the same one the
    Linux hid-logitech driver sends); bit 0 is the left-most light. Written with hidapi (installed on first use). Nothing here is
    allowed to hurt the wheel link: every failure is logged to wheel_helper.log and the lights are simply left alone.
    UNTESTED on Windows: the log says whether a write was accepted."""

    PIDS = (0xC24F, 0xC260, 0xC262, 0xC261, 0xC266, 0xC268, 0xC24E)  # G29 (PC and PS modes), G920/G923 and relatives
    LENGTHS = (7, 8, 16, 32, 64)

    def __init__(self) -> None:
        self.dev = None
        self.mask = -1
        self.length = None
        self.layout = None
        self.retry_at = 0.0
        self.next_try = 0.0
        self.dead = False
        self.logf = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wheel_helper.log')

    def log(self, msg: str) -> None:
        try:
            with open(self.logf, 'a') as lf:
                lf.write(f'{time.strftime("%H:%M:%S")} leds: {msg}\n')
        except Exception:
            pass

    def _import(self):
        try:
            import hid  # type: ignore
            return hid
        except Exception:
            pass
        marker = self.logf + '.hidapi-tried'
        if os.path.exists(marker):
            return None
        try:
            open(marker, 'w').write('1')
            self.log('hidapi missing: installing it with pip (once)')
            import subprocess
            subprocess.run([sys.executable, '-m', 'pip', 'install', '--user', '--quiet', '--disable-pip-version-check', 'hidapi'], timeout=180,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            import hid  # type: ignore
            return hid
        except Exception as e:
            self.log(f'hidapi not available: {e}')
            return None

    def _open(self) -> bool:
        hid = self._import()
        if not hid:
            self.dead = True
            return False
        try:
            infos = [d for d in hid.enumerate(0x046D, 0) if d.get('product_id') in self.PIDS]
        except Exception as e:
            self.log(f'enumerate failed: {e}')
            return False
        if not infos:
            return False
        # the joystick interface (usage page 1, usage 4) if the list says; the first one otherwise
        infos.sort(key=lambda d: 0 if (d.get('usage_page') == 1 and d.get('usage') in (4, 5)) else 1)
        for info in infos:
            try:
                dev = hid.device()
                dev.open_path(info['path'])
                self.dev = dev
                self.log(f'opened {info.get("product_string")} pid {info.get("product_id"):#06x} usage {info.get("usage_page")}/{info.get("usage")}')
                return True
            except Exception as e:
                self.log(f'open failed: {e}')
        return False

    def set(self, mask: int, now: float | None = None) -> None:
        """Show these lights (bit 0 = left-most); asks again every few seconds in case the wheel forgot."""
        if self.dead:
            return
        now = time.monotonic() if now is None else now
        if mask == self.mask and now < self.next_try:
            return
        self.next_try = now + 5
        if self.dev is None:
            if now < self.retry_at:
                return
            if not self._open():
                self.retry_at = now + 5  # no wheel (or not yet): look again in a few seconds, not every frame
                return
        # the layout that worked once is the only one used again; first time: the Linux driver's layout, then a plain 2-byte one
        layouts = (self.layout,) if self.layout is not None else (0, 1)
        lengths = (self.length,) if self.length else self.LENGTHS
        for lay in layouts:
            for n in lengths:
                head = bytes([0xF8, 0x12, mask & 0xFF]) if lay == 0 else bytes([0x12, mask & 0xFF])
                buf = head + bytes(max(0, n - len(head)))
                try:
                    if self.dev.write(buf) > 0:
                        if self.length is None:
                            self.length, self.layout = n, lay
                            self.log(f'write accepted (layout {lay}, report length {n}), lights {mask:#04x}')
                        self.mask = mask
                        return
                except Exception:
                    pass
        if self.length is None:
            self.log('the wheel did not accept the light report (a different report layout, or another program owns the wheel)')
            self.dead = True

    def close(self) -> None:
        try:
            if self.dev is not None:
                self.set(0)
                self.dev.close()
        except Exception:
            pass


# ----------------------------------------------------------------------------- relay link


class Link:
    def __init__(self, url: str, ctl: Controller, quiet: bool = False, ffb: bool = True, name: str = 'wheel', buttons: int = 0, leds: 'WheelLeds | None' = None):
        self.url, self.ctl, self.quiet = url, ctl, quiet
        self.leds = leds
        self.ledstate = LedState()
        self.ffb, self.name, self.nbuttons = ffb, name, buttons
        self.ws = None
        self.connected = False
        self.stopping = False
        self.last_claim = 0.0
        self.thread = threading.Thread(target=self.run, daemon=True)

    def say(self, *a) -> None:
        if not self.quiet:
            print(time.strftime('%H:%M:%S'), *a, flush=True)

    def send(self, msg: dict) -> None:
        try:
            if self.ws and self.connected:
                self.ws.send(json.dumps(msg))
        except Exception:
            pass

    def claim(self) -> None:
        self.last_claim = time.time()
        if self.ffb:
            self.send({'t': 'wheel', 'helper': True})

    def run(self) -> None:
        import websocket
        while not self.stopping:
            try:
                self.ws = websocket.create_connection(self.url, timeout=5)
                self.connected = True
                self.say('connected to the relay', self.url)
                self.send({'t': 'companionHello', 'name': self.name, 'buttons': self.nbuttons})
                self.claim()
                while not self.stopping:
                    try:
                        raw = self.ws.recv()
                    except websocket.WebSocketTimeoutException:
                        self.send({'t': 'ping'})
                        continue
                    if not raw:
                        break
                    m = json.loads(raw)
                    if m.get('t') == 'state':
                        self.ctl.on_state(m, time.monotonic())
                        # what the rim lights show comes from this (see led_mask)
                        if self.leds:
                            self.ledstate.update(m, time.monotonic())
                        st = (m.get('wheel') or {}).get('status')
                        # a new car (or the mod reloading) forgets the helper: claim the wheel again
                        if self.ffb and st != 'helper' and time.time() - self.last_claim > 2:
                            self.claim()
                    elif m.get('t') == 'event' and self.leds and m.get('kind') in ('parkingSearch', 'arrived', 'disengage', 'cancelRoute'):
                        self.ledstate.event(m, time.monotonic())
                        if m.get('kind') == 'disengage':
                            self.say('FSD', m.get('kind'), m.get('detail') or '')
                    elif m.get('t') == 'event' and m.get('kind') in ('disengage', 'engaged', 'reengaged'):
                        self.say('FSD', m.get('kind'), m.get('detail') or '')
            except Exception as e:  # relay not up yet, dropped, ...
                if self.connected:
                    self.say('relay link lost:', e)
            self.connected = False
            if not self.stopping:
                time.sleep(1.5)

    def close(self) -> None:
        if self.ffb:
            self.send({'t': 'wheel', 'helper': False})  # the mod takes the wheel back
        self.stopping = True
        try:
            if self.ws:
                self.ws.close()
        except Exception:
            pass


# ----------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description='Backup FFB wheel helper for the Tesla BeamNG bridge')
    ap.add_argument('--url', default='ws://127.0.0.1:8765/', help='relay WebSocket URL (default %(default)s)')
    ap.add_argument('--device', help='wheel index or part of its name (default: first FFB wheel)')
    ap.add_argument('--strength', type=float, default=0.6, help='0..1 spring strength while FSD drives (default 0.6)')
    ap.add_argument('--invert', action='store_true', help='the wheel turns the wrong way')
    ap.add_argument('--list', action='store_true', help='list wheels and exit')
    ap.add_argument('--buttons', action='store_true', help='buttons only: leave force feedback to the mod')
    ap.add_argument('--fake', action='store_true', help='no wheel: print what it would do')
    ap.add_argument('--fake-press', default='', help=argparse.SUPPRESS)
    ap.add_argument('--seconds', type=float, default=0, help='stop after this long (testing)')
    ap.add_argument('--no-leds', action='store_true', help='do not use the rim lights')
    ap.add_argument('--quiet', action='store_true')
    a = ap.parse_args(argv)

    if a.list:
        devs = SDLWheel.list_devices()
        for i, name, haptic in devs:
            print(f'{i}: {name}{"  (force feedback)" if haptic else ""}')
        if not devs:
            print('no joysticks/wheels found')
        return 0

    try:
        wheel = FakeWheel(a.fake_press) if a.fake else SDLWheel(a.device, haptics=not a.buttons)
    except Exception as e:
        print('wheel helper:', e, file=sys.stderr)
        return 2
    ctl = Controller(a.strength, a.invert)
    leds = None if (a.no_leds or a.fake) else WheelLeds()
    link = Link(a.url, ctl, a.quiet, ffb=not a.buttons, name=wheel.name, buttons=wheel.nbuttons, leds=leds)
    if not a.quiet:
        what = 'buttons only' if a.buttons else f'buttons + force feedback, strength {ctl.strength:.2f}{" (inverted)" if a.invert else ""}'
        print(f'wheel companion: {wheel.name} ({wheel.nbuttons} buttons), {what}. Ctrl+C to stop.')
    def on_term(*_):
        raise KeyboardInterrupt  # closing the window / kill: still hand the wheel back
    for sig in ('SIGTERM', 'SIGBREAK'):
        if hasattr(signal, sig):
            signal.signal(getattr(signal, sig), on_term)
    link.thread.start()
    t0 = time.monotonic()
    last_print = 0.0
    last_pos = 0.0
    prev_buttons: list[bool] = []
    try:
        while not a.seconds or time.monotonic() - t0 < a.seconds:
            wheel.pump()
            now_buttons = wheel.buttons()
            for i, down in enumerate(now_buttons):
                if down != (prev_buttons[i] if i < len(prev_buttons) else False):
                    link.send({'t': 'wheelButton', 'button': i, 'down': down})
                    if not a.quiet and down:
                        print(f'  button {i}', flush=True)
                    if down:
                        try:
                            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'wheel_helper.log'), 'a') as lf:
                                lf.write(f'{time.strftime("%H:%M:%S")} button {i}\n')
                        except Exception:
                            pass
            prev_buttons = now_buttons
            if leds and link.connected:
                leds.set(led_mask(time.monotonic(), link.ledstate.d))
            elif leds and leds.mask not in (-1, 0):
                leds.set(0)
            sp = ctl.spring(time.monotonic()) if not a.buttons else Spring()
            wheel.apply(sp)
            if not a.buttons and sp.on and sp.coeff > 0 and time.monotonic() - last_pos > 0.03:
                last_pos = time.monotonic()
                link.send({'t': 'wheel', 'pos': round(wheel.axis(), 4)})
            if a.fake and not a.quiet and time.monotonic() - last_print > 1:
                last_print = time.monotonic()
                print(f'  spring on={sp.on} center={sp.center:+.3f} k={sp.coeff:.2f}', flush=True)
            time.sleep(1 / 60)
    except KeyboardInterrupt:
        pass
    finally:
        link.close()
        if leds:
            leds.close()
        wheel.close()
        if not a.quiet:
            print('wheel companion stopped' + ('' if a.buttons else '; the mod has the wheel again'))
    if a.fake:
        # for tests: the spring centres it used while FSD drove
        engaged = [s for s in wheel.log if s.coeff == ctl.strength]
        print(json.dumps({'springs': len(wheel.log), 'engaged': len(engaged),
                          'maxCenter': max((abs(s.center) for s in engaged), default=0)}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
