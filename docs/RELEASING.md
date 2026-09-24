# Releasing

How a version goes from `main` to users: the script, the Mac installer, and
the GitHub release the in-app updater reads.

## Versions

- `VERSION` holds the number; the build stamps it into the script.
- Plain `MAJOR.MINOR.PATCH` only. The in-app update check compares the digits,
  so a suffix like `-beta.2` cannot be ordered — call a release "beta" in its
  title instead. Betas are `0.x`; `1.0.0` is general release.
- Git tags are `vX.Y.Z` on `main`.

## What a release contains

Attach these to the GitHub release (do **not** commit them — `dist/` and the
built script are ignored):

| Asset | For | Notes |
|---|---|---|
| `Higgs-VoiceOver.lua` | The in-app updater and manual installs | GitHub does not allow spaces in asset names; upload it under this name. The updater matches it by letters only and installs it as `Higgs VoiceOver.lua` |
| `Higgs-VoiceOver-X.Y.Z.pkg` | Mac users | Signed and notarized, or Gatekeeper blocks it |

The build writes `dist/Higgs VoiceOver.lua` and `dist/Higgs VoiceOver X.Y.Z.pkg`;
copy them to the hyphenated names before uploading, so the download names are
the ones the README gives.

GitHub's automatic "Source code" archives are added by GitHub.

## Checklist

1. Update `VERSION` and `CHANGELOG.md`.
2. Build and test:
   ```bash
   FUS="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"
   "$FUS" -l lua build.lua && "$FUS" -l lua tests/run.lua
   ```
   Capture and look at the main screens (`tests/shoot.sh`), and run
   `tests/resolve_live.lua` on a machine where Resolve is free to use and
   `tests/api_live.lua` with a Boson key. A failure marked `SERVICE:` is
   Boson's side (for example word timestamps not returned); check the app's
   fallback passed before deciding whether to ship.
3. Build the Mac installer (below) and install it on a clean user account:
   the Scripts menu should list **Higgs VoiceOver** once.
4. Commit, tag and push:
   ```bash
   git commit -am "Version X.Y.Z" && git tag -a vX.Y.Z -m "Higgs VoiceOver X.Y.Z"
   git push origin main vX.Y.Z
   ```
5. Create the GitHub release from the tag, paste the changelog entry, attach
   both assets. Publish it as a **normal** release: the in-app updater reads
   GitHub's "latest release", which skips pre-releases.

## The Mac installer

```bash
packaging/macos/build.sh
```

produces `dist/Higgs VoiceOver <version>.pkg`. It installs the script into
Resolve's **system-wide** Utility folder
(`/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/`),
refuses to install when Resolve is missing, and removes any per-user copy or
copy under an old name so the Scripts menu lists the product once.

### Signing and notarizing

An unsigned package is blocked when a downloaded copy is double-clicked. To
sign and notarize you need an Apple Developer account with a
**Developer ID Installer** certificate in your keychain.

One-time: save notarization credentials in the keychain (it asks for an
app-specific password from account.apple.com):

```bash
xcrun notarytool store-credentials <profile-name> --apple-id <apple-id> --team-id <TEAM_ID>
```

Then:

```bash
SIGN_ID="Developer ID Installer: <Name> (<TEAM_ID>)" NOTARY_PROFILE=<profile-name> packaging/macos/build.sh
```

The script signs the package, submits it to Apple, waits (minutes; the first
submission for an account can take longer), staples the ticket so it works
offline, and checks it with `spctl`. Expect
`source=Notarized Developer ID`.

Build notes:

- The payload is repacked with `ditto --noextattr`: macOS may attach an extended
  attribute to every file the build creates, and `pkgbuild` would otherwise
  install those as `._` files into Resolve's folders. The build fails if any
  remain.
- Nothing secret lives in this repository; the certificate and notary
  credentials stay in your keychain.

## The update channel

The app reads `https://api.github.com/repos/<UPDATE_REPO>/releases/latest`
(`UPDATE_REPO` is set near the top of the updates section in `src/higgs/ui.lua`),
compares the tag with its own version, and offers **Update now**, which
downloads the `.lua` asset, checks that it compiles, and replaces the
installed script. Pre-releases are not returned by that endpoint, so mark a
beta as a normal release when you want existing users to be offered it.
