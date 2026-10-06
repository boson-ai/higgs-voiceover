#!/bin/bash
# Build the macOS installer for the CEP build:
#   dist/Higgs-VoiceOver-<version>-Premiere-Pro-macOS.pkg
#
#   npm run package:cep                       first: the signed .zxp (see scripts/package-cep.mjs)
#   packaging/macos/build.sh                  unsigned installer (for testing)
#   SIGN_ID="Developer ID Installer: …" NOTARY_PROFILE=<profile> packaging/macos/build.sh
#                                             signed, notarized and stapled
#
# The package puts the signed extension, exactly as in the .zxp (its
# META-INF signature included), in the system-wide CEP extensions folder, so
# Premiere loads it for every user without the developer setting.
set -euo pipefail
export COPYFILE_DISABLE=1   # this repo's drive stores extended attributes as ._ files
cd "$(dirname "$0")/../.."
VERSION=$(node -p 'require("./package.json").version')
ZXP="dist/Higgs-VoiceOver-$VERSION-Premiere-Pro.zxp"
[ -f "$ZXP" ] || { echo "missing $ZXP — run npm run package:cep first" >&2; exit 1; }

WORK=$(mktemp -d)
ROOT="$WORK/root/Library/Application Support/Adobe/CEP/extensions/ai.boson.higgs-voiceover.cep"
mkdir -p "$ROOT" "$WORK/scripts" "$WORK/res" dist
ditto -x -k --norsrc --noextattr "$ZXP" "$ROOT"
cat packaging/macos/postinstall > "$WORK/scripts/postinstall"; chmod 755 "$WORK/scripts/postinstall"
for f in welcome.html conclusion.html; do cat "packaging/macos/$f" > "$WORK/res/$f"; done
sed "s/__VERSION__/$VERSION/" packaging/macos/distribution.xml > "$WORK/distribution.xml"

xattr -cr "$WORK"
find "$WORK" -name '._*' -delete
chmod -R go-w "$WORK/root"
pkgbuild --root "$WORK/root" --scripts "$WORK/scripts" \
  --identifier ai.boson.higgs-voiceover.premiere --version "$VERSION" \
  --install-location / "$WORK/raw.pkg" >/dev/null
# As in the Resolve installer: re-pack the payload with ditto so macOS's
# provenance attributes don't ride in as ._ files.
pkgutil --expand "$WORK/raw.pkg" "$WORK/exp"
rm -rf "$WORK/exp/Payload" "$WORK/exp/Bom"
ditto -c -z --norsrc --noextattr --noacl "$WORK/root" "$WORK/exp/Payload"
mkbom "$WORK/root" "$WORK/exp/Bom"
pkgutil --flatten "$WORK/exp" "$WORK/component.pkg"
rm -f "$WORK/raw.pkg"
if pkgutil --payload-files "$WORK/component.pkg" | grep -q '/\._'; then
  echo "payload still carries ._ entries" >&2; exit 1
fi

OUT="dist/Higgs-VoiceOver-$VERSION-Premiere-Pro-macOS.pkg"
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
