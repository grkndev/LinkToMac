#!/usr/bin/env bash
#
# Build a distributable macOS build of LinkToMac and package it as a drag-to-install DMG.
#
#   ./scripts/build-release.sh
#   → mac/build/release/LinkToMac-<version>.dmg
#
# The app is ad-hoc signed (no Apple Developer team; matches project.yml). It is therefore
# NOT notarized: on another Mac, Gatekeeper quarantines a downloaded copy. First launch must be
# right-click → Open (or `xattr -dr com.apple.quarantine /Applications/LinkToMac.app`). See README.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> mac/

SCHEME=LinkToMac
CONFIG=Release
DD=build/dd
OUT=build/release

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild ($CONFIG)"
xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DD" build

APP="$DD/Build/Products/$CONFIG/$SCHEME.app"
[ -d "$APP" ] || { echo "error: build product not found at $APP" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "==> version $VERSION"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> package DMG"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$SCHEME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$SCHEME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> done: $DMG"
