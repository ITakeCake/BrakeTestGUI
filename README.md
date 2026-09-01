# BrakeTest GUI

Standalone BeamNG.drive brake test mod. Set a target speed, get a measured stop back with distance, average G and duration.

Stock BeamNG's brake tester samples speed on the render thread, so results shift with frame rate. This mod measures on the vehicle Lua VM at 2 kHz, one sample per physics step, so frame rate stops being an input to the result. See the [wiki](https://github.com/ITakeCake/BrakeTestGUI/wiki) for the full writeup.

![Main tab](docs/images/ui_main.png)

## Install

Drop the repo folder into your BeamNG mods directory as an unpacked mod, or zip it and use the in game mod manager.

## Using it

Drive normally with the detector armed and it records a run automatically once brake input crosses 0.05 near your `Record from` speed. Results appear on the Main tab and log to `BrakeTestResults_Straight.csv`, viewable on the History tab.

Five tabs: Main (live results), Config (per test settings, 8 slots), Settings (app wide, HUD opacity etc.), Details (chord vs. true path, per wheel torque), History (past runs from the CSV). Full tour with screenshots and control mapping in the [wiki](https://github.com/ITakeCake/BrakeTestGUI/wiki/HUD-Tour).

## Files

| path | role |
|---|---|
| `lua/vehicle/extensions/brakeTest.lua` | vehicle side measurement and recording, 2 kHz |
| `lua/ge/extensions/brakeTestUI.lua` | GE side bridge, CSV read/write |
| `ui/modules/apps/BrakeTest/` | the in game Angular HUD app |
| `docs/` | terminology contract, UI sizing traps, brake input proof |

## Developing

**Ctrl+U** reloads UI and CEF after editing `app.html` or `app.js`. **Ctrl+L** reloads all Lua after editing either `.lua` file. A standalone test harness for the HUD (no game required) is documented in the [wiki](https://github.com/ITakeCake/BrakeTestGUI/wiki/Developing).

## More

- [Wiki](https://github.com/ITakeCake/BrakeTestGUI/wiki): measurement internals, the stock speed sampling bug, brake input timing, architecture
- [Issues](https://github.com/ITakeCake/BrakeTestGUI/issues): known problems and planned work
