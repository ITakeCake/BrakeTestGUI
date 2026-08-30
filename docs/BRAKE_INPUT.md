# How the auto-driver presses the brake

Answering a direct question: **is the auto-driver's brake application the same
as a person holding `S` on the keyboard?**

**No.** The auto-driver applies full brake essentially instantly. A keyboard
press ramps to full brake over about **333 ms**. Proof below.

## The call we make

`lua/vehicle/extensions/brakeTest.lua` sends, every physics step:

```lua
input.event("brake", br, 1)
input.event("brake", br, 2)
```

The third argument is **not** a device or player index. It is the input
**filter**, and `event()` simply stores it (`lua/vehicle/input.lua`):

```lua
M.state[itype].val    = ivalue
M.state[itype].filter = filter
```

So the second call overwrites the first, and the filter that actually takes
effect is `2`.

## What the filter numbers mean

From `lua/common/inputFilters.lua`:

| value | constant | behaviour for brake/throttle |
|---|---|---|
| 0 | `FILTER_KBD` | `smootherKBD:getCapped(...)` — ramped |
| 1 | `FILTER_PAD` | `smootherPAD:getCapped(...)` — ramped, much faster |
| 2 | `FILTER_DIRECT` | **no smoothing at all** |
| 3 | `FILTER_KBD2` | `smootherKBD:getCapped(...)` |

`lua/vehicle/input.lua` branches on this. For anything that is not `steering`,
the `FILTER_DIRECT` branch contains **no statement that touches `ival`** — the
requested value passes straight through. Every other filter runs the value
through a temporal smoother first.

## The actual rates

`input.lua`'s `init()` defines the brake channel as:

```lua
brake = {
  smootherKBD = newTemporalSmoothing(3,   3,   1000, 0),
  smootherPAD = newTemporalSmoothing(100, 100, nil,  0),
  minLimit = 0, maxLimit = 1
}
```

The first two arguments are the in/out rates in units per second:

| path | filter | rate | 0 → full brake |
|---|---|---|---|
| Keyboard `S` | `FILTER_KBD` | 3 /s | **~333 ms** |
| Gamepad trigger | `FILTER_PAD` | 100 /s | ~10 ms |
| **Our auto-driver** | `FILTER_DIRECT` | unlimited | **one physics step (0.5 ms)** |

## Why it matters

The first third of a second of a keyboard stop is spent at partial brake. Our
runs skip that entirely, so an auto-driver stop is not comparable to a stop a
person drives on the keyboard — it is closer to a perfect, instantaneous pedal
slam than to any human input.

This is **not a bug in the measurement**. The 2 kHz distance/G figures are
correct for whatever input is applied; this only describes *what* input is
applied. Changing it would change the numbers, so it must be a deliberate,
visible choice rather than a silent fix.

## Note on the redundant pair

`input.event("brake", br, 1)` followed by `input.event("brake", br, 2)` looks
like it was written believing the third argument selects a device or a player.
It does not. The first call is dead — it is overwritten before the value is
ever read. The same pattern appears for `throttle`, `clutch` and `steering`.

Leaving both calls in place preserves current behaviour exactly, because
`FILTER_DIRECT` wins either way. Removing the `, 1)` line is a no-op refactor
and safe; changing the surviving filter is **not** — that changes results.
