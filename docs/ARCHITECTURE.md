# Architecture

Higgs VoiceOver is one Lua script that Resolve runs from its Scripts menu. It
draws its window with Resolve's UIManager (Qt widgets styled per widget with
QSS), talks to Boson's API through `curl`, and puts audio on the timeline
through Resolve's scripting API.

## Modules (`src/higgs/`)

| Module | Role |
|---|---|
| `main.lua` | Entry point: connect to Resolve, require an open project, start the log, load settings, enforce a single running instance, run the window |
| `ui.lua` | The window and its dialogs: onboarding, the Generate tab, Settings, Add a voice |
| `theme.lua` | Every colour, size and stylesheet. `ui.lua` never writes a colour value |
| `api.lua` | Boson client: queued `curl` requests, the key passed through a temporary config file, friendly error messages, request metrics |
| `config.lua` | Settings, key storage, folders, config schema and migrations, the voice list, the single-instance lock, drafts |
| `log.lua` | One log per launch, metrics, redaction |
| `tags.lua` | The Higgs control-tag taxonomy and the rules for placing tags in text |
| `subtitles.lua` | Subtitles from a take: match Boson's word timings to the typed text, split it (short phrases or sentences), apply subtitle timing rules, write `.srt` (pure, tested) |
| `recorder.lua` | Rules for a recorded voice sample: length and level verdicts (pure, tested) |
| `record_macos.lua` | Microphone capture on macOS through `osascript` and `AVAudioRecorder` |
| `platform.lua` + `platform_macos.lua` | The OS contract and the macOS backend |
| `resolve.lua` | Media-pool bin, track creation, placement at the playhead, subtitles onto a subtitle track |
| `util.lua` | JSON, base64, files, WAV/PCM helpers, Unicode-aware clip names |
| `icons.lua` | Transport icons as embedded PNGs, written to disk at launch |

`build.lua` wraps each module in `package.preload` and writes the single
`Higgs VoiceOver.lua`; `require("higgs.x")` works the same in the bundle as in
the source tree. `VERSION` is stamped in as `_G.HIGGS_VO_VERSION`.

## The OS boundary

Higgs VoiceOver runs on **macOS**. **Every OS-specific operation goes through
`platform.lua`**, and no other module touches the operating system directly.
The contract (listed at the top of `platform.lua`) covers paths, running
processes, playing audio and recording, and is validated at load time — so a
future backend for another OS fails immediately and names what is missing.

| | macOS |
|---|---|
| Requests | `curl`, polled in the background so the window stays responsive |
| Preview playback | `afplay` |
| Recording | `osascript` → `AVAudioRecorder`, nothing to install; uses the default input |
| Settings | `~/Library/Application Support/HiggsVO` |
| Clips | `~/Movies/Higgs VoiceOver/<project>` |

## Runtime

- **The event loop is pumped by hand.** UIManager never delivers
  `Timer.Timeout`, so the app drains the event queue itself, waits 20 ms, then
  runs a tick: poll the API queue, advance the preview player, autosave the
  draft, check layout, stamp the single-instance lock. Dialogs run a nested loop.
- **One instance at a time.** Every script in Resolve shares one event queue,
  so two copies would steal each other's clicks. A running instance refreshes a
  lock file; a second launch asks it to bring its window forward instead.
- **One request in flight**, first in first out. A generation run sends its
  lines one after another so the clips come back in order.

## A generation, end to end

1. Each line of the text box becomes a request; a line without end punctuation
   gets a full stop at send time so the model closes the sentence.
2. The API returns mono audio. It is written as stereo (both channels the
   same) with a short trailing silence, then imported into the
   "Higgs VoiceOver" media-pool bin.
3. Placing puts each clip on the VO track (created as stereo if missing) at the
   playhead, or after the clip already there, one after another.
4. With **Add subtitles** on, step 1 asks for word timestamps (the response
   becomes JSON with the audio base64-encoded inside). After placing, each
   clip's line is split into subtitles, the word timings are matched back to
   the typed text (tags and punctuation ignored), the subtitles are snapped to
   the timeline's frames, and the whole run is written as one `.srt` next to
   the audio, imported, and appended onto a subtitle track named like the VO
   track (a new one when the placement is earlier than that track's last
   subtitle). A take without timings — another language, or generated before
   the box was ticked — is timed from its text instead.

## Resolve behaviour the code relies on

`resolve.lua` encodes behaviour observed on real Resolve builds rather than
read from documentation: placing into an occupied range silently does nothing
while reporting success; overwriting a file in place does not refresh
Resolve's cache; there is no trim or move API. `tests/resolve_live.lua` checks
each of these — run it against every Resolve version you intend to support.

Subtitles have their own rules (Resolve 20.3.2; `tests/probes/subtitles.lua`
reproduces them): **appending a subtitle item with a clip-info table (tried
with `recordFrame`, with and without `trackIndex`) crashes Resolve**, so only
the plain `AppendToTimeline({ item })` is used. It puts
the item on the first *enabled* subtitle track, at that track's last subtitle
plus the time of the file's first subtitle; the position is therefore set by
writing the `.srt` with the right lead-in, with the target track made the
only enabled one for the moment of the append.

## Settings on disk

`config.json` in the settings folder, schema 4. A migration only ever moves a
value that still equals an old default; a value the user chose is kept.
Also in that folder: `logs/`, `projects/<project>/generate.json` (the draft),
`icons/`, `tmp/` (request scratch files).
