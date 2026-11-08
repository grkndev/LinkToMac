#!/bin/zsh
# Package a built .app as the drag-to-install DMG with the designed install window.
#   scripts/make-dmg.sh <path/to/LinkToMac.app> <version> <out.dmg>
#
# Needs `dmgbuild` (pure Python; writes the Finder .DS_Store directly, so no Finder session or
# AppleScript is involved and it works headless). It is installed on first use into a repo-local
# venv (mac/build/dmgbuild-venv), so nothing is installed globally. The background is rendered per
# call because it carries the version. Signing / notarising the DMG is the caller's job.
set -euo pipefail

APP=${1:?usage: make-dmg.sh <app> <version> <out.dmg>}
VERSION=${2:?version}
DMG=${3:?output path}
HERE=${0:A:h}
VENV="$HERE/../build/dmgbuild-venv"

[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "==> installing dmgbuild into $VENV (first run only)"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet dmgbuild
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Background: 660 × 400 + @2x merged into one multi-resolution TIFF so Finder picks per display.
swift "$HERE/dmg/make-background.swift" "$VERSION" "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

# The disk's icon is the app's own.
cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/VolumeIcon.icns"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$HERE/dmg/settings.py" \
  -D app="$APP" -D background="$WORK/background.tiff" -D volicon="$WORK/VolumeIcon.icns" \
  "Link to Mac $VERSION" "$DMG" >/dev/null
echo "==> $DMG"
