#!/usr/bin/env python3
"""Backup wheel helper: turns a force-feedback wheel (Logitech G29 etc.) with FSD using SDL
haptics, for when the mod can't drive the wheel motor from inside BeamNG (the wheel panel on
the test page says "unavailable", or the wheel doesn't move).

It connects to the relay, tells the car the helper owns the wheel (the mod then leaves the
motor alone), and holds a spring effect centred where FSD is steering. Grab the wheel and
turn it past the spring and FSD hands over, same as always. With FSD off it gives a light
speed-dependent centring spring so the wheel isn't dead.

Setup (once):
    pip install pysdl2 pysdl2-dll websocket-client
    In BeamNG: Options > Controls > your wheel > Force feedback: OFF (the helper does it now;
    two programs fighting over the motor feels awful).
Run (with the relay running):
    python bridge/wheel_helper.py                 (or wheel_helper.bat)
    python bridge/wheel_helper.py --list          (show wheels SDL can see)
    python bridge/wheel_helper.py --invert        (the wheel turns the wrong way)
    python bridge/wheel_helper.py --strength 0.8  --url ws://127.0.0.1:8765/
Ctrl+C stops it and hands the wheel back to the mod.
"""

from __future__ import annotations

import argparse
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
        # FSD off: light centring that firms up with speed, like the game's own FFB
        k = clamp(0.06 + speed * 0.012, 0.06, 0.4) * self.strength / 0.6
        return Spring(center=0.0, coeff=clamp(k, 0, 1), saturation=clamp(k * 1.5, 0, 1), damper=0.1, on=True)


# ----------------------------------------------------------------------------- SDL backend


class SDLWheel:
    def __init__(self, device: str | None):
        import ctypes
        import sdl2
        self.sdl2, self.ctypes = sdl2, ctypes
        sdl2.SDL_SetHint(b'SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS', b'1')  # BeamNG has the focus
        if sdl2.SDL_Init(sdl2.SDL_INIT_JOYSTICK | sdl2.SDL_INIT_HAPTIC) != 0:
            raise RuntimeError('SDL init failed: ' + sdl2.SDL_GetError().decode())
        self.joy = self.haptic = None
        idx = self.pick(device)
        if idx is None:
            raise RuntimeError('no force-feedback wheel found (plugged in? try --list)')
        self.joy = sdl2.SDL_JoystickOpen(idx)
        self.name = sdl2.SDL_JoystickName(self.joy).decode(errors='replace')
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
        self.spring_id = self.damper_id = -1
        self.sent: Spring | None = None

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

    def pick(self, device: str | None) -> int | None:
        devs = self.list_devices()
        if device is not None:
            for i, name, _ in devs:
                if device.isdigit() and int(device) == i or device.lower() in name.lower():
                    return i
            return None
        haptic = [d for d in devs if d[2]]
        # prefer something that looks like a wheel
        for i, name, _ in haptic:
            if any(k in name.lower() for k in ('wheel', 'g29', 'g920', 'g923', 'racing', 'fanatec', 'thrustmaster', 'moza', 'simagic')):
                return i
        return haptic[0][0] if haptic else None

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
                raise RuntimeError('spring effect: ' + sdl2.SDL_GetError().decode())
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

    def close(self) -> None:
        self.stop()
        if self.haptic:
            self.sdl2.SDL_HapticClose(self.haptic)
        if self.joy:
            self.sdl2.SDL_JoystickClose(self.joy)
        self.sdl2.SDL_Quit()


class FakeWheel:
    """--fake: no device, prints what it would do (for testing the connection)."""
    name = 'fake wheel'

    def __init__(self):
        self.sent: Spring | None = None
        self.log: list[Spring] = []

    def apply(self, sp: Spring) -> None:
        if self.sent != sp:
            self.log.append(sp)
        self.sent = sp

    def pump(self) -> None: ...
    def stop(self) -> None: self.sent = None
    def close(self) -> None: ...


# ----------------------------------------------------------------------------- relay link


class Link:
    def __init__(self, url: str, ctl: Controller, quiet: bool = False):
        self.url, self.ctl, self.quiet = url, ctl, quiet
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
        self.send({'t': 'wheel', 'helper': True})

    def run(self) -> None:
        import websocket
        while not self.stopping:
            try:
                self.ws = websocket.create_connection(self.url, timeout=5)
                self.connected = True
                self.say('connected to the relay', self.url)
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
                        st = (m.get('wheel') or {}).get('status')
                        # a new car (or the mod reloading) forgets the helper: claim the wheel again
                        if st != 'helper' and time.time() - self.last_claim > 2:
                            self.claim()
                    elif m.get('t') == 'event' and m.get('kind') in ('disengage', 'engaged', 'reengaged'):
                        self.say('FSD', m.get('kind'), m.get('detail') or '')
            except Exception as e:  # relay not up yet, dropped, ...
                if self.connected:
                    self.say('relay link lost:', e)
            self.connected = False
            if not self.stopping:
                time.sleep(1.5)

    def close(self) -> None:
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
    ap.add_argument('--fake', action='store_true', help='no wheel: print what it would do')
    ap.add_argument('--seconds', type=float, default=0, help='stop after this long (testing)')
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
        wheel = FakeWheel() if a.fake else SDLWheel(a.device)
    except Exception as e:
        print('wheel helper:', e, file=sys.stderr)
        return 2
    ctl = Controller(a.strength, a.invert)
    link = Link(a.url, ctl, a.quiet)
    if not a.quiet:
        print(f'wheel helper: {wheel.name}, strength {ctl.strength:.2f}{" (inverted)" if a.invert else ""}. Ctrl+C to stop.')
    def on_term(*_):
        raise KeyboardInterrupt  # closing the window / kill: still hand the wheel back
    for sig in ('SIGTERM', 'SIGBREAK'):
        if hasattr(signal, sig):
            signal.signal(getattr(signal, sig), on_term)
    link.thread.start()
    t0 = time.monotonic()
    last_print = 0.0
    try:
        while not a.seconds or time.monotonic() - t0 < a.seconds:
            wheel.pump()
            sp = ctl.spring(time.monotonic())
            wheel.apply(sp)
            if a.fake and not a.quiet and time.monotonic() - last_print > 1:
                last_print = time.monotonic()
                print(f'  spring on={sp.on} center={sp.center:+.3f} k={sp.coeff:.2f}', flush=True)
            time.sleep(1 / 60)
    except KeyboardInterrupt:
        pass
    finally:
        link.close()
        wheel.close()
        if not a.quiet:
            print('wheel helper stopped; the mod has the wheel again')
    if a.fake:
        # for tests: the spring centres it used while FSD drove
        engaged = [s for s in wheel.log if s.coeff == ctl.strength]
        print(json.dumps({'springs': len(wheel.log), 'engaged': len(engaged),
                          'maxCenter': max((abs(s.center) for s in engaged), default=0)}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
