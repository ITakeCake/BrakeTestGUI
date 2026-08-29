# BrakeTest GUI

Standalone BeamNG.drive in-game brake test mod: an app HUD that lets you set a target
speed, auto-triggers a measured stop, and reports distance/avg-G/duration. Split out
from the DynamicABS mod family since it has no dependency on ABS-controller internals.

## Layout

- `lua/vehicle/extensions/brakeTest.lua` — vehicle-side measurement/recording (2kHz state machine)
- `lua/ge/extensions/brakeTestUI.lua` — GE-side bridge pushing state to the UI app
- `lua/ge/extensions/absCmdChannel.lua` — command channel used by the automation/telemetry side
- `ui/modules/apps/BrakeTest/` — the in-game Angular HUD app

## Known issues

See the Issues tab — starting with stock-BeamNG's frame-rate-tied speed sampling and
its implications for this mod's own measurement accuracy.
