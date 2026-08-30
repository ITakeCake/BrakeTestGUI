# How the auto-driver presses the brake

Question: is the auto-driver's brake application the same as a person holding
`S` on the keyboard?

**No.** The auto-driver reaches full brake in one physics step. A keyboard
press ramps to full brake over about **333 ms**.

## The call we make

`lua/vehicle/extensions/brakeTest.lua`, every physics step:

```lua
input.event("brake", br, 2)
```

The third argument is not a device or player index. It is the input **filter**.
`event()` in `lua/vehicle/input.lua` only stores it:

```lua
M.state[itype].val    = ivalue
M.state[itype].filter = filter
```

Because it is a plain state write, a second call with a different filter
overwrites the first rather than adding to it.

## What the filter numbers mean

From `lua/common/inputFilters.lua`:

| value | constant | behaviour for brake/throttle |
|---|---|---|
| 0 | `FILTER_KBD` | `smootherKBD:getCapped(...)`, ramped |
| 1 | `FILTER_PAD` | `smootherPAD:getCapped(...)`, ramped much faster |
| 2 | `FILTER_DIRECT` | **no smoothing at all** |
| 3 | `FILTER_KBD2` | `smootherKBD:getCapped(...)` |

`input.lua` branches on this. For anything that is not `steering`, the
`FILTER_DIRECT` branch contains **no statement that touches `ival`**, so the
requested value passes straight through. Every other filter runs it through a
temporal smoother first.

`FILTER_DIRECT` is not uniform across channels. For `steering` it still applies
angle-matching and `inputStabilization()`, so "direct" does not mean "raw"
there.

## The actual rates

`input.lua`'s `init()` defines the brake channel as:

```lua
brake = {
  smootherKBD = newTemporalSmoothing(3,   3,   1000, 0),
  smootherPAD = newTemporalSmoothing(100, 100, nil,  0),
  minLimit = 0, maxLimit = 1
}
```

The first two arguments are the in and out rates in units per second:

| path | filter | rate | 0 to full brake |
|---|---|---|---|
| Keyboard `S` | `FILTER_KBD` | 3 /s | **~333 ms** |
| Gamepad trigger | `FILTER_PAD` | 100 /s | ~10 ms |
| **Our auto-driver** | `FILTER_DIRECT` | unlimited | **one physics step, 0.5 ms** |

## Why it matters

The first third of a second of a keyboard stop is spent at partial brake. Our
runs skip it, so an auto-driver stop is closer to a perfect instantaneous pedal
slam than to any human input.

This is **not a measurement bug**. The 2 kHz distance and G figures are correct
for whatever input is applied; this only describes what input is applied.
Changing the filter would change the numbers, so it has to be a deliberate,
visible choice rather than a silent fix.

## History: the redundant filter-1 calls

Every channel used to be sent twice, `input.event("brake", br, 1)` followed by
`input.event("brake", br, 2)`, which reads like the third argument selects a
device or a player. It does not, so the first call was dead: overwritten before
the value was ever read. The same pattern existed for `throttle`, `clutch` and
`steering`.

The filter-1 calls were removed. Behaviour is byte-identical, because `2` had
always won. The surviving filter is deliberately left alone.

## Open question: the recorded curve shows a ramp

The recording UI does show brake ramping up, which looks like it contradicts
"instant".

Probably it does not, because these are different quantities:

- **Brake input** is the pedal value. That is what `FILTER_DIRECT` makes
  instant.
- **Brake torque** is what the sparklines plot (`wr.brakeTorque * input` in
  `brakeTest.lua`). The wheel's brake system has its own response.
- **Deceleration** must ramp regardless: weight transfers forward and the tyres
  take time to load. An instant pedal cannot produce an instant G.

So an instant input is compatible with a ramped torque and G trace.

**Unverified.** To settle it, log raw `input.brake` per physics step alongside
the torque trace and check whether that channel steps or ramps. If
`input.brake` itself ramps, the filter analysis above is wrong.
