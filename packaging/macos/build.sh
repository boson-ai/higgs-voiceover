#!/bin/bash
# Build the macOS installer: dist/Higgs VoiceOver <version>.pkg
#
#   packaging/macos/build.sh                  unsigned (for testing)
#   SIGN_ID="Developer ID Installer: …" packaging/macos/build.sh
#                                             signed
#   SIGN_ID="…" NOTARY_PROFILE=<profile> packaging/macos/build.sh
#                                             signed, notarized and stapled
#
# NOTARY_PROFILE names credentials saved once in the login keychain with
#   xcrun notarytool store-credentials <profile> --apple-id … --team-id …
# (it asks for an app-specific password itself; nothing secret lives here).
#
# The package installs the one built script into Resolve's system-wide
# Utility folder, so it shows up for every user and needs no Terminal.
set -euo pipefail
# This repo lives on a non-APFS drive, which stores extended attributes as
# ._ files; without this they ride into the payload.
export COPYFILE_DISABLE=1
cd "$(dirname "$0")/../.."
FUS="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"
VERSION=$(tr -d '[:space:]' < VERSION)
"$FUS" -l lua build.lua >/dev/null

WORK=$(mktemp -d)
ROOT="$WORK/root/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
mkdir -p "$ROOT" "$WORK/scripts" "$WORK/res" dist
cat "Higgs VoiceOver.lua" > "$ROOT/Higgs VoiceOver.lua"
cat packaging/macos/postinstall > "$WORK/scripts/postinstall"; chmod 755 "$WORK/scripts/postinstall"
for f in welcome.html conclusion.html; do cat "packaging/macos/$f" > "$WORK/res/$f"; done
sed "s/__VERSION__/$VERSION/" packaging/macos/distribution.xml > "$WORK/distribution.xml"

# pkgbuild archives extended attributes as ._ entries; the payload should
# be the script and nothing else.
xattr -cr "$WORK"
find "$WORK" -name '._*' -delete
chmod -R go-w "$WORK/root"
pkgbuild --root "$WORK/root" --scripts "$WORK/scripts" \
  --identifier ai.boson.higgs-voiceover --version "$VERSION" \
  --install-location / "$WORK/raw.pkg" >/dev/null
# macOS stamps a protected com.apple.provenance attribute on every file this
# process creates (xattr -c cannot remove it), and pkgbuild archives it as
# ._ entries that would be installed into Resolve's folders. Re-pack the
# payload with ditto, which can leave attributes out.
pkgutil --expand "$WORK/raw.pkg" "$WORK/exp"
# Only the payload is installed onto the disk; the scripts run from a
# temporary folder, so a stray ._postinstall there is never executed or kept.
rm -rf "$WORK/exp/Payload" "$WORK/exp/Bom"
ditto -c -z --norsrc --noextattr --noacl "$WORK/root" "$WORK/exp/Payload"
mkbom "$WORK/root" "$WORK/exp/Bom"
pkgutil --flatten "$WORK/exp" "$WORK/component.pkg"
rm -f "$WORK/raw.pkg"
if pkgutil --payload-files "$WORK/component.pkg" | grep -q '/\._'; then
  echo "payload still carries ._ entries" >&2; exit 1
fi

OUT="dist/Higgs VoiceOver $VERSION.pkg"
SIGN_ARGS=()
if [ -n "${SIGN_ID:-}" ]; then SIGN_ARGS=(--sign "$SIGN_ID"); fi
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/res" \
  --package-path "$WORK" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$OUT" >/dev/null
rm -rf "$WORK"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${SIGN_ID:-}" ] || { echo "NOTARY_PROFILE needs SIGN_ID: Apple only notarizes signed packages" >&2; exit 1; }
  echo "notarizing (usually a few minutes)…"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  spctl -a -vv -t install "$OUT"
fi
echo "built: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))${SIGN_ID:+ signed}"
