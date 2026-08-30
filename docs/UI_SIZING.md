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

**Spacing scales with the window WIDTH only, and never below the mockup's px.**
The mockup (`Desktop/BrakeTest_Flow_Display.html`) is 382×111.5px with root
padding `6px`, tile padding `5px 6px`, tile gap `5px`, nav padding `2px 6px`.
Those are written as `max(6px, 1.57cqw)` etc. — 6px of 382 = 1.57cqw — so a
window twice as wide gets twice the frame, but a small window never drops
below the mockup. Scaling by *height* (`cqh`) was the earlier mistake: 6px of
111.5 = 5.4cqh, which turns into ~20px in a 380px-tall window while the
width barely changed. The inner chrome (nav's 2px, row gaps) stays plain px.

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

Fixing those means either raising the `cqh` budget so content actually adds up
to ~100% of the tile, giving one element per tile `flex: 1` so it absorbs the
slack, or capping the tile row's height so leftover falls below it instead of
inside it.
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
  tiles stretch to the nav. Tile content hugs the top (`justify-content:
  flex-start` on Main's tiles; the secondary tabs' tiles are centered like
  ABSGripGauges cells).
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

There's no committed harness (it's a scratch file), but the recipe is: an HTML
page that loads AngularJS 1.8 from cdnjs, stubs `window.bngApi.engineLua` to
log, declares `angular.module('beamng.apps', [])`, includes `app.js`, and
mounts `<div brake-test>` **inside a replica of the game wrapper** — a
`.bng-app { position:absolute; overflow:hidden }` box with a `.bngApp
{ box-sizing:border-box; padding:2px }` base rule, sized to the window you
want to test. Serve the repo root over HTTP so `/ui/modules/apps/BrakeTest/
app.html` resolves. Resize the `.bng-app` box, not the page.

Sizes worth checking every time: `382×111.5` (mockup), `686×380` and
`985×340` (real in-game windows from screenshots), `1152×490` (the taller
in-game window). Measure `root.bottom - nav.bottom` (should be ≈1px, the
border) and whether any tile's children extend past its box.

## 6. Reloading in-game

- **Ctrl+U** reloads the UI/CEF — enough for `app.html` / `app.js` changes,
  and the game hot-reloads `mods/Unpacked` on save too.
- **Ctrl+L** reloads all Lua — needed after `brakeTest.lua` / `brakeTestUI.lua`
  changes.
