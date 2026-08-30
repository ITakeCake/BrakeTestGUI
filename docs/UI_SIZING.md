# How HUD sizing and spacing work

Written after a long round of "the margins look wrong in-game but fine in the
mockup". Every trap below cost real time. Read this before touching
`app.html`'s `<style>` block.

## 1. What the game wraps the app in

BeamNG renders every UI app inside this (`ui/modules/apps/bng-app.html`):

```
<div class="bng-app" style="position:absolute; overflow:hidden; ...">   the app "window"
  <div ng-transclude style="width:100%; height:100%; box-sizing:border-box">
    <div class="bngApp brakeTestRoot">                                  OUR root
```

Two things about this bite.

**`.bngApp` carries its own `padding: 2px`** from `ui/entrypoints/main/main.css`,
a base rule for every stock app. Our root uses that class for its translucent
background, so without an override the game adds 2px on every side on top of
whatever padding we set. That is part of why in-game margins looked fatter than
the mockup. The root sets `padding: 0 !important`, where the `!important`
exists purely to beat `.bngApp`. Real frame padding lives on `.btBody` instead,
for the reason in section 2.

**The window's size is whatever the player dragged it to.** It is stored per
layout in `uilayout.json`, not in `app.json`. `app.json`'s `css.width/height`
is only the default for a fresh placement. So the app must survive any size.
Its aspect is pinned separately by the resize lock (3b), and its type scales
through container queries (2).

## 2. Container-query units

The root has `container-type: size`, so inside it `1cqh` is 1% of the root's
height and `1cqw` is 1% of its width. This is the same technique the original
pre-overhaul app and ABSGripGauges use, and it is what makes text grow when the
window is dragged bigger.

**Text** uses `font-size: min(Ncqh, Mcqw)`. It grows with height but is capped
by width so it cannot overflow sideways.

**Spacing is pure `cqw`, with no px layout constants.** The mockup
(`Desktop/BrakeTest_Flow_Display.html`) is 382x111.5px with root padding `6px`,
tile padding `5px 6px`, tile gap `5px`, nav padding `2px 6px`. Each is written
as its share of 382:

| mockup px | cqw |
|---|---|
| 6px | 1.57cqw |
| 5px | 1.31cqw |
| 4px | 1.05cqw |
| 3px | 0.79cqw |
| 2px | 0.52cqw |

Only borders, the scrollbar, `border-radius` and `text-shadow` stay in px.
Those are decoration, not layout.

### Two dead ends worth not repeating

**`cqh` for spacing** was the first mistake. 6px of 111.5 is 5.4cqh, which
becomes about 20px in a 380px-tall window while the width barely moved.

**`max(6px, 1.57cqw)` floors** were the second. They hedged against a
narrow-but-tall window collapsing the width-scaled padding, a shape that can no
longer occur because the aspect lock makes `1cqw = 3.426cqh` a constant. Worse,
the plain px left behind (`gap: 6px`, `margin: 2px`, a `22px` grid column) were
the `fixed_px` term in `content = k * boxHeight + fixed_px`. As the box grew,
those stopped mattering and the fill fraction drifted. Purging them is what
makes fill scale-invariant: identical at 382 wide and at 1152 wide.

### The trap that hid everything: cq units on the container itself

`cqw` and `cqh` resolve against the nearest **ancestor** query container.
`.brakeTestRoot` *is* the container, so it has no ancestor container and its
own cq units resolve against the **viewport**: the whole game screen in-game,
the browser window in a harness.

That is why the root's padding looked different in every environment and never
matched its own children. Frame padding therefore lives on `.btBody`, a child,
and never on the root. The root's only padding rule is the
`padding: 0 !important` that cancels `.bngApp`'s 2px.

## 3. The nav bar is flush to the edges on purpose

In the mockup the nav's `-6px` side margins cancel the root's `6px` side
padding, and its `-3px` bottom margin cancels the root's bottom padding, so the
bar renders edge to edge. The port reaches the same result without negative
margins: the root has no padding, frame padding sits on `.btBody` (top and
sides only), and the nav is `.btBody`'s sibling with `margin: 0.52cqw 0 0`.

If the nav ever floats off the bottom or in from the sides again, the first
suspect is padding re-added to `.brakeTestRoot`, including `.bngApp`'s 2px
(section 1), or a cq unit sneaking onto the root (section 2).

## 3b. The window is aspect-locked

BeamNG honours a **top-level** `"preserveAspectRatio": true` in app.json, a
sibling of `css` and not inside it. 31 stock apps use it (SimpleTacho,
PowerTrainDebug, Compass, SimpleDash and others). Our default is `764 x 223`,
exactly 2x the 382 x 111.5 mockup, so 3.4260:1.

The reason is that this layout is a wide strip, not a panel. Three tiles of 2
to 4 lines cannot consume arbitrary height. Dead space in the Distance tile,
measured near the mockup's scale, against window aspect:

| aspect | dead space |
|---|---|
| 3.43:1 (design) | ~20% |
| 3.0:1 | ~29% |
| 1.88:1 | ~55% |
| 1.40:1 | ~64% |

### How the lock actually behaves

Observed behaviour, not documented by the game:

- **The locked ratio is not read from app.json.** It is captured from the live
  element when the app loads, as its width divided by its height. A window
  already saved in the game's layout at some other ratio therefore locks to
  *that*. Changing the app.json default only affects a fresh placement; an
  existing one must be removed and re-added, or resized first.
- **No `min-width` or `min-height`, deliberately.** Those apply as real CSS, so
  a floor on either axis would stop the element reaching the size the lock
  computes and would silently break the ratio at small sizes. The resize
  handler has its own floors (50 wide, 40 tall) applied before the aspect
  correction, so the practical minimum is around 50 x 15 at our ratio.
- **Resize snaps to 10px increments**, so exact odd numbers cannot be reached
  by dragging. 382 x 111.5 rounds to about 380 x 110.

### What the lock does not fix

Aspect was only one of three causes of dead space. Do not read the table above
as "locked means solved". The other two were:

1. **Scale drift.** At a fixed 3.43:1, fill still fell as the window grew: 72%,
   then 63%, then 60% at 382, 764 and 982 wide. Content height is
   `k * boxHeight + fixed_px`, so as the box grows the fixed px stop mattering
   and fill converges on `k`, the sum of the cqh coefficients, which was only
   about 0.6. Aspect is irrelevant to this one. Fixed by purging the px
   constants (section 2).
2. **A structurally short tile.** Deceleration ran about 53% dead at every size
   and every ratio, 47% even in the mockup. It had two children (label, curve)
   where Distance had three and Speed Gates four, because Understeer only
   rendered when Scripted steering was on, which straight-line runs never use.
   No ratio fills a missing row. Fixed by always rendering the optional rows
   (section 4).

Measured dead space at the bottom of every Main tile is now 1.0px, the border,
at 382, 764, 982 and 1152 wide, in both the empty and post-run states.

### Consequence

Details, and often History, will always scroll, because the window can never be
made tall. That is the accepted trade for Main never having 55% dead space
again. If a tall window is ever wanted, the fix is to make Main reflow,
stacking the three tiles vertically below about 2:1, not to unlock the ratio.

## 4. Main fills itself; secondary tabs scroll

Main's `.btWidgets` grid is `flex: 1` inside `.btMainBody`, so the three tiles
stretch to the nav. The tiles then fill themselves, via three rules that only
work together:

1. **`justify-content: space-between`** on `.btWidgets .btTile`, so slack lands
   between the rows rather than in a void underneath them. Each child keeps its
   own small `margin-top` as a minimum separation, which is the only thing
   holding the layout apart at the design size where there is no slack to
   distribute.
2. **One element per tile may grow.** Deceleration's `.btGWrap` is
   `flex: 1 1 24.2cqh`, so the G curve gets taller instead of the gaps getting
   wider. A grown child consumes all free space, so `space-between` resolves to
   zero in that tile.
3. **The child count must be fixed.** Even spreading breaks if a row appears or
   vanishes, so Understeer and Actual always render, greyed via
   `.btRow.is-off` when unmeasured, instead of being `ng-if`-ed away. This is
   also what stopped Deceleration being structurally short: 47% to 100%.

Secondary tabs behave differently. Config, Settings, Details and History each
sit in `.btScroll` (`flex: 1; overflow-y: auto`), and their `.btTiles` grid uses
`grid-auto-rows: minmax(max-content, 1fr)` plus `min-height: 0`. Both halves
matter:

- `max-content` stops rows crushing and clipping their own content. The tiles
  are `overflow: hidden`, so without it the row minimum resolves to 0.
- `min-height: 0` makes the grid's height definite, so `1fr` rows share the box
  instead of all inflating to the tallest row's content.

Their tiles stay centered, like ABSGripGauges cells.

## 5. Testing without the game

The harness is committed at `tools/sizing-harness.html`. It renders the app at
four sizes at once inside a replica of the game wrapper and reports, per Main
tile, the fill percentage, the dead space at the tile's bottom, every
inter-child gap, and whether anything is clipped.

```
python -m http.server 8731        # from the repo root
```

| URL | shows |
|---|---|
| `/tools/sizing-harness.html` | four sizes with measurements |
| `...?pop` | same, populated as if a run had just finished |
| `...?op` | one size, four opacity values, over a bright backdrop |
| `...?tab=history&sc=180` | one tab, scrolled by 180px, History stocked to 25 rows |
| `...?shot=details&sc=end` | scrolled to the end, to capture content below the fold |
| `...?shot=main` | clean 1000x292 render for README screenshots |

Serve over HTTP. `app.js`'s `templateUrl` is the absolute path
`/ui/modules/apps/BrakeTest/app.html`, which will not resolve over `file://`.

What to look for:

- `DEAD-BOTTOM` should read about 1.0px, the border, on every tile at every
  size. If a number climbs with window size, a px layout constant has crept
  back in (section 2).
- `MAIN CLIPPING` should read `none`. Main has no `overflow-y`, so content that
  does not fit is silently cut off rather than becoming a scrollbar. A fill
  percentage under 100 does not prove content fits; only `scrollHeight` versus
  `clientHeight` does.

Two traps if you rebuild the harness:

- **Do not put a literal `ng-transclude` attribute on the wrapper div** to
  mimic the game. Angular treats it as its own directive and throws
  `ngTransclude:orphan`, which silently leaves the app unrendered. Use a plain
  class with the same `width`, `height` and `box-sizing`. The geometry is what
  matters, not the attribute.
- **Bootstrap each box separately.** The directive deliberately declares no
  isolate scope, so a single `angular.bootstrap` over all four boxes hands them
  one shared scope and per-box state cannot be tested.

## 6. Reloading in-game

- **Ctrl+U** reloads the UI and CEF, enough for `app.html` and `app.js`. The
  game also hot-reloads `mods/Unpacked` on save.
- **Ctrl+L** reloads all Lua, needed after `brakeTest.lua` or
  `brakeTestUI.lua`.
