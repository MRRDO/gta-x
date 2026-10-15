"""Wheel helper against the fake game: harness (real mod Lua, wheel pulled by the helper's
spring) -> relay -> wheel_helper.py --fake, while FSD drives a route with turns.
    python3 beamng/test/test_wheel_helper.py     (needs luajit, lua-socket, lua-dkjson, node, websocket-client)
Also unit-checks the helper's spring logic."""
import json, os, subprocess, sys, threading, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'bridge'))
import wheel_helper as W
import websocket

results = []
def check(name, ok, info=''):
    results.append(ok)
    print(('PASS' if ok else 'FAIL') + '  ' + name + (f'  ({info})' if info else ''), flush=True)

# --- logic
c = W.Controller(0.6)
check('no state: wheel released', not c.spring(0).on)
c.on_state({'speed': 10, 'steering': 0.3, 'autopilot': {'engaged': True, 'mode': 'fsd'}, 'wheel': {'target': 0.25, 'ratio': 1.2}}, 0)
sp = c.spring(0.1)
check('FSD on: spring centred on the target', sp.on and abs(sp.center - 0.25) < 1e-9 and sp.coeff == 0.6)
check('stale state (game paused): released', not c.spring(2.0).on)
c.on_state({'speed': 10, 'steering': 0.3, 'autopilot': {'engaged': True, 'mode': 'fsd'}, 'wheel': {'ratio': 1.5}}, 0)
check('no target: steering / ratio', abs(c.spring(0).center - 0.2) < 1e-9)
c.on_state({'speed': 20, 'steering': 0.3, 'autopilot': {'engaged': True, 'mode': 'tacc'}, 'wheel': {'target': 0.25}}, 0)
sp = c.spring(0)
check('TACC: just light centring', sp.center == 0 and sp.coeff < 0.4)
ci = W.Controller(0.6, invert=True)
ci.on_state({'speed': 1, 'autopilot': {'engaged': True, 'mode': 'fsd'}, 'wheel': {'target': 0.25}}, 0)
check('--invert flips the centre', abs(ci.spring(0).center + 0.25) < 1e-9)

# --- integration
root = os.path.join(os.path.dirname(__file__), '..', '..')
PORT = 18771
procs = []
env = dict(os.environ, HARNESS_SPEED='6', HARNESS_QUIET='1', HARNESS_HELPER_SIM='1')
procs.append(subprocess.Popen(['luajit', 'beamng/test/harness.lua'], cwd=root, env=env))
time.sleep(0.5)
procs.append(subprocess.Popen(['node', '--import', 'tsx', 'bridge/relay.ts', '--port', str(PORT), '--quiet'], cwd=root))
helper = None
try:
    ws = None
    for _ in range(60):
        try:
            ws = websocket.create_connection(f'ws://127.0.0.1:{PORT}/', timeout=5); break
        except Exception:
            time.sleep(0.25)
    helper = subprocess.Popen([sys.executable, 'bridge/wheel_helper.py', '--fake', '--quiet', '--seconds', '60', '--url', f'ws://127.0.0.1:{PORT}/'],
                              cwd=root, stdout=subprocess.PIPE, text=True)
    state = {}
    events = []
    stop = False
    def reader():
        while not stop:
            try:
                m = json.loads(ws.recv())
            except Exception:
                return
            if m.get('t') == 'state': state.update(m)
            elif m.get('t') == 'event': events.append(m)
    threading.Thread(target=reader, daemon=True).start()
    def pump():
        while not stop:
            try: ws.send(json.dumps({'t': 'attention', 'state': 'ok'}))
            except Exception: return
            time.sleep(0.15)
    threading.Thread(target=pump, daemon=True).start()
    t0 = time.time()
    while time.time() - t0 < 15 and (state.get('wheel') or {}).get('status') != 'helper':
        time.sleep(0.1)
    check('mod hands the wheel to the helper', (state.get('wheel') or {}).get('status') == 'helper', str((state.get('wheel') or {}).get('status')))
    ws.send(json.dumps({'t': 'navigate', 'to': [300, 150, 0]}))
    time.sleep(1)
    ws.send(json.dumps({'t': 'autopilot', 'mode': 'fsd', 'profile': 'standard'}))
    maxPos = maxErr = 0.0
    t0 = time.time()
    while time.time() - t0 < 40 and not any(e.get('kind') in ('arrived', 'disengage') for e in events):
        w = state.get('wheel') or {}
        if (state.get('autopilot') or {}).get('engaged') and w.get('target') is not None:
            maxPos = max(maxPos, abs(w.get('pos') or 0))
            maxErr = max(maxErr, abs((w.get('pos') or 0) - w['target']))
        time.sleep(0.05)
    kinds = [e.get('kind') + ':' + str(e.get('detail')) for e in events]
    check('FSD drives the route with the helper (no false takeover)', any(k.startswith('arrived') for k in kinds) and not any(k.startswith('disengage:steer') for k in kinds), ', '.join(kinds[-6:]))
    check('physical wheel turns with the car', maxPos > 0.1, f'max {maxPos * 450:.0f} deg')
    check('wheel stays near the target', maxErr < 0.2, f'max error {maxErr * 450:.0f} deg')
    stop = True
    ws.close()
    helper.terminate()
    out = helper.communicate(timeout=10)[0].strip().splitlines()
    summary = json.loads(out[-1]) if out and out[-1].startswith('{') else {}
    check('helper sent springs that followed FSD', summary.get('engaged', 0) > 5 and summary.get('maxCenter', 0) > 0.1, json.dumps(summary))
finally:
    for p in procs + ([helper] if helper else []):
        try: p.kill()
        except Exception: pass

failed = results.count(False)
print(f'\n{len(results) - failed} passed, {failed} failed')
sys.exit(1 if failed else 0)
