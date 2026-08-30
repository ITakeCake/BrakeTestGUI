# What every control does

If the HUD and this table disagree, the HUD is wrong.

Covers all five tabs: Main, Config, Settings, Details, History.

## Main: state and last result

| GUI element | `$scope` source | Lua payload key | Behaviour |
|---|---|---|---|
| Stopping distance | `data.arc_dist_m` | `arc_dist_m` | True path only. Chord (`dist_m`) is Details-only. |
| Wheel | `data.avg_wheel_angle` | `avg_wheel_angle` | Shown only when steering data exists. |
| Preset strip 1-8 | `activeSlot`, `presets` | none | Click loads that slot (`setSlot`). Full config push, not a display change. |
| Deceleration | `data.avg_g` | `avg_g` | Chord avg-G, matching the CSV's primary Avg G column. |
| Decel curve | `data.decel_path` | `decel_path` | 64-point downsample of instantaneous decel samples (`EXT.decel`). Decorative, never feeds the metric. |
| Understeer | `data.understeer` | `understeer` | Always rendered. Greyed `--` via `.btRow.is-off` when unmeasured, so the tile keeps a fixed child count. |
| Status square | `detectorSquareClass()` | `state`, `detector_enabled` | Orange waiting, yellow recording (pulses), green done, grey off. Clicking calls `brakeTestUI.setDetectorEnabled()`. A real switch, not a display toggle. |
| Brake / Record | `btInputBrakeMph`, `btInputRecordMph` | `brakeStartSpeed`, `recordStartSpeed` | Configured targets, read-only here. |
| Actual | `data.actual_start_mph` | `actual_start_mph` | Real airspeed at the waiting-to-measuring crossing (`EXT.actualStart`), not the target. Also fixed the CSV's "Actual Start Speed" column, which had silently been the target. Always rendered, greyed when absent. |
| Footer summary | `btInputCoastMph`, `btEnableTurning`, `btInputTelemetryHz` | none | Current config at a glance. |
| Start / Stop | `isRunning()`, `toggleRun()` | `auto_state` | Auto-driver only. Independent of the status square. |

## Config: what THIS TEST is, saved per slot

| GUI label | `$scope` var | Lua var | Behaviour |
|---|---|---|---|
| Record from | `btInputRecordMph` | `recordStartSpeed`, set by `setTestParams()` | Measurement window opens at or below this. Clamped to Brake at. |
| Brake at | `btInputBrakeMph` | `brakeStartSpeed` | Auto-driver goes to full brake here. Required. |
| Coast margin | `btInputCoastMph` | `coastOffset` | Auto-driver accelerates to Brake at plus this, then lifts. Range 0 to 5. |
| Scripted steering, Enabled | `btEnableTurning` | `turningEnabled`, set by `setTurningEnabled()` | Auto-driver only. Greys the steer fields when off. |
| Steer amount | `btInputSteerAmt` | `steerAmount`, set by `setSteerParams()` | Range -1 to +1. Held from trigger until the car stops. |
| Steer at (Record / Brake / Custom) | `btSteerAtMode` | resolved into `steerTriggerSpeed`, set by `setSteerParams()` | Picks which speed trips the steering. Lua only ever receives an absolute mph; the mode decides which number that is, so Record and Brake stay correct when those values are edited later. |
| Custom steer speed | `btInputSteerAtMph` | same | Shown only in Custom mode. 0 means never. |
| Slot picker 1-8 | `activeSlot` via `selectSlot()` | none | Selects a save target only, does not load. Must be a function on the controller scope: an inline `activeSlot = s` assigns into `ng-repeat`'s child scope and every slot latches its own copy. |
| Save to slot | `saveToSlot()` | `brakeTestUI.savePresets` | Dual persistence: localStorage plus `settings/brakeTestMod_presets.json`. Stores `steerAtMode`; a preset without one reads as Custom. |
| Apply | `applyConfig()` to `pushAllParams()` | `setTestParams`, `setSteerParams`, `setTelemetryHz`, `setTurningEnabled` | The one function every apply path goes through (Apply, Start, preset load, vehicle switch), so they cannot disagree. |

## Settings: how the APP behaves, global, never in a slot

| GUI label | `$scope` var | Lua var / storage | Behaviour |
|---|---|---|---|
| Car drives the run | `btAutoTest` | `autoTestEnabled`, set by `setAutoTestEnabled()` | Turning it off also turns off Scripted steering (`toggleAutoTest()`), since steering only runs inside the auto-driver's state machine. |
| Telemetry Hz | `btInputTelemetryHz` | `setTelemetryHz` | 2 kHz CSV stream rate, 0 is off. Pushes immediately on change. |
| HUD opacity | `hudOpacity` | localStorage `brakeTestHudOpacity`, no Lua | Client display preference. The directive's `link` fn mirrors it into the `--bt-a` CSS custom property; every translucent surface derives from that in the stylesheet. Coefficients are the old fixed alphas divided by 0.72, so 72% reproduces the original look. Must use `setProperty`: jqLite's `css()` ignores custom properties. |
| Show last | `historyShowLast` | `requestHistory(n)` | Capped at 25 by `clampShowLast()`. |
| Delete oldest past | `historyDeletePast` | `trimHistory(n)` | See History below. |

## Details: everything Main has no room for

| GUI label | Lua payload key |
|---|---|
| Distance | `arc_dist_m`, `arc_dist_ft` (true path) |
| Chord | `dist_m`, `avg_g` |
| Duration | `duration_s` |
| Start speed | `actual_start_mph` |
| Car / time | `car`, `time_str`. Latched once per run in `logToCSV` to reuse its existing locals rather than adding upvalues to `onPhysicsStep`. |
| Avg steer | `avg_steer_input` |
| Avg wheel angle | `avg_wheel_angle` |
| Understeer | `understeer` |
| Heading change | `achieved_yaw` |
| Cornering score | `acs_score` |
| Brake torque grid and sparklines | `bf_avg`, `bf_max`, `bf_min` scalars, plus `torque_fl_path` and siblings: 64-point downsamples of raw per-tick torque (`EXT.torqueFL` etc). |

Known edge case: Scripted steering on with Steer amount 0 still forces the
cornering score on, because `isActuallyCornering` ORs `turningEnabled` with the
measured yaw rather than checking that any steering was actually commanded.

## History: real past runs from the CSV

| GUI element | Source |
|---|---|
| Row list | `requestHistory(limit)` reads `BrakeTestResults_Straight.csv` directly, most recent first. Columns: Car, From (target record mph), Dist (true path m), G (true path avg G), Time. |
| Frozen header | `position: sticky` on `.btHistHead`. Its background is fully opaque and does not follow `--bt-a`: rows scroll underneath, and their text ghosted through even at 0.92 alpha. |
| Best-row highlight | Computed client-side (`isBest`). Shortest distance among shown rows, not the newest. |
| Show last N | Re-requests on change, capped at 25. |
| Open file location | `brakeTestUI.openHistoryFolder()`. `Engine.Platform.exploreFolder` on `FS:getFileRealPath(HISTORY_FILE)`, which opens the folder with the CSV selected. |
| Trim history | `trimHistory(keepCount)`. Backs up the untrimmed file to `.BAK_<timestamp>` before truncating, per project convention: park, do not discard. |

`requestHistory` and `trimHistory` re-read the whole CSV every call. Trivial at
today's row count; worth revisiting if the log grows large.

## Cross-file notes for future edits

- `brakeTest.lua`'s `onPhysicsStep` is near vlua's 60-upvalue-per-function cap.
  All HUD-overhaul additions live in one table upvalue, `EXT`, mirroring the
  existing `LT` pattern. Do not add bare `local` upvalues referenced inside
  `onPhysicsStep` without checking this first.
- `EXT.car`, `EXT.timeStr` and the five `buildSparkPath()` calls are
  deliberately computed outside `onPhysicsStep`, in `logToCSV` and `updateGFX`
  respectively, for the same reason.
- GE Lua and vehicle Lua share the same relative-path root. Confirmed
  empirically: `settings/brakeTestMod_presets.json` and
  `BrakeTestResults_Straight.csv` both land in the same `current/` userpath
  folder.
- `input.event`'s third argument is the input filter, not a device index. See
  [BRAKE_INPUT.md](BRAKE_INPUT.md).
