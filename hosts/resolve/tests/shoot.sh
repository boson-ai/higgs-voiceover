#!/bin/bash
# Capture one scenario of the window to PNG.  Usage: tests/shoot.sh <scenario> <out.png>
# The window is placed at a fixed geometry (see ui.lua), so a region capture
# of that rectangle plus its title bar is the whole window.
#
# The script is never killed: UIManager windows belong to Resolve's process,
# and one whose script dies stays on screen and paints over later captures.
# screenshot.lua closes its own window after HIGGS_SHOT_SECONDS instead.
set -e
FUS="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript"
SCEN="$1"; OUT="$2"
export HIGGS_SHOT_DIR="${HIGGS_SHOT_DIR:-/tmp/higgsvo-shots}"
# The Add-a-voice scenarios open a second window after the main one, so they
# need longer before the shutter — and the window must outlive the shutter, or
# the capture catches the main window with no dialog on it.
case "$SCEN" in
  addvoice*) : "${HIGGS_SHOT_DELAY:=5}"; : "${HIGGS_SHOT_SECONDS:=14}"
             # Tall enough for the transcript unfolded. A region that clips the
             # window photographs a bug that is not there — it has cost a
             # review round. Always size it for the tallest state.
             : "${HIGGS_REGION:=1020,95,740,640}" ;;
esac
export HIGGS_SHOT_SECONDS="${HIGGS_SHOT_SECONDS:-7}"
if pgrep -f "screenshot.lua" >/dev/null; then
  echo "a previous capture is still open; waiting for it to close" >&2
  while pgrep -f "screenshot.lua" >/dev/null; do sleep 0.5; done
fi
# Resolve needs a moment to tear the previous window down before the next
# script's one appears; without this, back-to-back runs photograph the main
# window with no dialog on it.
sleep 2
HIGGS_SCENARIO="$SCEN" "$FUS" -l lua tests/screenshot.lua >/tmp/higgsvo-shot.log 2>&1 &
PID=$!
# The Add-a-voice scenarios open a second window after the main one, so they
# need longer before the shutter than a plain page does.
sleep "${HIGGS_SHOT_DELAY:-3}"
# Escape first: a menu left open anywhere paints over the capture.
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
osascript -e 'tell application "DaVinci Resolve" to activate' >/dev/null 2>&1 || true
sleep 1.5
screencapture -x -R "${HIGGS_REGION:-150,50,1020,810}" "$OUT"
wait $PID || true
if grep -q "attempt to\|error" /tmp/higgsvo-shot.log; then echo "LOG:"; grep -v "Interpreter\|Copyright\|^$" /tmp/higgsvo-shot.log; fi
echo "captured $SCEN -> $OUT"
