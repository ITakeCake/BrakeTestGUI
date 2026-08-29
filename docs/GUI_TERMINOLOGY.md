# BrakeTest GUI — what every control does

If the HUD and this table disagree, the HUD is wrong.

## Settings panel

| GUI label | `$scope` var | Lua var (file:line) | Behaviour |
|---|---|---|---|
| Brake at (mph) | `btInputBrakeMph` | `brakeStartSpeed` (`brakeTest.lua:723`; m/s) | Auto-driver goes to full brake when speed ≤ this (`:374`). Required; everything else is relative to it. |
| Record from (mph) | `btInputRecordMph` | `recordStartSpeed` (`:724`) | Measurement window opens when speed ≤ this (`:462`). Clamped ≤ Brake at. Defaults to Brake at. |
| Coast margin (mph) | `btInputCoastMph` | `coastOffset` (`:725`) | Auto-driver accelerates to Brake at + this, then lifts and coasts down (`:333`). 0–5. |
| Automate run (checkbox) | `btAutoTest` | `autoTestEnabled` (`:758`) | Car drives itself: accelerate → coast → brake → stop. Shows START/STOP RUN. |
| Scripted steering (checkbox, "Automated run only" group) | `btEnableTurning` | `turningEnabled` (`:753`) | When on **and** the run is automated, the auto-driver holds Steer amount once speed ≤ Steer at (`:368,387`). Also forces the cornering score on (`:627`). Disabled/greyed unless Automate run is checked. |
| Steer amount (−1 … +1) | `btInputSteerAmt` | `steerAmount` (`:730`) | Steering input held from trigger until the car stops (`:257`). Sign = BeamNG steering axis; direction not yet confirmed in-game. |
| Steer at (mph) | `btInputSteerAtMph` | `steerTriggerSpeed` (`:731`; m/s) | Steering engages the first physics step speed ≤ this, during coast or braking (`:368,387`). 0 = never. Clamped 0 … Brake at + Coast margin. |
| "= Record + 0.5" button | — | — | Fills Steer at with Record from + 0.5, so steering is already held when the measurement window opens. |
| Telemetry (Hz) | `btInputTelemetryHz` | `setTelemetryHz` (`brakeTestUI.lua`) | 2 kHz CSV stream rate, 0 = off. |
| Apply settings | `applySettings()` | — | Pushes all of the above. |
| Presets 1–6 / SET | — | — | Saves/loads the settings above under a slot. |

Hints shown inline:
- Under speeds: "Accelerates to Brake at + Coast margin, lifts, brakes at Brake at, measures from Record from."
- Under steering group: "Steering holds from Steer at until stopped. ≥ Record from: held before measuring starts. < Record from: begins mid-stop."

## Result block

| GUI label | Lua payload key |
|---|---|
| Distance (chord) | `dist_m` / `dist_ft` |
| Avg G (chord) | `avg_g` |
| Distance (true path) | `arc_dist_m` / `arc_dist_ft` |
| Avg G (true path) | `arc_avg_g` |
| Time … from | `duration_s`, `start_speed_mph` |
| Avg steer (0–1) | `avg_steer_input` |
| Avg wheel angle | `avg_wheel_angle` |
| Understeer | `understeer` |
| Heading change | `achieved_yaw` |
| Cornering score (ACS) | `acs_score` |

Known edge case, documented not changed: Scripted steering on with Steer amount 0 still forces the cornering score (`brakeTest.lua:627`). Lua-side, out of scope for this UI pass.
