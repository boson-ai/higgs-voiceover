#!/bin/bash
# Install Higgs VoiceOver into DaVinci Resolve's Utility scripts menu.
#
#   ./install.sh              install or update
#   ./install.sh --uninstall  remove the script (settings and voices are kept)
#
# Writes only to a per-user folder — no admin rights, nothing added elsewhere.

set -euo pipefail

SCRIPT_NAME="Higgs VoiceOver.lua"
# Earlier file names. Resolve lists every script in the folder, so a copy
# left under an old name would put the product in the menu twice.
LEGACY_NAMES=("Higgs VO.lua")
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Higgs VoiceOver runs on macOS."
  exit 1
fi
DEST="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility"
DATA="$HOME/Library/Application Support/HiggsVO"

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$DEST/$SCRIPT_NAME"
  for old in "${LEGACY_NAMES[@]}"; do rm -f "$DEST/$old"; done
  echo "Removed $DEST/$SCRIPT_NAME"
  echo "Your settings, voices and takes are still in $DATA"
  exit 0
fi

if [[ ! -f "$SRC_DIR/$SCRIPT_NAME" ]]; then
  echo "Error: $SCRIPT_NAME not found next to this installer."
  echo "Build it first:  fuscript -l lua build.lua"
  exit 1
fi

mkdir -p "$DEST"
cp "$SRC_DIR/$SCRIPT_NAME" "$DEST/"
for old in "${LEGACY_NAMES[@]}"; do
  if [[ -f "$DEST/$old" ]]; then rm -f "$DEST/$old"; echo "Removed the old menu entry: $old"; fi
done

echo "Installed: $DEST/$SCRIPT_NAME"
echo
echo "In DaVinci Resolve:  Workspace > Scripts > Higgs VoiceOver"
echo "If Resolve is already open, restart it so the menu picks up the script."
