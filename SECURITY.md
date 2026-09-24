# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue: use GitHub's
**Security → Report a vulnerability** on this repository. Include what you
found, how to reproduce it, and the version (Settings → Support). We aim to
reply within a week.

## What the app does with sensitive data

- **API key**: stored base64-encoded in `config.json` in your user settings
  folder — obfuscation, not encryption. It is sent only to `api.boson.ai`,
  passed to `curl` through a temporary config file readable only by you (never
  on a command line), and never written to the log.
- **Your text** goes only to Boson's API, to generate the audio you requested.
- **Logs** record what the app did. They never contain the API key or the text
  you voiced; project, voice and file names are marked so they can be removed
  before a log is ever shared.
- **Updates** are downloaded from this repository's GitHub releases and must
  compile before they replace the installed script.
