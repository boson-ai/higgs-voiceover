# Higgs VoiceOver

AI voice-over for DaVinci Resolve, powered by [Higgs TTS 3](https://docs.boson.ai/models/higgs-tts/overview) from Boson AI.

Type or paste what you want said, direct the delivery with tags, and put the
voice-over on your timeline — without leaving Resolve. Once installed, open it
from Resolve's menu bar: **Workspace → Scripts → Higgs VoiceOver** (a project
must be open).

> 1.0.0 is the first public release, for DaVinci Resolve Studio 20 or later
> on **macOS**.

## What it does

### Text to speech

Type or paste text in the Generate tab and choose a voice. Each line is sent to
Boson's [Higgs TTS 3](https://docs.boson.ai/models/higgs-tts/overview) API as
its own request and comes back as its own audio clip, in order. Clips are saved
to disk and imported into a "Higgs VoiceOver" bin in the media pool. Listen to
them in the audio preview, then place one clip or all of them on the timeline
at the playhead. Output formats: wav, mp3, aac, flac.

### Subtitles

Tick **Add subtitles** and placed clips come with subtitles on a subtitle
track, timed to the words: the app asks Boson for
[word-level timestamps](https://docs.boson.ai/models/higgs-tts/overview#word-level-timestamps)
and splits the text the way subtitlers do — at punctuation and natural pauses,
never between "the" and its noun. In **Settings › Timeline › Subtitles** choose **Short
phrases** (one line, up to 42 characters; 16 in Chinese) or **Whole
sentences** (one sentence per subtitle, up to two lines). They are ordinary
Resolve subtitles: edit, style and export them like any others. Word timing
is available for English, Chinese and Spanish; a line in another language is
placed without subtitles.

### Voice cloning

Add a voice from a short recording (3–30 seconds) made in the app, or from an
audio file. Nothing extra needs to be installed to record. The new voice is
created on your Boson account and appears in the voice list.

### Emotion and delivery tags

Higgs TTS 3 reads control tags written in the text, such as
`<|emotion:enthusiasm|>`, speaking styles, sound effects, pauses, and speed,
pitch and expressiveness. Insert them from the tag list or type them. See
[Boson's tag reference](https://docs.boson.ai/models/higgs-tts/tags).

### Bring your own key

Higgs VoiceOver uses your own Boson API key; requests are billed to your
Boson account. Get a key from your
[Boson Workspace](https://www.boson.ai/workspace/api-key).

## Requirements

- **macOS.** A Windows version is on the way.
- **DaVinci Resolve Studio 20 or later.** The Studio version is required: the
  free version of Resolve does not run script windows. Download it from
  [blackmagicdesign.com](https://www.blackmagicdesign.com/products/davinciresolve);
  the Mac App Store version does not load user scripts.
- A **Boson API key** from your [Boson Workspace](https://www.boson.ai/workspace/api-key).
- An internet connection.

## Install

1. Download `Higgs-VoiceOver-<version>.pkg` from the
   [latest release](../../releases/latest).
2. Open it and follow the installer. It asks for your password because it
   installs for every user on the Mac.
3. Quit and reopen DaVinci Resolve, open a project, and choose
   **Workspace → Scripts → Higgs VoiceOver**.

**By hand instead:** download `Higgs-VoiceOver.lua` from the
[latest release](../../releases/latest), rename it to **`Higgs VoiceOver.lua`**
(Resolve shows the file name as the menu entry), copy it into
`~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`,
and restart Resolve.

### Updating

Higgs VoiceOver checks for new releases once a day (you can turn this off in
Settings). **Settings → Check for updates → Update now** installs the new
version; close and reopen the window to use it.

### Uninstalling

Delete `Higgs VoiceOver.lua` from
`/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`
(where the installer puts it) or from the per-user folder above if you
installed by hand.
Your settings stay in the data folder below until you delete that too.

## First run

Open it from the Scripts menu, paste your API key and choose **Connect** — or
**Skip for now** to look around first (you'll need a key before you can
generate). Then:

1. Pick a voice on the left, or **Add voice…** to make your own.
2. Type your lines. Insert tags from the list, or type them, e.g.
   `<|emotion:enthusiasm|> Welcome back!`
3. **Generate**, listen in **Audio preview**, then **Place all clips** — or
   tick **Place on timeline** (and **Add subtitles**) beside Generate to have
   it done when the run finishes.

Tag reference: [docs.boson.ai — tags](https://docs.boson.ai/models/higgs-tts/tags).

## Your data and privacy

- Settings, drafts and logs: `~/Library/Application Support/HiggsVO/`
- Generated clips: `~/Movies/Higgs VoiceOver/<project>/` (changeable in Settings)


- Your text is sent only to Boson's API, to generate the audio you ask for.
- Your API key is stored in `config.json`, base64-encoded. That is
  obfuscation, not encryption: anyone with access to your user account can read
  it. It is passed to `curl` through a temporary config file, never on the
  command line, and is never written to the log.
- One log file is kept per launch (the ten most recent). Logs record what the
  app did — never your API key and never the text you voiced. Settings →
  **Open log folder** shows them; attach the latest one to a bug report.
- **No usage data is collected.** Higgs VoiceOver talks only to Boson's API
  (to generate and to create voices) and to GitHub (the update check). Your
  scripts, voices and generated audio are never shared.

## Troubleshooting

- **The menu item is missing** — restart Resolve after installing; make sure
  it is Resolve Studio from blackmagicdesign.com, not the Mac App Store.
- **"Boson didn't accept that key"** — copy the whole key again from your
  Boson Workspace.
- **Recording doesn't start** — allow microphone access for DaVinci
  Resolve in System Settings → Privacy & Security → Microphone. The recording
  uses your default input; **Audio settings…** in the dialog opens the Sound
  settings to change it.
- **Numbers or dates sound wrong with subtitles on** — Boson skips its text
  normalisation when word timings are requested, so "$1,250" is read as
  written. Write it out ("twelve hundred and fifty dollars") for that line.
- **A line is refused as too long** — the limit is 5,000 characters per line;
  break it into more lines.

Found a bug? [Open an issue](../../issues/new/choose) and attach the latest log.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) to build from source and run the tests,
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the code is organised, and
[docs/RELEASING.md](docs/RELEASING.md) for how releases and the installer are made.

Higgs VoiceOver runs on Boson AI's Higgs TTS 3 API. DaVinci Resolve is a
trademark of Blackmagic Design.
