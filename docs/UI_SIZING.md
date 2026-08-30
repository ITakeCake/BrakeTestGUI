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
  `css.width/height` is only the default for a fresh placement. So the app
  has to look right at *any* aspect ratio, which is the whole reason for §2.

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
