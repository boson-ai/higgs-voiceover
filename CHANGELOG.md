# Changelog

All notable changes to Higgs VoiceOver. Versions follow `MAJOR.MINOR.PATCH`;
`0.x` releases are betas.

## 1.0.0 — unreleased

- **Subtitles**: tick **Add subtitles** and placed clips come with native
  Resolve subtitles on a subtitle track, timed to the words using Boson's
  word-level timestamps (English, Chinese and Spanish; a line without word
  timings becomes one subtitle for the length of its clip — never guessed). **Settings › Timeline › Subtitles** splits them into
  **Short phrases** (one line, up to 42 characters, broken at natural points)
  or **Whole sentences** (up to two lines), with a preview of your first line.
- Generate: **Place on timeline** (now on by default) and **Add subtitles**
  sit beside Generate (for automatic placing); **Play audio when done** and
  its own **Add subtitles** box (for the Place buttons) sit in the Audio
  preview card.
- Settings apply when you press **Save** (no more saving as you type);
  **Reset to default** puts everything but your API key back to its default.
- The usage-data checkbox is gone from first run and Settings: nothing was
  ever collected, and nothing is.

## 0.1.0 — private beta

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
