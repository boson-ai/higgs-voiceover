# Contributing

Thanks for helping. Higgs VoiceOver is a single Lua script that runs inside
DaVinci Resolve Studio. The source is split into modules under `src/higgs/`
and bundled into one file by `build.lua`. Resolve ships the Lua interpreter,
so there is no toolchain to install.

## Setup

You need a Mac with DaVinci Resolve Studio 20+ and, for anything that calls the
API, a Boson API key of your own.

```bash
FUS="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"

"$FUS" -l lua build.lua          # bundle src/higgs/*.lua -> "Higgs VoiceOver.lua"
"$FUS" -l lua tests/run.lua      # unit tests (Resolve may be closed)
./install.sh                     # copy the build into your Scripts › Utility menu
```

`install.sh` installs for your user only. Restart Resolve the first time so the
menu picks the script up; after that, closing and reopening the window loads a
new build. `./install.sh --uninstall` removes it.

The built `Higgs VoiceOver.lua` is not committed — it is attached to each
GitHub release instead. Build it locally before running the tests.

## Tests

| What | Command | Needs |
|---|---|---|
| Unit tests | `"$FUS" -l lua tests/run.lua` | nothing |
| Screenshots of UI states | `tests/shoot.sh <scenario> out.png` | Resolve open (it opens a second window) |
| Live Resolve integration | `"$FUS" -l lua tests/resolve_live.lua` | Resolve open — works in a scratch project it creates and **switches Resolve to it**, so don't run it while you are editing |
| Live Boson API | `"$FUS" -l lua tests/api_live.lua` | A Boson key (the one saved in the app, or `HIGGS_TEST_KEY`); a few cents of credit. Speech in every format, word timestamps, error paths, the request queue, and how the key is handled on disk and in the process list |
| Toolkit probes | `tests/probes/*.lua` | Resolve open; investigative, not part of CI |

Screenshot scenarios are listed at the top of `tests/screenshot.lua` (onboarding
states, the Generate tab at rest, running and finished, Settings, and the Add a
voice dialog). `HIGGS_SHOT_X` moves the capture window and `HIGGS_REGION` the
capture rectangle (`x,y,w,h`); `HIGGS_SHOT_DIR` points the run at a fresh
settings folder.

**Unit tests cannot catch a layout bug.** After any interface change, capture
the states you touched and look at them — and check the capture actually
contains the whole window before trusting it.

## Before you change the interface

Read [docs/UI.md](docs/UI.md). Resolve's UIManager looks like HTML and behaves
like something else; every rule in that guide was learned by shipping something
broken. The three that catch people fastest:

- **A group cannot be sized.** `MinimumSize`/`MaximumSize` on an HGroup, VGroup
  or Stack is ignored. Sizes come from Labels used as struts.
- **Assume a CSS property does nothing until measured.** `font-weight` and
  `line-height` on a label, `border-radius` on a slider handle and `Margin` on a
  group are all silently ignored.
- **A widget hidden when the window first lays out is never laid out** until
  `RecalcLayout` — show it later and it piles up at the origin.

## Code conventions

- **Every OS-specific call goes through `platform.lua`.** No other module
  touches the operating system directly, so supporting another OS later means
  writing one backend table.
- **`ui.lua` never writes a colour or size** — they live in `theme.lua`.
- **Declare before use.** `local function` is in scope only after its
  declaration; forward-declare helpers used above their definition. LuaJIT
  allows 60 upvalues per function, which is why wiring is split per tab.
- **One function paints each screen**; handlers change state and call it.
- **The product is "Higgs VoiceOver"** in every string a user can see
  (`Config.APP_NAME`); the short "Higgs VO" is only for code, folders and the
  default track name. The user-facing word is "line", never "segment".
- **Copy is short and plain.** Errors say what happened, then what to do.

### Logging

The log is the only record of a session a user can send, so a bug that leaves
no trace in it is a logging bug too.

- Log **outcomes**, not just events: `Log.metric("place.quick", { clips = 2, ok = 1 })`.
- **Never log the API key or the text being voiced** — log its length. Wrap
  names in `Log.q()` and paths in `Log.path_safe()` so `Log.redact()` can strip
  them.
- Widgets that are shown or hidden at runtime get a rule in `LAYOUT_RULES`
  (`ui.lua`) so a layout fault is logged even without a screenshot.

## Pull requests

- Keep one change per pull request, and explain **why** in the description and
  the commit messages — they are the project's history.
- Include before/after screenshots for any interface change.
- Run the unit tests, and the live Resolve tests if you touched `resolve.lua`.
- By contributing you agree your work is released under the project's license.

## More

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — modules, runtime, data on disk.
- [docs/RELEASING.md](docs/RELEASING.md) — versions, the Mac installer, publishing a release.
- [SECURITY.md](SECURITY.md) — reporting a vulnerability.
