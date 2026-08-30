# BrakeTest GUI

Standalone BeamNG.drive in-game brake test mod: an app HUD that lets you set a target
speed, auto-triggers a measured stop, and reports distance / avg-G / duration. Split out
from the DynamicABS mod family since it has no dependency on ABS-controller internals.

Measurement runs on the **vehicle** Lua VM at 2 kHz (every physics step), never on the
render thread — which is the single most important design decision in the whole mod, and
the reason for the [stock-BeamNG bug](#the-bug-in-stock-beamngs-version) described below.

---

## The HUD

Five tabs. Every control maps to a specific Lua line — full table in
[docs/GUI_TERMINOLOGY.md](docs/GUI_TERMINOLOGY.md).

The window is **aspect-locked** to 3.4260:1 (`preserveAspectRatio` in `app.json`), so it
can be dragged to any size but never to a shape the layout was not designed for. Type and
spacing scale with the window via CSS container queries — see
[docs/UI_SIZING.md](docs/UI_SIZING.md), which exists because getting this right cost a
lot of time and the traps are not obvious.

### Main — state and last result

![Main tab](docs/images/ui_main.png)

Always-visible. Stopping distance is **true path** (see [below](#chord-vs-true-path)),
with average wheel angle beside it and the 8 quick-config slots underneath. The
deceleration curve is drawn *behind* the average-G number from the run's real 2 kHz
samples. The coloured square at the top right of Speed gates is the passive detector's
state — and it is a **real switch**, not just an indicator:

| square | meaning |
|---|---|
| grey | detector off — no run will be recorded |
| orange | armed, waiting for a stop to begin |
| yellow (pulsing) | recording right now |
| green | just finished a run |

Clicking it disables or re-enables the detector, and disabling it mid-run aborts that run.

### Config — what *this test* is

![Config tab](docs/images/ui_config.png)

Saved into one of 8 slots. `Steer at` picks **which** speed trips the scripted steering —
`Record`, `Brake`, or a `Custom` mph. Binding it to Record or Brake keeps the trigger
correct when you later edit those numbers; a hand-typed figure silently goes stale.

### Settings — how the *app* behaves

![Settings tab](docs/images/ui_settings.png)

Global, never saved into a slot: auto-driver on/off, telemetry rate, HUD opacity, and the
History query defaults. HUD opacity drives a single `--bt-a` CSS custom property, so
every surface — backgrounds, borders, shadows, and the accent fills — fades together. At
0% only the text remains.

### Details — everything Main has no room for

![Details tab](docs/images/ui_details.png)

Chord vs. true path, the full steering breakdown, and a per-wheel brake-torque grid with
real sparklines from the run (scroll down):

![Details brake torque](docs/images/ui_details_torque.png)

### History — real past runs

![History tab](docs/images/ui_history.png)

Read from the actual `BrakeTestResults_Straight.csv`, not a separate cache — so it always
agrees with the file you would open in Excel. Best run (shortest distance, not most
recent) is highlighted. The header is frozen. `Open file location` reveals the CSV in your
file browser; `Trim history` **backs up to a timestamped `.BAK_` copy before truncating**,
so a mis-click is always recoverable.

---

## How a run works

### The three speed gates

Two of them you set; the third is derived.

```
                     Brake at + Coast margin   ← accelerate to here, then lift
                     Brake at                  ← full brake applied here
                     Record from               ← measurement window OPENS here
                     ...
                     |v| <= 1.0 m/s            ← measurement window CLOSES here
```

`Record from` must be ≤ `Brake at` (the UI clamps it). Setting them equal means you start
measuring the instant the brake goes down. Setting `Record from` lower means the car is
already braking when the clock starts, which is how you measure a stop "from 60" without
including the pedal-application transient.

`Coast margin` is the overshoot: the auto-driver accelerates past `Brake at` by this much,
then lifts and coasts back down, so the brake is applied on a settled chassis rather than
mid-acceleration.

### Two independent ways to trigger a run

**Passive detector** (works with you driving, no automation): it arms whenever brake input
exceeds 0.05 while airspeed is at or near `Record from`. Just drive and brake — it
records. This is the default path and needs nothing switched on.

**Auto-driver** (Settings → Car drives the run): accelerates, holds, coasts, brakes and
stops on its own. Scripted steering only exists inside this path — a scripted steer input
during a hand-driven run would fight your own input, so the UI turns it off with the
auto-driver.

### The measurement state machine

`brakeState` is `idle → waiting → measuring → idle`, evaluated every physics step:

1. **idle → waiting** — the detector arms.
2. **waiting → measuring** — airspeed crosses below `Record from`. Position and the *true*
   airspeed at this instant are captured. That true value is logged as
   `actual_start_mph`, and it is what the HUD shows as `Actual` — the speed you really
   started from, not the speed you asked for.
3. **measuring** — every step accumulates true-path distance and samples deceleration.
4. **measuring → idle** — airspeed reaches `|v| <= 1.0 m/s`, the same cutoff stock
   `wheels.lua` uses. Results are computed, pushed to the HUD, and appended to the CSV.

---

## How we calculate stopping distance

Position sampled at the window's open and close; distance and average G derived from those
two points plus the accumulated path. **No per-frame accumulation and no self-computed
physics** — the same underlying method BeamNG's own stock `wheels.lua` uses, but sampled
on the physics thread.

### Chord vs. true path

Two numbers, because they answer different questions:

- **True path** (`arc_dist_m`) — the accumulated per-step distance actually travelled. On
  a steering run this is longer than the straight-line figure. Main shows this.
- **Chord** (`dist_m`) — the straight line between start and stop points. Equal to true
  path on a perfectly straight stop; shorter on any run with steering. Details shows this.

For a straight-line brake test they agree. The pair is what makes a *steering* brake test
interpretable.

### The bug in stock BeamNG's version

Stock BeamNG's own brake test keys start/stop detection off
`electrics.values.airspeed`, which is refreshed once per **rendered frame**, not once per
physics step. A frame-rate drop changes how stale that value is, which shifts exactly
where the test starts and stops measuring — even though the position sampling and the
math themselves are exact.

![Frame-rate-tied speed sampling bug](docs/images/stock_stopping_distance_fps_bug.png)

In plain terms: if you tie *when* you record speed to the frame rate, the moment you hit
60 mph is never quite the same moment twice. The game might look and see 61 mph, then look
again and see 59.1 — and the test starts from 59.1, purely because of *when* it happened
to look.

This mod reads speed on the physics thread at 2 kHz, so the gate lands in the same place
regardless of what the renderer is doing.

Full writeup: [Issue #1](https://github.com/ITakeCake/BrakeTestGUI/issues/1).

---

## How brake input is applied

The auto-driver's brake is **not** equivalent to a human holding `S`. It applies full
brake in a single physics step; a keyboard press ramps over roughly **333 ms**.

This is a consequence of `input.event`'s third argument being the input **filter**, not a
device index. Full proof, with the engine source lines and the rate constants, in
[docs/BRAKE_INPUT.md](docs/BRAKE_INPUT.md).

It does not affect measurement correctness — the 2 kHz figures are right for whatever
input is applied — but it does mean auto-driver runs are not comparable to keyboard-driven
ones.

---

## Architecture

```
lua/vehicle/extensions/brakeTest.lua     2 kHz state machine. Measures. Owns the truth.
        |  (vehicle VM -> GE VM)
lua/ge/extensions/brakeTestUI.lua        Bridge. Formats numbers, reads/writes the CSV.
        |  (guihooks.trigger)
ui/modules/apps/BrakeTest/app.js         Angular controller. Zero calculations.
ui/modules/apps/BrakeTest/app.html       Template + all styling.
```

Two rules hold this together:

1. **Every display number is a pre-formatted string pushed from Lua.** The UI performs no
   arithmetic on results whatsoever. If a number looks wrong, exactly one file is
   responsible.
2. **`pushAllParams()` is the only path from UI to Lua for parameters.** Apply, Start,
   preset load and vehicle switch all funnel through it, so they cannot disagree.

### Other things worth knowing

- **`onPhysicsStep` is near LuaJIT's 60-upvalue-per-function cap.** New state goes into an
  existing table (`EXT`, `LT`), never a new local. Adding one more upvalue there breaks
  the file at load with a non-obvious error.
- **Relative Lua paths resolve to the userpath's `current/` folder.** Absolute paths fail
  silently, writing nothing and reporting no error.
- **Presets persist twice** — `localStorage` for instant reads, plus a file via Lua so
  they survive a cache clear.

---

## Files

| path | role |
|---|---|
| `lua/vehicle/extensions/brakeTest.lua` | vehicle-side measurement / recording (2 kHz) |
| `lua/ge/extensions/brakeTestUI.lua` | GE-side bridge, CSV read/write |
| `lua/ge/extensions/absCmdChannel.lua` | command channel for the automation/telemetry side |
| `ui/modules/apps/BrakeTest/` | the in-game Angular HUD app |
| `tools/sizing-harness.html` | render/measure the HUD outside the game |
| `docs/` | terminology contract, UI sizing traps, brake-input proof |

## Developing

Reload after edits:

- **Ctrl+U** — UI / CEF. Enough for `app.html` and `app.js`.
- **Ctrl+L** — all Lua. Needed after either `.lua` file.

Test the HUD without launching the game:

```
python -m http.server 8731        # from the repo root
```

| URL | shows |
|---|---|
| `/tools/sizing-harness.html` | four window sizes, with fill / clipping / gap measurements |
| `…?pop` | same, populated as if a run had just finished |
| `…?op` | one size, four HUD-opacity values, over a bright backdrop |
| `…?tab=config` | a single tab, with History stocked to its 25-row ceiling |
| `…?shot=main` | clean 1000×292 render for README screenshots |

It must be served over HTTP — `app.js`'s `templateUrl` is an absolute path and will not
resolve over `file://`.

## Known issues

See the [Issues tab](https://github.com/ITakeCake/BrakeTestGUI/issues). Issue #2 (a
tolerance-error output for start-speed accuracy) can now build on the real
`actual_start_mph` field added in the HUD overhaul, which did not exist when that issue
was filed.

Open question, deliberately parked: the recorded curve shows brake ramping up, which looks
like it contradicts the instant-input finding. It probably does not — input, torque and g
are different quantities — but it is unverified. The channel to log to settle it is noted
at the end of [docs/BRAKE_INPUT.md](docs/BRAKE_INPUT.md).
