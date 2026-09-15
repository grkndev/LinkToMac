#!/usr/bin/env bash
#
# Build a distributable macOS build of LinkToMac, package it as a drag-to-install DMG, sign it for
# Sparkle, and generate the update appcast. Optionally publish the DMG + appcast to GitHub Releases.
#
#   ./scripts/build-release.sh              # build + DMG + appcast (local only)
#   ./scripts/build-release.sh --publish    # also: gh release create/upload to GitHub
#   ./scripts/build-release.sh --publish --no-notes   # publish with a placeholder body
#   → mac/build/release/LinkToMac-<version>.dmg
#   → mac/build/release/appcast.xml
#
# Release notes live in `release-notes/v<version>.md` at the repo root (they cover BOTH apps, not
# just the Mac). Publishing without one is refused up front — 0.9.0 shipped with a "LinkToMac 0.9.0"
# placeholder body because nothing stopped it, and the notes had to be pasted in afterwards.
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
REQUIRE_NOTES=1
for arg in "$@"; do
  case "$arg" in
    --publish)  PUBLISH=1 ;;
    --no-notes) REQUIRE_NOTES=0 ;;
    *) echo "error: unknown argument '$arg' (expected --publish and/or --no-notes)" >&2; exit 1 ;;
  esac
done

# Resolve the version from project.yml rather than the built bundle, so a missing release-notes
# file fails NOW instead of after a full Release build + DMG + Sparkle signing.
NOTES_DIR=../release-notes
PLANNED_VERSION=$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' project.yml)
NOTES_FILE="$NOTES_DIR/v$PLANNED_VERSION.md"
if [ "$PUBLISH" -eq 1 ] && [ "$REQUIRE_NOTES" -eq 1 ] && [ ! -s "$NOTES_FILE" ]; then
  cat >&2 <<EOF
error: no release notes for v$PLANNED_VERSION

  Write them here, then re-run:
    $(cd .. && pwd)/release-notes/v$PLANNED_VERSION.md

  They are the release body on GitHub and cover BOTH apps. Past releases are the
  format to follow. To publish anyway with a placeholder body: --no-notes
EOF
  exit 1
fi

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

# `--deep` re-signs nested code with NO entitlements, which silently strips the Share extension's
# sandbox entitlement — and macOS refuses to register an unsandboxed app extension at all, so the
# Finder "Send to Phone" entry would just never appear in a released build (it works fine from a
# local xcodebuild, which is what makes this easy to miss). Re-sign the extension with its
# entitlements, then re-seal the outer bundle WITHOUT --deep so it doesn't clobber it again.
APPEX="$APP/Contents/PlugIns/SendToPhone.appex"
if [ -d "$APPEX" ]; then
  echo "==> re-sign Share extension with entitlements"
  codesign --force --sign - --entitlements ShareExtension/ShareExtension.entitlements "$APPEX"
  codesign --force --sign - "$APP"
  codesign -d --entitlements - "$APPEX" 2>&1 | grep -q "app-sandbox" \
    || { echo "ERROR: Share extension lost its sandbox entitlement" >&2; exit 1; }
fi

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
  # Re-resolve against the built version; it should equal PLANNED_VERSION, and if it somehow
  # doesn't, the notes that were validated up front aren't the ones we'd be shipping.
  NOTES_FILE="$NOTES_DIR/v$VERSION.md"
  if [ -s "$NOTES_FILE" ]; then
    NOTES_ARGS=(--notes-file "$NOTES_FILE")
  else
    NOTES_ARGS=(--notes "LinkToMac $VERSION")
  fi
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --clobber
    # A re-publish refreshes the body too, so fixing a typo in the notes doesn't mean editing
    # the release by hand.
    gh release edit "v$VERSION" --repo "$REPO" "${NOTES_ARGS[@]}"
  else
    gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$REPO" \
      --title "LinkToMac $VERSION" "${NOTES_ARGS[@]}"
  fi
  echo "==> published: https://github.com/$REPO/releases/tag/v$VERSION"
else
  echo "==> local build only — run with --publish to upload the DMG + appcast to GitHub Releases"
fi

echo "==> done: $DMG"
