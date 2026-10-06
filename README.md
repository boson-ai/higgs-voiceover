# Higgs VoiceOver

AI voice-over and word-timed subtitles inside your video editor, powered by
[Higgs TTS 3](https://docs.boson.ai/models/higgs-tts/overview) from Boson AI.

Type or paste what you want said, direct the delivery with tags, and put the
voice-over — with its subtitles — on your timeline without leaving your editor.

> **For DaVinci Resolve Studio and Adobe Premiere Pro, on macOS.** Final Cut
> Pro and Windows are on the way.
>
> - **Resolve:** **Workspace → Scripts → Higgs VoiceOver** (a project must be
>   open). [Install](#install-in-davinci-resolve)
> - **Premiere Pro:** **Window → Extensions → Higgs VoiceOver** — a panel that
>   docks like any other. [Install](#install-in-premiere-pro)

## What it does

### Text to speech

Type or paste text in the Generate tab and choose a voice. Each line is sent to
Boson's [Higgs TTS 3](https://docs.boson.ai/models/higgs-tts/overview) API as
its own request and comes back as its own audio clip, in order. Clips are saved
to disk and imported into a "Higgs VoiceOver" bin in the media pool. Listen to
them in the audio preview, then place one clip or all of them on the timeline
at the playhead (in Premiere, on the audio track you choose — the last one
by default). Output formats: wav, mp3, aac, flac.

### Subtitles

Placed clips can come with subtitles, timed to each spoken word using Higgs
TTS 3's word timestamps. They are split at natural breaks, as short phrases or
whole sentences, and land as ordinary subtitles you can edit, style and
export: a subtitle track in Resolve, a captions track in Premiere. Word timing covers English, Chinese and Spanish; other languages get
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

- **macOS.**
- **DaVinci Resolve Studio 20 or later**, or **Adobe Premiere Pro 2022 (22.0)
  or later**.
- A **Boson API key** from your [Boson Workspace](https://www.boson.ai/workspace/api-key).
- An internet connection.

Resolve must be the Studio version: the free version does not run script
windows. Download it from
[blackmagicdesign.com](https://www.blackmagicdesign.com/products/davinciresolve);
the Mac App Store version does not load user scripts.

## Install in DaVinci Resolve

1. Download `Higgs-VoiceOver-<version>-DaVinci-Resolve-macOS.pkg` from the
   [latest release](../../releases/latest).
2. Open it and follow the installer. It asks for your password because it
   installs for every user on the Mac.
3. Quit and reopen DaVinci Resolve, open a project, and choose
   **Workspace → Scripts → Higgs VoiceOver**.

### Updating

Higgs VoiceOver checks for new releases once a day (you can turn this off in
Settings) and tells you when one is out. Download the new installer from the
[latest release](../../releases/latest), run it, and reopen the window.

### Uninstalling

Delete `Higgs VoiceOver.lua` from
`/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`
(where the installer puts it).
Your settings stay in the data folder below until you delete that too.

## Install in Premiere Pro

1. Download `Higgs-VoiceOver-<version>-Premiere-Pro-macOS.pkg` from the
   [latest release](../../releases/latest).
2. Open it and follow the installer. It asks for your password because it
   installs for every user on the Mac.
3. Quit and reopen Premiere Pro, open a project, and choose
   **Window → Extensions → Higgs VoiceOver**.

### Updating

The panel checks for new releases once a day (you can turn this off in
Settings). **Settings → Check for updates → Update now** downloads the new
installer in your browser; open it, then restart Premiere Pro.

### Uninstalling

Delete the `ai.boson.higgs-voiceover.cep` folder from
`/Library/Application Support/Adobe/CEP/extensions/` and restart Premiere Pro.
Your settings stay in the data folder below until you delete that too.

## First run

Open it from the Scripts menu (Resolve) or the Extensions menu (Premiere Pro), paste your API key and choose **Connect** — or
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
  (Resolve) and `~/Library/Application Support/HiggsVO-Premiere/` (Premiere
  Pro). The two are kept apart, so having both installed is fine.
- Generated clips: `~/Movies/Higgs VoiceOver/<project>/` (changeable in Settings)

- Your text is sent only to Boson's API, to generate the audio you ask for.
- Your API key is kept in that folder, which only your macOS account can
  open — base64-encoded in `config.json` (Resolve) or in a file of its own
  (Premiere Pro). That is not encryption: anyone with access to your account
  can read it. Resolve passes it to `curl` through a temporary config file,
  never on the command line; it is never written to the log.
- One log file is kept per launch (the ten most recent). Logs record what the
  app did — never your API key and never the text you voiced. Settings →
  **Open log folder** shows them; attach the latest one to a bug report.
- **No usage data is collected.** Higgs VoiceOver talks only to Boson's API
  (to generate and to create voices) and to GitHub (the update check). Your
  scripts, voices and generated audio are never shared.

## Troubleshooting

- **The menu item is missing** — restart Resolve after installing; make sure
  it is Resolve Studio from blackmagicdesign.com, not the Mac App Store.
- **Higgs VoiceOver is missing from Window → Extensions** — quit and reopen
  Premiere Pro after installing.
- **"Boson didn't accept that key"** — copy the whole key again from your
  Boson Workspace.
- **Recording doesn't start** — allow microphone access for DaVinci
  Resolve or Premiere Pro in System Settings → Privacy & Security →
  Microphone. In Resolve the recording uses your default input; **Audio
  settings…** in the dialog opens the Sound settings to change it. In
  Premiere Pro, pick the microphone in the dialog.
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
trademark of Blackmagic Design; Adobe Premiere Pro is a trademark of Adobe.
