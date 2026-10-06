# Changelog

All notable changes to Higgs VoiceOver. Versions follow `MAJOR.MINOR.PATCH`;
`0.x` releases are betas. All editors share one version number: each release
(`vX.Y.Z`) has an installer for every editor.

## 1.0.0

### Premiere Pro — added 2026-10-06

The first Premiere Pro release, added to 1.0.0: the Resolve feature set in a dockable panel
(**Window → Extensions → Higgs VoiceOver**), for Premiere Pro 2022 and later.

- **Generate**, **tags**, **audio preview** and **Settings** as in Resolve
  1.0.0, styled to sit beside Premiere's own panels and following its light or
  dark theme.
- **Place on timeline**: clips go at the playhead on the audio track you pick
  (A1, A2, … — the last one by default), back to back with no gaps; a locked
  or missing track is reported, not written over. Clips are also imported
  into a "Higgs VoiceOver" bin.
- **Subtitles** land as a native Premiere captions track, word-timed as in
  Resolve.
- **Add a voice**: record in the panel with a microphone picker and a shortcut
  to the system's sound settings, or use an audio file; the transcript box
  appears only when you want one; consent required.
- **Updates**: checked once a day against this repository's Premiere Pro
  releases; **Update now** downloads the installer.
- Its own data folder (`HiggsVO-Premiere`), so it and the Resolve version can
  be installed side by side.
- Signed, notarized macOS installer.

### DaVinci Resolve — 2026-09-24

The first public release.

- **Generate**: type or paste text; each line becomes its own clip, generated
  in order, saved to disk and imported into the project's media-pool bin.
  Voice list with preview, add and delete; draft kept per project.
- **Tags**: search and filter Boson's emotion, style, prosody and sound-effect
  tags, coloured by type in the text. Emotion, style, speed, pitch and
  expressiveness go to the start of the line, replacing one of the same kind;
  pauses and sound effects go at the cursor, and a sound effect comes with its
  written sound (`<|sfx:laughter|>Haha`), as Boson advises.
- **Audio preview**: page through a run's clips, play, pause and scrub; place
  one clip or all of them at the playhead. It stays usable while you edit the
  text and shows which bin the clips are in.
- **Place on timeline** (on by default) places a finished run automatically;
  **Play audio when done** starts the preview.
- **Subtitles**: native Resolve subtitles on a subtitle track, timed to Boson's
  word timestamps in English, Chinese and Spanish — **Short phrases** or
  **Whole sentences** (Settings), split where a subtitler would; a line in
  another language becomes one subtitle the length of its clip. Short gaps are
  filled. Separate **Add subtitles** boxes for automatic placing and for the
  Place buttons.
- **Add a voice**: record a sample on a Mac with nothing to install, or use an
  audio file; optional transcript; consent required.
- **Onboarding**: connect a Boson API key or skip for now.
- **Settings** apply with **Save**; **Reset to default** keeps your key. Audio
  format, trailing silence, clip folder and naming, timeline track, subtitle
  splitting, updates, logs.
- **Updates**: checked once a day; **Update now** installs a new release in
  place. "Up to date" otherwise.
- **Reliability and privacy**: "too many requests" is retried; no connection
  says so; the settings folder (with your key) is private to your account; no
  usage data is collected; a log per launch with outcomes and timings, never
  your key or your text.
- Signed and notarized macOS installer.

## 0.1.0 — private beta (DaVinci Resolve only)

- **Generate**: type or paste text; each line becomes its own clip, generated
  in order. Voice list, tag list with search and type filter, tags coloured by
  type, start-of-line tags placed automatically, draft saved per project.
- **Audio preview**: page through the takes of the last run, play, pause,
  scrub; place one clip or all of them at the playhead, or automatically when
  a run finishes.
- **Add a voice**: record a sample on a Mac with nothing to install, or use an
  audio file; optional transcript; consent required.
- **Onboarding**: connect a Boson API key or skip for now; anonymous usage
  consent asked up front.
- **Settings**: audio format (wav, mp3, aac, flac), trailing silence per clip,
  clip folder per project and file naming, timeline track, update checks, logs.
- A log per launch with outcomes and timings, never your key or your text.
- Signed and notarized macOS installer.
