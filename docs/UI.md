# Building UI in Resolve's UIManager

**Read this before writing any interface code in this project.** Not the first
time only — every time. The toolkit looks like HTML and behaves like something
else, and almost every rule below was learned by shipping something broken
first. Each one cost real time.

Everything here was established empirically on DaVinci Resolve 20/21 Studio
(macOS) with probes in `tests/probes/`. Where a claim is measured, the measurement is
given. Where it is inference, it says so.

---

## 0. The one-minute version

If you read nothing else:

1. **Nothing is verified until you have looked at a screenshot of it.** Not
   "the code says", not "the tests pass". Look.
2. **Check the screenshot actually contains what you think.** A capture of the
   wrong window, or a region that clips the window, is worse than no capture —
   it is a bug report about something that is not there.
3. **Measure, do not assume.** Four CSS properties in this toolkit are silently
   ignored. Colours you believe are readable have measured at 2:1.
4. **A group cannot be sized.** Heights and widths come from Labels. This is
   the single biggest difference from any layout system you know.
5. **Declare before use.** `local function` resolves at compile time; a helper
   defined below its caller is a nil global at runtime.

---

## 1. The mental model

UIManager is a thin Lua binding over Qt widgets. You describe a tree of
widgets in a table, hand it to `disp:AddWindow`, and get back an item table you
address by ID. It is **not** a retained document you can re-query: there is no
"get the element at this position", no computed style, no layout read-back
beyond `.Geometry`, and no way to observe most state you did not set yourself.

Three consequences shape everything:

- **You cannot ask the UI what it looks like.** The only observation channel is
  a screenshot. This is why the screenshot harness exists and why it is not
  optional.
- **Styling is per-widget QSS strings**, not a cascade. There is no stylesheet
  file, no inheritance worth relying on, and no way to know whether a property
  applied except by measuring pixels.
- **Layout is Qt's box model with most of the levers removed.** `Margin` is
  forbidden, group sizing is ignored, and the tools you actually have are
  `Spacing`, `Weight`, and spacer Labels.

### The parts

- `ui:VGroup` / `ui:HGroup` — boxes. `Spacing` between children, `Weight` for
  stretch. **They paint nothing** and **they cannot be sized.**
- `ui:Stack` — one child visible at a time by `CurrentIndex`. Also cannot be
  sized.
- `ui:Label`, `ui:Button`, `ui:LineEdit`, `ui:TextEdit`, `ui:ComboBox`,
  `ui:CheckBox`, `ui:Tree`, `ui:Slider`, `ui:TabBar` — the leaves. These *can*
  be sized, which is why they end up doing structural work.
- `ui:VGap(n)` — a fixed vertical spacer. Prefer it to a stretched Label.

---

## 2. How to check your work

This is the part that matters most, and the part this project got wrong
repeatedly.

### The loop

```bash
FUS="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"
"$FUS" -l lua build.lua          # bundle
"$FUS" -l lua tests/run.lua      # unit tests — these do NOT cover the UI
tests/shoot.sh <scenario> out.png
# then LOOK at out.png
```

Unit tests cover pure logic. **They cannot fail for any layout, colour,
spacing, clipping or state-painting bug.** A green test run tells you the rules
modules are right and says nothing about the interface.

### Verify the capture before you trust it

Every capture must be checked for two things before it is read as evidence:

1. **Is the thing you wanted actually in the frame?** Scenarios that open a
   dialog can fail to open it — a Lua error, a timing race, a window opening
   off-screen — and you get a photograph of the main window instead.
2. **Is the window fully inside the region?** A region shorter than the window
   crops the footer, and both a UX reviewer and an art director once filed the
   same critical bug ("Create voice is sliced in half") against a capture region
   that was 36 px too short. The window was fine.

```python
# A capture with no dialog in it, or a dialog that runs past the frame,
# is not evidence. Check before reading anything else off it.
from PIL import Image; import numpy as np
im = np.array(Image.open(path).convert("RGB")).astype(int)
lit = im.sum(axis=2) > 110
rows = np.where(lit[:, 200:1300].sum(axis=1) > 900)[0]
assert len(rows), "no window in frame"
assert rows.max() < im.shape[0] - 4, "window runs past the capture region"
```

### Do not measure the window by its ground colour

`#28282e` is the dialog's background **and the main window's**. Counting rows of
that colour silently measures the union of both, and every window height quoted
during one long session was wrong because of it. Measure the window's own
border, its title bar, or a widget you can identify — never the fill.

### Measure contrast rather than eyeballing it

Two colours that looked obviously fine measured at 2.0:1 and 2.95:1 and were
invisible in the product: a disabled primary button rendered as an empty green
box with no label for several rounds. Compute it:

```python
def lin(c):
    c /= 255
    return c/12.92 if c <= 0.03928 else ((c+0.055)/1.055)**2.4
def L(h):
    r,g,b = int(h[1:3],16), int(h[3:5],16), int(h[5:7],16)
    return 0.2126*lin(r) + 0.7152*lin(g) + 0.0722*lin(b)
def ratio(a,b):
    la, lb = L(a), L(b)
    return (max(la,lb)+0.05) / (min(la,lb)+0.05)
```

4.5:1 is the floor for body text. The palette's error red was 3.82:1 and failed
it; it is split into a fill red and a lighter text red for that reason.

### Measure ink, not intent

To check whether a weight, size or dim state actually rendered, count ink:

```python
ink = np.array(Image.open(p).convert("L")).astype(int) > 110
band = ink[y0:y1, x0:x1]
print("ink px", band.sum(), "over width", np.where(band.any(axis=0))[0].ptp())
```

If the number is identical before and after your change, your change did
nothing. That is how three rounds of "semibold" headings were caught.

### Never capture while the user is working

The harness opens a second window inside the user's Resolve and steals focus.
If they are editing, wait — or you will photograph their browser.

---

## 3. Layout

### Groups cannot be sized. Labels can.

`MinimumSize` and `MaximumSize` on an HGroup, VGroup or Stack are **ignored**,
for width *and* height. This is the rule that breaks the most intuitions.

To force a size, put a Label next to the thing:

```lua
-- Hold a row to a height: a zero-width Label that the layout must honour.
ui:HGroup{
  Weight = 0, Spacing = 0,
  ui:Stack{ ID = "Pages", Weight = 1, ... },
  ui:Label{ Weight = 0, MinimumSize = { 0, 172 }, MaximumSize = { 0, 172 } },
}
```

**Put the strut on the right, not the left.** A strut before the Stack indents
every page by its own minimum width, and the content stops lining up with the
rows beneath it. That misalignment shipped and had to be reported by the owner.

### Window width is set by label text

A window opens at the width its rows' *labels* ask for, measured with a font
wider than the one drawn. `Resize`, `SetGeometry` and assigning `Geometry` after
`Show()` all do nothing. In the main window the tab strip's `MinimumSize`
(853 px) is what pins the window to 1000.

So: keep labels that exist before `Show()` short, or set their text afterwards.
A long placeholder in a row can silently widen the whole window.

### Windows grow but do not shrink

Qt will enlarge a window past its declared `Geometry`/`MinimumSize` when content
needs it, and will **not** shrink it back when the content goes away. A
disclosure that expands the window therefore only ever expands it.

Two honest options:

- Size the window for its **largest** state and leave it fixed. The smaller
  states carry some empty space; the footer never moves.
- Let it grow and accept that it stays grown.

Add-a-voice takes the first. Verify by measuring the same landmark — the
primary button's row, say — in every state; they must match.

### `Margin` on a group is forbidden

It breaks window sizing: the window may never appear, or its content clips.
Use `Spacing`, `ui:VGap(n)`, and spacer Labels. The dialog inset (`inset()` in
`ui.lua`) is spacer widgets for this reason.

Note the frame you measure is not all yours: Qt adds its own window margin
above and below the content, measured at ~25 px top and ~32 px bottom, and it
already exceeds anything `inset()` sets there. Three attempts to tune it changed
nothing on screen. Declare the height the window actually takes and spend the
remainder deliberately.

### A stretched Label is not a spacer

`ui:Label{ Weight = 1 }` still asks for a line of text, so it inflates the row
it is meant to be padding. Use `ui:VGap(n)` for fixed space. Where you do need a
stretch (to pin a footer to the bottom), give it `MinimumSize = { 0, 0 }` so it
can collapse.

### Hidden at first layout means never laid out

This bit the Generate tab's "Place this clip": built hidden, shown after the
first run, it drew at the far-left edge of its row instead of beside
"Place all". Every widget whose `Hidden` changes at runtime gets a mirror flag
and a `relayout()` on change. Screenshot scenarios must reveal such a widget
*after* the window is up (`late_last` in `tests/screenshot.lua`), or the
capture shows the one path users never see.

A widget that was `Hidden` when the window first laid out has **no geometry**
when you show it later; its children pile up at the origin. Call
`win:RecalcLayout()` (our `relayout()`) after any visibility change.

And the mirror trap: a Lua flag tracking `Hidden` must be initialised to the
same value the build used. Start it `nil` against a widget built `Hidden = true`
and the first refresh sees "no change" and the widget stays hidden forever.

### Stack pages paint through each other

Changing `CurrentIndex` alone is not enough. Hide the sibling pages explicitly
(`select_page` in `ui.lua`).

### Groups paint nothing

No background, no border, whatever selector you use. A card is four 1 px Labels
around the content — see `card()` in `ui.lua`. Rounded corners need a real
widget with `border-radius` in its own stylesheet (`T.pill()`).

### A button is 2 px taller than `control`

Its border draws outside the size. A title row holding buttons is 26 px; one
holding only a label is not — so two columns' boxes start 2 px apart. The
`section_row()` strut is `control + 2` for this reason (measured).

### QSS padding is outside the size hint

Qt computes a widget's size hint before the stylesheet applies, so a padded
label will collide with its neighbour. Give it an explicit width.

---

## 4. Things that silently do nothing

Every one of these was written, believed, shipped, and only found by measuring
pixels. **Assume a CSS property does nothing until you have measured it.**

| Property | Where | What actually happens |
|---|---|---|
| `font-weight` (any value) | `ui:Label` | Ignored. Works on `ui:Button`. |
| `<b>` / `font-weight` in rich text | `ui:Label` | Ignored too. A label **cannot** be bold by any route — use size or colour. |
| `line-height` | `ui:Label` QSS | Ignored. Works in the label's *rich text*, where `N%` is a percentage of Qt's natural line height (20 px at 14 px type), **not** of the type size: `140%` measured as a 28 px pitch. |
| `border-radius` | `QSlider::handle` | Ignored; the handle is a hard rectangle. |
| `Margin` | any group | Breaks window sizing. |
| `:disabled { color: … }` | PNG icon | Cannot touch a PNG. Qt fades it ~20 %, not enough to read as disabled — ship a second, dimmer asset and swap the file. |
| `MinimumSize` / `MaximumSize` | group, Stack | Ignored, width and height. |
| `::drop-down` any rule | `ui:ComboBox` | Removes the chevron entirely. |
| `TextAlignment` | tree cell | Ignored. |
| `BackgroundColor` | tree item | Not painted. |

Rich text on a Label *does* honour `<span style='color:…'>`, which is how
multi-colour labels and the status pill work.

---

## 5. Widgets, one by one

**`ui:Label`** — the workhorse. Sizeable, so it does structural duty as struts
and rules. Borders do not paint; a 1 px Label with a background is the rule.
Can render rich text (colour spans, line-height) but never weight.

**`ui:Button`** — `font-weight` works here. `Icon = ui:Icon{ File = png }` with
`IconSize = {w,h}`; the icon can be swapped at runtime by assigning `Icon`.
Qt mnemonics eat `&` — write `&&`. QSS `min-width` is what makes a button wider
than its size hint.

**`ui:TextEdit`** — **no selection API at all**: `SelectedText`,
`CursorPosition`, `SelectionStart`, `HasSelection` are all nil. `InsertPlainText`
reliably replaces a selection; `InsertHTML` does not. To edit around a
selection, insert a private-use sentinel with `InsertPlainText` and rebuild the
text in Lua. **Setting `HTML`/`PlainText` moves the caret to the start**
(measured; an older note here said "the end", and that belief put every tag
after the first at the top of the text); inserting preserves it. The caret
cannot be read, but it can be moved: `MoveCursor("Start", "MoveAnchor")`, then
`"NextBlock"` / `"NextCharacter"` / `"EndOfBlock"` / `"PreviousCharacter"`
— always pass `"MoveAnchor"`, because without it the moves **select** as they
go and the next insert replaces the selection. About 0.4 ms per step;
`EnsureCursorVisible()` scrolls to it. To keep the caret across a rewrite,
insert a sentinel at it, rewrite without the sentinel, then walk back to it.
`PlainText` reads back clean even when HTML was set. Rich text
supports `<p style='margin:0 0 5px 0'>` for paragraph spacing and
`background-color` on spans. It takes no `line-height` from anywhere. Two
round-trip traps in HTML you set: an empty line written `<p><br></p>` reads
back as **two** line breaks (blank lines double on every rewrite) and an empty
`<p></p>` is dropped — use Qt's own `<p style='-qt-paragraph-type:empty'><br /></p>`;
and runs of spaces collapse unless the paragraph has `white-space:pre-wrap`,
after which the box no longer matches the text you think it holds.

**`ui:Slider`** — **delivers no events whatsoever.** `ValueChanged`,
`SliderPressed`, `SliderMoved` and `ActionTriggered` were all driven with a real
click and never fired, and a click on the track does not page-step. Dragging the
handle does change `.Value`, which polling can read. For a clickable bar, build
it from small buttons instead. For a bar that must not be dragged, set
`Enabled = false` **and** give the `:disabled` rules the same colours as the
enabled ones — otherwise it greys out.

**`ui:Tree`** — `SelectionMode = "NoSelection"` keeps per-cell `TextColor`; a
selected row repaints every cell in one colour. Column widths reset to contents
on rebuild, so set them again. Emits `CurrentItemChanged`, `ItemClicked`,
`ItemDoubleClicked`, `ItemActivated` — declare the ones you handle in the
tree's `Events = { … }` table. There is **no `SetCurrentItem`**, and a row
selected from code (`item.Selected = true`) is not `CurrentItem()`: read the
highlighted row as current-or-first-selected (`highlighted_row()` in `ui.lua`).
A list rebuilt from a combo's `CurrentIndexChanged` also rebuilds when *code*
sets the index — the event lands after `suppress` has lifted — and throws away
any selection made in between.

**`ui:LineEdit`** — emits `ReturnPressed`.

**`.Geometry`** — readable on any widget as `{ x, y, w, h }`, **relative to
the enclosing group**: every HGroup/VGroup is a widget underneath, so two
buttons in one row compare, a text box and the button row below it do not.
This is what the log's layout self-check reads.

**Windows** — `Show`, `Hide`, `Raise`, `ActivateWindow`, `IsActiveWindow`. There
is no `IsVisible`, and `win.Hidden` stays false after `Hide()`, so visibility
cannot be read. Window events need `Events = { Close = true }`.

**Window geometry is remembered per window ID.** A new window reusing an ID
inherits wherever the last one sat — which made screenshot runs inconsistent
until the harness started using a unique ID per run. A script killed from
outside also leaves its widgets registered under that ID, and the next window
merges with them.

---

## 6. Events and the loop

- **`Timer.Timeout` never fires.** `RunLoop` would leave API polling dead
  forever. `run_loop` pumps by hand: drain `ui:GetEvent(false)` (0.13 ms per
  call) then `bmd.wait(0.02)`. Dialogs nest their own loop.
- **`StepLoop` delivers one event per call.** Pumping one event per tick with a
  sleep between makes typing feel frozen. Drain the queue.
- **The event queue is shared by every script Resolve is running.** An event for
  a window this dispatcher never registered makes `Dispatch` throw
  (`attempt to index local 'ontbl'`); catch and ignore it. Two copies of the
  same script steal each other's clicks — hence the heartbeat lock file.
- **Never open a window from a second copy — not even an error dialog.** Its
  loop drains the shared queue and swallows the running copy's clicks, so a
  healthy window looks frozen. Hand off instead: the new launch writes
  `raise.request`, the running copy calls `Show()`/`Raise()`/`ActivateWindow()`,
  pumps briefly, confirms with `IsActiveWindow()`, then acks.
- **`TextChanged` arrives from the queue**, so a programmatic write lands
  *after* a `suppress` guard has lifted. Compare the widget's text against the
  value you last wrote and return early, or the handler undoes work done since.
- **Do not fork per tick.** `os.execute` costs ~2 ms and the loop runs ~50×/s; a
  per-tick `kill -0` burned ~105 ms/second and audibly stuttered playback.
  Throttle anything that spawns a process to a few times a second.
- `bmd.gettime()` is a sub-second clock **but not wall-clock time** (it read
  21:46 at 20:03). Use it for durations; for a timestamp, tie it to `os.time()`
  once and offset (see `stamp()` in `log.lua`). `os.time()` is whole seconds;
  `os.clock()` is CPU time and does not advance during `bmd.wait`.

---

## 7. Colour

The palette lives in `theme.lua` and **`ui.lua` never writes a hex value**.

- **Fills and text need different values of the same hue.** A colour dark
  enough to sit behind white text is too dark to *be* text. Green does this
  (`#1d7028` fill / `#22ad2e` text) and red follows it (`#e0524a` for marks and
  fills, `#f2776d` for running text at 5.3:1).
- **Weight is not available on labels**, so a line that must outrank another can
  only do it with colour — or with shape. When hue alone would not separate
  "blocked" from "carry on", make the blocking state a *block*: a tinted panel
  with a rule down its edge. Shape survives however colour is perceived.
- **A track you cannot see is not a track.** A progress groove painted in the
  window colour measured 1.12:1 and the bar existed only as a handle stub.

---

## 8. Writing and editing `ui.lua`

`ui.lua` is ~3,000 lines and one file. These are the rules that keep it working.

### Declaration order is a runtime hazard

`local function foo` is in scope only *after* its declaration. A helper defined
below its first use resolves to a nil global and crashes when that path runs —
which may be long after launch. This has bitten the file at least five times
(`card`, `icon_button`, `quick_note`, `bar_widget`, `repaint_box`). Either move
the helper up, or forward-declare:

```lua
local repaint_box, insert_tag   -- defined further down, used above
```

### One function paints, everything else sets state

Each screen has a single `refresh()` that reads the state tables and writes
every widget. Handlers change state and call it. The moment two places write the
same widget they disagree — a tick painting a button's text while `refresh`
painted it too produced a button labelled "Get ready…" that behaved as Cancel.

### Never let a second writer overwrite a judgement

A tab handler replaced a whole verdict object with a hard-coded "ok". A refused
take then came back from a tab click looking fine, and the disabled Create
button lit up. **Append to a message; never substitute the object that carries
`ok`/`kind`.**

### Editing safely with scripts

Most edits here are made by Python scripts against the source. Two ways to
destroy the file, both of which happened:

- **`str.index(x, base)` then `str.replace(old, new)`** — `replace` rewrites the
  *first* match in the whole file, not the one at `base`. A handler ended up at
  the top of the module and the dialog died with
  `attempt to index global 'dlg'`. **Slice by index, splice by index.**
- **Anchoring on a shape that repeats.** `}, inset(ui:VGroup{` appears in three
  dialogs; an edit meant for one replaced another's entire widget tree. Anchor
  on the enclosing function name first, then search forward from there.

After any scripted edit: rebuild, run the tests, and **open the file at the
edit site** to confirm the shape is what you meant.

### The LuaJIT upvalue limit

A function may hold at most 60 upvalues. One function wiring every handler
exceeds it, which is why `wire()` is split per tab.

### Assets are written from base64 at launch

Icons are embedded and written to `<config>/icons/`. **Write them every launch**,
not only when absent: a redrawn icon otherwise never reaches disk and the old
one keeps being drawn for as long as the user's config folder survives. That
cost a review round with the change in the source and not on the screen.

---

## 9. Designing a screen here

What has actually worked in this product, after eleven review rounds:

- **Lead with the thing the screen is for.** The Add-a-voice transport was one
  row between a microphone picker and a verdict line; it is a card at the top
  now and the screen reads in one glance.
- **Small words crowd a small window.** Tips lines, running "still needed"
  lists, explanatory subtitles and reassurance sentences each looked harmless
  and together made the dialog unreadable. Say a thing once, where it is
  needed, or not at all.
- **One slot, one line.** A status line that carries guidance, then live
  coaching, then a verdict is better than three lines that are each empty most
  of the time.
- **Put a fault where the eye is.** A refused take announced in the footer while
  the card showed a confident full bar is worse than silence. And never say it
  in two places — that is how the clutter comes back.
- **A control that does nothing should not be visible.** Hide a play button
  until there is something to play; do not grey it.
- **Identical instruments should look identical.** The Add-a-voice transport and
  the Generate tab's audio preview are the same widget order, spacing and track,
  so learning one teaches the other.
- **State that belongs to one tab must not survive a tab switch.** A verdict
  about a microphone has no business on the file page.

---

## 10. Design review

Big UI changes are reviewed from **screenshots** — by a UX designer and an art
director — and iterated until both are satisfied. The quality of the captures is
the quality of the review. Twice, a bad capture produced a confident critical bug report about
something that did not exist — which wastes a round and, worse, teaches you to
distrust real findings. Check every capture before you send it.

Their measurements have repeatedly been right where reasoning was wrong. When a
reviewer says a colour measures 2.95:1 and you believe it is fine, they are
holding the pixels and you are holding an intention.
