# BrakeTest GUI

Standalone BeamNG.drive in-game brake test mod: an app HUD that lets you set a target
speed, auto-triggers a measured stop, and reports distance/avg-G/duration. Split out
from the DynamicABS mod family since it has no dependency on ABS-controller internals.

## Layout

- `lua/vehicle/extensions/brakeTest.lua` — vehicle-side measurement/recording (2kHz state machine)
- `lua/ge/extensions/brakeTestUI.lua` — GE-side bridge pushing state to the UI app
- `lua/ge/extensions/absCmdChannel.lua` — command channel used by the automation/telemetry side
- `ui/modules/apps/BrakeTest/` — the in-game Angular HUD app

## Settings explained

Full table with the Lua line each control maps to: [docs/GUI_TERMINOLOGY.md](docs/GUI_TERMINOLOGY.md).

Short version — an automated run does: accelerate to **Brake at + Coast margin** → lift and
coast → full brake at **Brake at** → measurement window opens at **Record from** → stop.
**Scripted steering** (automated runs only) holds **Steer amount** from the moment speed
drops to **Steer at** until the car stops. Set Steer at ≥ Record from to have the wheel
already turned when measuring starts, or below it to turn mid-stop.

## How we calculate stopping distance

This mod measures a stop directly: it samples position when the vehicle crosses
below the target speed (`state = "waiting" → "measuring"`), samples position again
once speed drops to ~1 m/s, and computes distance/avg-G from those two points. No
per-frame accumulation, no self-computed physics — same underlying method BeamNG's
own stock `wheels.lua` uses.

Stock BeamNG's version of this, though, has a bug worth knowing about: it keys its
start/stop detection off `electrics.values.airspeed`, which is only refreshed once
per *rendered frame*, not once per physics step. That means a frame-rate drop (e.g.
alt-tabbing) changes how stale that speed value gets, which shifts exactly where
the test starts and stops measuring — even though the position sampling and math
are exact.

![Frame-rate-tied speed sampling bug](docs/images/stock_stopping_distance_fps_bug.png)

In plain terms: if you tie *when* you record speed to the frame rate, the moment
you hit 60mph is never quite the same moment twice. The game might check in and
see 61mph, then next check sees 59.1mph — and the test starts probing from 59.1mph
instead of 60mph, purely because of *when* it happened to look.

Full writeup: [Issue #1 — Issues with some current designs](https://github.com/ITakeCake/BrakeTestGUI/issues/1).

## Known issues

See the [Issues tab](https://github.com/ITakeCake/BrakeTestGUI/issues) — starting with the
frame-rate-tied speed sampling above and a planned tolerance-error output for the GUI.
