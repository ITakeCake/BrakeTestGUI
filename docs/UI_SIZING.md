# BrakeTest HUD — how sizing and spacing actually work

Written after a long round of "the margins look wrong in-game but fine in the
mockup". Every gotcha below cost real time. Read this before touching
`app.html`'s `<style>` block.

## 1. What the game wraps the app in

BeamNG renders every UI app inside this (`ui/modules/apps/bng-app.html`):

```
<div class="bng-app" style="position:absolute; overflow:hidden; …">   ← the app "window"
  <div ng-transclude style="width:100%; height:100%; box-sizing:border-box">
    <div class="bngApp brakeTestRoot">                                 ← OUR root
```

Two things about this bite:

- **`.bngApp` has its own `padding: 2px`** (`ui/entrypoints/main/main.css`).
  It's a base rule for every stock app. Our root uses that class for the
  translucent background, so unless we override it, the game adds 2px on
  every side *on top of* whatever padding we set. That's part of why in-game
  margins looked fatter than the mockup. The root sets `padding: 0 !important`
  — the `!important` exists purely to beat `.bngApp`'s rule — and the real
  frame padding lives on `.btBody` instead (see §2 for why it can't live on
  the root).
- **The app window's size is whatever the player dragged it to.** It's stored
  per-layout in the game's `uilayout.json`, *not* in `app.json` — `app.json`'s
  `css.width/height` is only the default for a fresh placement. The app must
  therefore survive any *size*; its *aspect* is pinned separately by the
  resize lock (§3b), and its type scales via container queries (§2).

## 2. Container-query units, and why the mockup's px numbers are the source of truth

The root has `container-type: size`, so inside it `1cqh` = 1% of the root's
height and `1cqw` = 1% of its width. That is the trick the original
(pre-overhaul) app and ABSGripGauges use, and it's what makes text grow when
the player drags the window bigger.

**Text** is sized as `font-size: min(Ncqh, Mcqw)` — grows with height, but
capped by width so it never overflows sideways. The cqw cap is tuned to cross
over at about a 2.5:1 window; wider than that, height wins; taller than that,
width wins.

**Spacing is pure `cqw`. There are no px layout constants left.** The mockup
(`Desktop/BrakeTest_Flow_Display.html`) is 382×111.5px with root padding `6px`,
tile padding `5px 6px`, tile gap `5px`, nav padding `2px 6px`. Every one of
those is expressed as its share of 382: `6px → 1.57cqw`, `5px → 1.31cqw`,
`4px → 1.05cqw`, `3px → 0.79cqw`, `2px → 0.52cqw`. Only borders, the
scrollbar, `border-radius` and `text-shadow` stay px — they are decoration,
not layout.

Two dead ends are worth not repeating:

- **`cqh` for spacing** was the first mistake: 6px of 111.5 = 5.4cqh, which
  becomes ~20px in a 380px-tall window while the width barely moved.
- **`max(6px, 1.57cqw)` floors** were the second. They were a hedge against a
  narrow-but-tall window collapsing the width-scaled padding — a shape that
  **can no longer occur**, because the aspect lock (§3b) makes
  `1cqw = 3.426cqh` a constant. Worse, the plain px that stayed behind
  (`gap: 6px`, `margin: 2px`, a `22px` grid column) were the `fixed_px` term
  in `content = k × boxHeight + fixed_px`: as the box grew they stopped
  mattering and the fill fraction drifted. Purging them is what makes fill
  **scale-invariant** — identical at 382 wide and at 1152 wide.

### The gotcha that hid everything: cq units on the container itself

`cqw`/`cqh` resolve against the nearest **ancestor** query container. On
`.brakeTestRoot` — which *is* the container — there is no ancestor container,
so they resolve against the **viewport** (the whole game screen in-game, the
browser window in a harness). That's why the root's padding looked different
in every environment and never matched its own children. Frame padding
therefore lives on `.btBody` (a child), never on the root. The root's only
padding rule is `padding: 0 !important` to cancel `.bngApp`'s 2px.

## 3. The nav bar is flush to the edges on purpose

In the mockup the nav's `-6px` side margins cancel the root's `6px` side
padding, and its `-3px` bottom margin cancels the root's `3px` bottom padding,
so the bar renders edge-to-edge and flush with the bottom. The port gets the
same result without negative margins: the root has no padding at all, the
frame padding sits on `.btBody` (top/sides only), and the nav is `.btBody`'s
sibling with `margin: 2px 0 0` — so it naturally spans the full width and
sits on the bottom edge.

If the nav ever floats off the bottom or in from the sides again, the first
suspect is padding being re-added to `.brakeTestRoot` (including `.bngApp`'s
2px — see §1) or a cq unit sneaking onto the root (§2).

## 3b. The window is aspect-locked (preserveAspectRatio)

This layout is a **wide strip**, not a panel: three tiles of 2-4 lines each
can't consume height. Dead space in the Distance tile, measured near the
mockup's scale, against window **aspect**:

| aspect | dead space |
|---|---|
| 3.43:1 (design) | ~20% |
| 3.0:1 | ~29% |
| 1.88:1 | ~55% |
| 1.40:1 | ~64% |

So the app is locked to its design ratio rather than re-tuned for each shape.

**The lock only addresses the aspect axis. Two other causes survive it** - do
not read the table above as "locked = solved":

1. **Scale drift.** At a *fixed* 3.43:1, fill still falls as the window grows:
   72% -> 63% -> 60% at 382 -> 764 -> 982 wide. Content height is
   `k * boxHeight + fixed_px`; as the box grows the fixed px stop mattering and
   fill converges on `k`, the sum of the `cqh` coefficients, which is only
   about 0.6. The other ~40% is never allocated to anything. Aspect is
   irrelevant to this one.
2. **A structurally short tile.** Deceleration runs ~53% dead at *every* size
   and *every* ratio (47% even in the mockup). It has two children (label,
   curve) where Distance has three and Speed Gates has four - Understeer only
   renders when Scripted steering is on, which straight-line runs never use.
   No ratio fills a missing row.

**Both are fixed** (see §4) — scale drift by purging the px constants (§2),
the short tile by always rendering its optional rows. Measured dead space at
the bottom of every Main tile is now 1.0px (the border) at 382, 764, 982 and
1152 wide, in both the empty and the post-run state.
BeamNG supports this natively: `ui/modules/apps/app.js` honours a **top-level**
`"preserveAspectRatio": true` in app.json (a sibling of `css`, NOT inside it).
21 stock apps use it (SimpleTacho, PowerTrainDebug, Compass, SimpleDash...).
Our default is `764 x 223` - exactly 2x the 382 x 111.5 mockup, 3.4260:1.

Three things about how the lock actually behaves (all from `app.js`):

- **The locked ratio is NOT read from app.json.** It is captured at app load
  from the live element: `initAspectRatio = offsetWidth / offsetHeight`
  (`app.js:53`). A window already saved in the game's layout at some other
  ratio will therefore lock to *that*. Changing the app.json default only
  helps a fresh placement - an existing one must be removed and re-added, or
  resized first.
- **No `min-width` / `min-height`, on purpose.** Those are applied as real
  CSS, so a floor on either axis would stop the element reaching the size the
  lock computes and would silently break the ratio at small sizes. The resize
  handler has its own hard floors (50 wide, 40 tall) applied *before* the
  aspect correction, so the practical minimum lands around 50 x 15 at our
  ratio.
- **Resize snaps to 10px increments**, so exact odd numbers can't be reached
  by dragging - 382 x 111.5 rounds to about 380 x 110.

Consequence worth remembering: Details (and often History) will always scroll,
because the window can never be made tall. That is the accepted trade for Main
never having 55% dead space again. If a tall window is ever wanted, the fix is
to make Main reflow - stack the three tiles vertically below about 2:1 - not
to unlock the ratio.

## 4. Tiles fill the window; secondary tabs scroll

- Main's `.btWidgets` grid is `flex: 1` inside `.btMainBody`, so the three
  tiles stretch to the nav. **Main's tiles then fill themselves**, via three
  rules that only work together:
  1. `justify-content: space-between` on `.btWidgets .btTile` — slack goes
     *between* the rows, not into a void under them. Each child keeps its own
     small `margin-top` as a **minimum** separation, which is the only thing
     holding the layout apart at the design size where there is no slack.
  2. **One element per tile may grow.** Deceleration's `.btGWrap` is
     `flex: 1 1 24.2cqh`, so the g-curve gets taller instead of the gaps
     getting wider — a graph reads better tall than a gap does. A grown child
     eats all the free space, so `space-between` resolves to zero in that tile.
  3. **The child count must be fixed.** Even spreading breaks if a row appears
     or vanishes, so Understeer and Actual always render, greyed to `—` via
     `.btRow.is-off` when unmeasured, rather than `ng-if`-ing away. This is
     also what stopped Deceleration being structurally short (47% → 100%).
  The secondary tabs' tiles stay centered, like ABSGripGauges cells.
- Config / Settings / Details / History each sit in `.btScroll` (`flex: 1;
  overflow-y: auto`). Their `.btTiles` grid uses
  `grid-auto-rows: minmax(max-content, 1fr)` + `min-height: 0`. Both halves
  matter: `max-content` stops rows crushing/clipping their own content (the
  tiles are `overflow: hidden`, so without it the row minimum resolves to 0);
  `min-height: 0` makes the grid's height definite so `1fr` rows share the
  box instead of all inflating to the tallest row's content.
- Details still scrolls at normal sizes — three tiles of content in a two-row
  box is by design.

## 5. Testing without the game

The harness is committed at `tools/sizing-harness.html`. It renders the app at
four sizes at once inside a replica of the game wrapper and prints, per Main
tile, the fill %, the dead space at the tile's bottom, and every inter-child
gap. Run it:

```
python -m http.server 8731          # from the repo root
# then open  http://localhost:8731/tools/sizing-harness.html
#      or    .../tools/sizing-harness.html?pop   for the post-run state
```

It must be served over HTTP — `app.js`'s `templateUrl` is the absolute path
`/ui/modules/apps/BrakeTest/app.html`, so `file://` will not resolve it.
`DEAD-BOTTOM` should read ~1.0px (the border) on every tile at every size; if
a number climbs with window size, a px layout constant has crept back in (§2).

**Gotcha if you rebuild it:** do not put a literal `ng-transclude` attribute on
the wrapper div to mimic the game. Angular treats that as its own directive and
throws `ngTransclude:orphan`, which silently leaves the app unrendered. Use a
plain class with the same `width/height/box-sizing` — the geometry is what
matters, not the attribute.

Sizes worth checking every time: `382×111.5` (mockup), `686×380` and
`985×340` (real in-game windows from screenshots), `1152×490` (the taller
in-game window). Measure `root.bottom - nav.bottom` (should be ≈1px, the
border) and whether any tile's children extend past its box.

## 6. Reloading in-game

- **Ctrl+U** reloads the UI/CEF — enough for `app.html` / `app.js` changes,
  and the game hot-reloads `mods/Unpacked` on save too.
- **Ctrl+L** reloads all Lua — needed after `brakeTest.lua` / `brakeTestUI.lua`
  changes.
