#!/usr/bin/env bash
#
# Build a distributable macOS build of LinkToMac, package it as a drag-to-install DMG, sign it for
# Sparkle, and generate the update appcast. Optionally publish the DMG + appcast to GitHub Releases.
#
#   ./scripts/build-release.sh              # build + DMG + appcast (local only)
#   ./scripts/build-release.sh --publish    # also: gh release create/upload to GitHub
#   → mac/build/release/LinkToMac-<version>.dmg
#   → mac/build/release/appcast.xml
#
# The app is ad-hoc signed (no Apple Developer team; matches project.yml). It is therefore
# NOT notarized: on another Mac, Gatekeeper quarantines a downloaded copy. First launch must be
# right-click → Open (or `xattr -dr com.apple.quarantine /Applications/LinkToMac.app`). See README.
#
# Sparkle update signing uses the EdDSA private key stored in the login Keychain by
# `generate_keys` (its public half is SUPublicEDKey in Info.plist) — no Apple account needed.
#
# IMPORTANT: Sparkle decides "is there a newer version?" by CFBundleVersion (CURRENT_PROJECT_VERSION
# in project.yml). Bump it on every release or existing installs won't see the update.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> mac/

SCHEME=LinkToMac
CONFIG=Release
DD=build/dd
OUT=build/release
SPARKLE_VERSION=2.6.4
REPO=grkndev/LinkToMac
DOWNLOAD_BASE="https://github.com/$REPO/releases/download"

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

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

# --- Sparkle: sign the DMG + write the appcast --------------------------------------------------
# We assemble a single-entry appcast from `sign_update` (reads the EdDSA key from the Keychain)
# rather than `generate_appcast`, which doesn't emit signatures in this toolchain. One entry is all
# Sparkle needs to offer the latest build; the enclosure points at this version's release asset.
TOOLS=build/sparkle-tools/bin
if [ ! -x "$TOOLS/sign_update" ]; then
  echo "==> fetching Sparkle $SPARKLE_VERSION tools"
  mkdir -p build/sparkle-tools
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    -o build/sparkle-tools/sparkle.tar.xz
  tar -xf build/sparkle-tools/sparkle.tar.xz -C build/sparkle-tools
fi

echo "==> sign DMG + write appcast"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "14.0")
# sign_update prints:  sparkle:edSignature="…" length="…"
SIGN_ATTRS="$("$TOOLS/sign_update" "$DMG")"
case "$SIGN_ATTRS" in *edSignature=*) ;; *) echo "error: sign_update produced no signature" >&2; exit 1;; esac
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>LinkToMac</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
            <enclosure url="$DOWNLOAD_BASE/v$VERSION/$SCHEME-$VERSION.dmg" $SIGN_ATTRS type="application/octet-stream"/>
        </item>
    </channel>
</rss>
XML
echo "==> appcast: $OUT/appcast.xml"

# --- Publish to GitHub Releases (opt-in) -------------------------------------------------------
if [ "$PUBLISH" -eq 1 ]; then
  command -v gh >/dev/null || { echo "error: gh CLI not found (brew install gh)" >&2; exit 1; }
  echo "==> publishing GitHub release v$VERSION"
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --clobber
  else
    gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" \
      --title "LinkToMac $VERSION" --notes "LinkToMac $VERSION"
  fi
  echo "==> published: https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "==> local build only — run with --publish to upload the DMG + appcast to GitHub Releases"
fi

echo "==> done: $DMG"
