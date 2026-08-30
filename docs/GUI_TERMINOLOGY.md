# BrakeTest GUI — what every control does

If the HUD and this table disagree, the HUD is wrong.

Superseded 2026-08-30 by the Flow HUD overhaul (5 tabs: Main / Config / Settings / Details / History). Old 4-tab layout's tables below have been replaced.

## Main (always visible — state + last result)

| GUI element | `$scope` source | Lua payload key / var | Behaviour |
|---|---|---|---|
| Stopping distance (big number) | `data.arc_dist_m` | `arc_dist_m` (`brakeTest.lua` updateGFX) | **True path only** — chord distance (`dist_m`) is Details-only now, dropped from Main. |
| Wheel (mini-stat beside distance) | `data.avg_wheel_angle` | `avg_wheel_angle` | Only shown when steering data exists this run. |
| Preset strip 1–8 | `activeSlot`, `presets` | — | Click loads that slot (`setSlot`) — full config push, not just a display. |
| Deceleration (big number) | `data.avg_g` | `avg_g` | Chord avg-G (matches the CSV's primary Avg G column). |
| Decel curve (behind the number) | `data.decel_path` | `decel_path` | Real per-run SVG path, ~14-point downsample of instantaneous decel samples (`EXT.decel` in `brakeTest.lua`). Decorative — never feeds the metric. |
| Understeer | `data.understeer` | `understeer` | Only shown when present. |
| Status square (top-right of Speed gates) | `detectorSquareClass()` | `state`, `detector_enabled` | Orange=waiting, yellow=recording (pulses), green=done, grey=off. **Clicking it calls `brakeTestUI.setDetectorEnabled()`** — a real feature: disables the passive detector so normal driving stops being interpreted as a run. Not a display toggle. |
| Brake / Record (Speed gates) | `btInputBrakeMph` / `btInputRecordMph` | `brakeStartSpeed` / `recordStartSpeed` | The configured targets — same fields as Config tab, shown read-only here. |
| Actual | `data.actual_start_mph` | `actual_start_mph` | The **real** airspeed at the waiting→measuring crossing (`EXT.actualStart`), not the target. Also fixed the CSV's "Actual Start Speed" column, which was silently just the target before. |
| Footer: Coast / Steer / Hz | `btInputCoastMph`, `btEnableTurning`, `btInputTelemetryHz` | — | Current config, one glance, no tab switch. |
| Start/Stop (nav, right) | `isRunning()` / `toggleRun()` | `auto_state` | Auto-driver only — independent of the status square. |

## Config tab — what THIS TEST is (saved per slot)

| GUI label | `$scope` var | Lua var (file:line) | Behaviour |
|---|---|---|---|
| Record from (mph) | `btInputRecordMph` | `recordStartSpeed` (`brakeTest.lua:812`) | Measurement window opens when speed ≤ this. Clamped ≤ Brake at. |
| Brake at (mph) | `btInputBrakeMph` | `brakeStartSpeed` | Auto-driver goes to full brake at this speed. Required. |
| Coast margin (mph) | `btInputCoastMph` | `coastOffset` | Auto-driver accelerates to Brake at + this, then lifts. 0–5. |
| Scripted steering — Enabled | `btEnableTurning` | `turningEnabled` (`:753`) | Auto-driver only; greys Steer amount/at when off. |
| Steer amount (−1…+1) | `btInputSteerAmt` | `steerAmount` (`:730`) | Held from trigger until the car stops. |
| Steer at (mph) | `btInputSteerAtMph` | `steerTriggerSpeed` (`:731`) | 0 = never. ≥ Record from: held before measuring starts. |
| Slot picker 1–8 | `activeSlot` | — | **Selects a save target only** — does not load. (Main's picker loads; this one doesn't, so editing a slot's values doesn't get clobbered by picking where to save it.) |
| Save to slot | `saveToSlot()` | `brakeTestUI.savePresets` | Dual-layer persistence: localStorage + `settings/brakeTestMod_presets.json`. |
| Apply | `applyConfig()` → `pushAllParams()` | `setTestParams` / `setSteerParams` / `setTelemetryHz` / `setTurningEnabled` | The one function every apply-path (Apply, Start run, preset load, vehicle switch) goes through, so they can't disagree. |

## Settings tab — how the APP behaves (global, never in a slot)

| GUI label | `$scope` var | Lua var / storage | Behaviour |
|---|---|---|---|
| Auto-driver — Car drives the run | `btAutoTest` | `autoTestEnabled` (`brakeTest.lua:859`) | Turning this off also turns off Scripted steering (`toggleAutoTest()` in app.js) — steering only ever runs inside the auto-driver's state machine. |
| Telemetry (Hz) | `btInputTelemetryHz` | `setTelemetryHz` | 2 kHz CSV stream rate, 0 = off. Pushes immediately on change. |
| HUD opacity | `hudOpacity` | localStorage `brakeTestHudOpacity` only — no Lua | Pure client display preference. Drives `hudRootStyle()`/`hudTileStyle()`/`hudNavStyle()` in app.js (background/border/shadow alpha, coefficients tuned so 72% ≈ the old fixed values). |
| Show last / Delete oldest past | `historyShowLast` / `historyDeletePast` | `brakeTestUI.requestHistory(n)` / `trimHistory(n)` | See History tab below. |

## Details tab — everything Lua sends that Main has no room for

| GUI label | Lua payload key |
|---|---|
| Distance (Last run) | `arc_dist_m` / `arc_dist_ft` (true path) |
| Chord | `dist_m` / `avg_g` |
| Duration | `duration_s` |
| Start speed | `actual_start_mph` |
| Car / time | `car` / `time_str` (latched once per run completion — see `EXT.car`/`EXT.timeStr` in `brakeTest.lua`, set inside `logToCSV` to reuse its already-computed `car`/`timestamp` locals rather than adding new upvalues to `onPhysicsStep`) |
| Avg steer | `avg_steer_input` |
| Avg wheel angle | `avg_wheel_angle` |
| Understeer | `understeer` |
| Heading change | `achieved_yaw` |
| Cornering score (ACS) | `acs_score` |
| Brake torque grid + per-wheel sparkline | `bf_avg`/`bf_max`/`bf_min` (existing scalar accumulators) + `torque_fl_path`/`torque_fr_path`/`torque_rl_path`/`torque_rr_path` (new — ~14-point downsample of raw per-tick torque, see `EXT.torqueFL` etc.) |

Known edge case, unchanged: Scripted steering on with Steer amount 0 still forces the cornering score on (`brakeTest.lua:627`).

## History tab — real past runs from the CSV log

| GUI element | Source |
|---|---|
| Row list | `brakeTestUI.requestHistory(limit)` (GE Lua) reads `BrakeTestResults_Straight.csv` directly, most-recent-first. Columns shown: Car, From (target record mph), Dist (True Path m), G (True Path avg G), Time (HH:MM). |
| Best-row highlight | Computed client-side in app.js (`isBest`) — the **shortest** distance among the shown rows, not the newest. |
| Show last N | Re-requests with a new limit on change. |
| Delete oldest past N (Trim history) | `brakeTestUI.trimHistory(keepCount)` — **backs up the untrimmed file first** (`.BAK_<timestamp>`) before truncating, per project convention (park, don't discard). |

First-pass limitation: `requestHistory`/`trimHistory` re-read the whole CSV every call (271 rows today — trivial). Worth revisiting if the log grows large.

## Cross-file notes for future edits

- `brakeTest.lua`'s `onPhysicsStep` is near vlua's 60-upvalue-per-function cap. All HUD-overhaul additions live in **one** table upvalue, `EXT` (mirrors the existing `LT` table pattern) — do not add new bare `local` upvalues referenced directly inside `onPhysicsStep` without checking this first.
- `EXT.car`/`EXT.timeStr` and the five `buildSparkPath()` calls are deliberately *not* computed inside `onPhysicsStep` — they're set in `logToCSV` (reusing its own locals) and `updateGFX` respectively, specifically to avoid adding more upvalues to `onPhysicsStep`.
- GE Lua (`brakeTestUI.lua`) and vehicle Lua (`brakeTest.lua`) share the same relative-path root (confirmed empirically: both `settings/brakeTestMod_presets.json` and `BrakeTestResults_Straight.csv` land in the same `current/` userpath folder).
