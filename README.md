# Higgs VoiceOver

AI voice-over and word-timed subtitles inside your video editor, powered by
[Higgs TTS 3](https://docs.boson.ai/models/higgs-tts/overview) from Boson AI.

Type or paste what you want said, direct the delivery with tags, and put the
voice-over — with its subtitles — on your timeline without leaving your editor.

> **1.0.0 is the first release: DaVinci Resolve Studio on macOS.** More
> editing apps and a Windows version are on the way.
>
> In Resolve, open it from the menu bar: **Workspace → Scripts → Higgs
> VoiceOver** (a project must be open).

## What it does

### Text to speech

Type or paste text in the Generate tab and choose a voice. Each line is sent to
Boson's [Higgs TTS 3](https://docs.boson.ai/models/higgs-tts/overview) API as
its own request and comes back as its own audio clip, in order. Clips are saved
to disk and imported into a "Higgs VoiceOver" bin in the media pool. Listen to
them in the audio preview, then place one clip or all of them on the timeline
at the playhead. Output formats: wav, mp3, aac, flac.

### Subtitles

Placed clips can come with subtitles, timed to each spoken word using Higgs
TTS 3's word timestamps. They are split at natural breaks, as short phrases or
whole sentences, and land as ordinary Resolve subtitles you can edit, style and
export. Word timing covers English, Chinese and Spanish; other languages get
one subtitle per line.

### Voice cloning

Add a voice from a short recording (3–30 seconds) made in the app, or from an
audio file. Nothing extra needs to be installed to record. The new voice is
created on your Boson account and appears in the voice list.

### Emotion and delivery tags

Higgs TTS 3 reads tags in the text that set emotion, speaking style, pace,
pitch and pauses, or add sounds like laughter or a sigh. Pick them from the
tag list and they go where Boson recommends.

### Bring your own key

Higgs VoiceOver uses your own Boson API key; requests are billed to your
Boson account. Get a key from your
[Boson Workspace](https://www.boson.ai/workspace/api-key).

## Requirements

This release:

- **macOS.** A Windows version is on the way.
- **DaVinci Resolve Studio 20 or later.** The Studio version is required: the
  free version of Resolve does not run script windows. Download it from
  [blackmagicdesign.com](https://www.blackmagicdesign.com/products/davinciresolve);
  the Mac App Store version does not load user scripts.
- A **Boson API key** from your [Boson Workspace](https://www.boson.ai/workspace/api-key).
- An internet connection.

## Install

1. Download `Higgs-VoiceOver-<version>-DaVinci-Resolve-macOS.pkg` from the
   [latest release](../../releases/latest).
2. Open it and follow the installer. It asks for your password because it
   installs for every user on the Mac.
3. Quit and reopen DaVinci Resolve, open a project, and choose
   **Workspace → Scripts → Higgs VoiceOver**.

**By hand instead:** download `Higgs-VoiceOver-<version>-DaVinci-Resolve-macOS.lua`
from the [latest release](../../releases/latest), rename it to **`Higgs VoiceOver.lua`**
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

## Your data and privacy

- Settings, drafts and logs: `~/Library/Application Support/HiggsVO/`
- Generated clips: `~/Movies/Higgs VoiceOver/<project>/` (changeable in Settings)

- Your text is sent only to Boson's API, to generate the audio you ask for.
- Your API key is stored in `config.json`, base64-encoded, in a folder only
  your macOS account can open. Base64 is obfuscation, not encryption: anyone
  with access to your account can read it. It is passed to `curl` through a temporary config file, never on the
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
- **Subtitles are one per line, not split** — splitting needs Boson's word
  timings, which cover English, Chinese and Spanish. Lines in other languages
  get one subtitle each, the length of the clip.
- **A line is refused as too long** — the limit is 5,000 characters per line;
  break it into more lines.

Found a bug? [Open an issue](../../issues/new/choose) and attach the latest log.

## Boson documentation

- [Higgs TTS 3 overview](https://docs.boson.ai/models/higgs-tts/overview)
- [Tags](https://docs.boson.ai/models/higgs-tts/tags) — emotion, style, prosody and sound effects
- [Voices and cloning](https://docs.boson.ai/models/higgs-tts/voices)
- [Supported languages](https://docs.boson.ai/models/higgs-tts/languages)
- [Word-level timestamps](https://docs.boson.ai/models/higgs-tts/overview#word-level-timestamps)
- [API reference](https://docs.boson.ai/api-reference/audio/create-a-speech)
- [Get an API key](https://www.boson.ai/workspace/api-key)

## Credits

Higgs VoiceOver runs on Boson AI's Higgs TTS 3 API. DaVinci Resolve is a
trademark of Blackmagic Design.
