# G29 rim lights (5 lights, bit 0 = left-most; 3 green, 2 amber)

Driven by `bridge/wheel_helper.py` (`led_mask`, tested in `beamng/test/test_wheel_leds.py`) from the relay's `state` and `event` messages. Written with hidapi: first the Linux driver's report `f8 12 <mask> 00 00 00 00`, if the wheel refuses it a plain `12 <mask>`. Untested on the real wheel: `bridge/wheel_helper.log` says which layout it accepted (also uploaded next to every black box). Never sends 0xFF (the firmware treats it as a redline strobe). Turn off with `--no-leds`. G HUB or Logitech Gaming Software running can fight it.

Priority, highest first:

| What | Lights |
|---|---|
| Take over now (alert or nag level 3, crash) | all five flash fast (8 Hz) |
| Warning ignored, nag level 2, or ignored for 12 s | all five flash (3.5 Hz) |
| FSD warning (level 1): "pay attention", unsure, degraded | a pulse that swells in and out from the middle; speeds up from 1.2 to 4 Hz the longer it is ignored |
| Pulling over for you (unresponsive / emergency) | alternating 1-3-5 / 2-4 |
| Braking (brake over 30 percent, moving) | all five flash rapidly (7 Hz) |
| Reverse, something within 4 m behind | lights fill from the left as it gets closer (1 light at 3.2 m, 5 under 0.8 m); under 0.5 m all flash fast. Nothing lights when nothing is close. Needs the car's `safety.rearDist` (static rays plus cars behind) |
| Hazards | first two lights flash with the hazards |
| Left / right signal | a sweep toward that side |
| Spot found | all five flash three times |
| Looking for parking | a pair of lights sweeping back and forth |
| Banish / Summon | a single light scanning back and forth |
| Speed Assist warning | the two amber lights blink |
| FSD on | a quick fill when it starts, then the first two lights solid |

All other times dark.

## Windows write format (changed 2026-10-08)
Working Windows programs (forza-wheel-leds, the BeamNG rev-light helpers) write `00 F8 12 <mask> 00 00 00 00` with hidapi: the first byte is
hidapi's report id (0x00, the wheel has no numbered reports), then the 7-byte command. The helper first sent `F8 12 ...` without it, which
Windows rejects or misreads. It now tries (1) with the leading 00, (2) the same with a last byte 01, (3) the bare Linux layout, (4) a plain 2-byte one,
and moves on to the wheel's other HID interfaces when one refuses everything. G HUB's own "rev lights" setting can take the lights: turn it off.
Test without the game: `python bridge\wheel_helper.py --led-test` lights 1, 2, 3, 4, 5 then none, and prints which layout worked.

## Choosing the effects (2026-10-08)
The five bits are five mirrored pairs (OptiPlex test: no single left/right light). Settings > Wheel lights in the app picks an effect per event
(FSD on, take over, warning, hard braking, hazards, signals, emergency vehicle, searching, Banish/Summon, speed) and has a Try button (plays 5 s).
Choices are saved by the relay in `bridge/wheel-lights.json`. Defaults: FSD = amber pair solid, take over and hard braking = urgent flash
(10 Hz, all lights), hazards = sweep 3, 4, 5. Effects are `EFFECTS` in `bridge/wheel_helper.py`; add one there and in `src/beamng/WheelLights.tsx`.

## Colours and the pattern editor (2026-10-08)
Quentin's wheel, outside to centre: green, green, amber, amber, red, then mirrored (green, green, amber, amber, red | red, amber, amber, green, green). So bit 0 and 1 = green pairs, bits 2 and 3 = amber, bit 4 = red. Defaults follow that: FSD on = amber (0x0C), hard braking / take over = urgent flash of amber + red (0x1C, 10 Hz), hazards = sweep amber, amber, red, light turns green = green flash.
Settings > Wheel lights has a wheel drawing that lights up and a pattern editor (frames of lights + milliseconds, looping). Patterns are saved by the relay (`wheel-lights.json`, key `custom`, ids `c_xxxxxx`) and the helper plays them (`frames_mask`). A dead handle (wheel power-cycled) is reopened by the helper; each change of what it shows is logged as `leds: show 0x..` in wheel_helper.log.
