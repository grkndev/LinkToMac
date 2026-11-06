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
# Signing: the app is signed with a Developer ID Application certificate (hardened runtime +
# secure timestamp), then notarized with `notarytool` and stapled — app first, then the DMG. A
# downloaded copy therefore opens on any Mac with no right-click → Open. One-time setup:
#   1. Create a "Developer ID Application" certificate (Xcode ▸ Settings ▸ Accounts ▸ Manage
#      Certificates, or developer.apple.com) — it must be in the login Keychain.
#   2. xcrun notarytool store-credentials "LinkToMac-notary" \
#        --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#      (or --key/--key-id/--issuer with an App Store Connect API key).
# Overrides:  SIGN_IDENTITY="Developer ID Application: …"   NOTARY_PROFILE=<keychain profile name>
# Resume:     RESUME_APP_NOTARY_ID=<submission id> ./scripts/build-release.sh …
#             (continue after the terminal gave up waiting on the app's notarization; reuses the
#             already-signed app instead of rebuilding — see the comment where it is read)
#
#   ./scripts/build-release.sh --adhoc      # local-only build with the old ad-hoc signature: no
#                                           # certificate or notarization, NOT distributable, and the
#                                           # Finder Share extension will not run. --publish refuses it.
#
# Sparkle update signing is separate: it uses the EdDSA private key stored in the login Keychain by
# `generate_keys` (its public half is SUPublicEDKey in Info.plist). It does not depend on the
# Apple certificate, so existing installs can update from an ad-hoc build to a signed one.
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
ADHOC=0
REQUIRE_NOTES=1
for arg in "$@"; do
  case "$arg" in
    --publish)  PUBLISH=1 ;;
    --no-notes) REQUIRE_NOTES=0 ;;
    --adhoc)    ADHOC=1 ;;
    *) echo "error: unknown argument '$arg' (expected --publish, --no-notes and/or --adhoc)" >&2; exit 1 ;;
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

# --- Signing preflight ---------------------------------------------------------------------------
# Resolve the identity and prove the notary credentials work NOW, not after a full Release build.
NOTARY_PROFILE="${NOTARY_PROFILE:-LinkToMac-notary}"
if [ "$ADHOC" -eq 1 ]; then
  if [ "$PUBLISH" -eq 1 ]; then
    echo "error: --adhoc builds are not notarized and must not be published (drop --adhoc)" >&2
    exit 1
  fi
  echo "warning: --adhoc build — not notarized, not distributable" >&2
else
  if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
  fi
  if [ -z "$SIGN_IDENTITY" ]; then
    cat >&2 <<EOF
error: no "Developer ID Application" certificate in the Keychain

  Create one (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application),
  or pass SIGN_IDENTITY="Developer ID Application: Name (TEAMID)". An "Apple Development"
  certificate is NOT enough — it can't be notarized. For a local-only build: --adhoc
EOF
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
error: notarytool can't use keychain profile "$NOTARY_PROFILE"

  Store credentials once:
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
  (app-specific password: account.apple.com ▸ Sign-In and Security). Or set NOTARY_PROFILE.
EOF
    exit 1
  fi
  echo "==> signing as: $SIGN_IDENTITY"
fi

# RESUME_APP_NOTARY_ID=<submission id> continues a previous run whose app notarization outlasted the
# terminal (a first submission from a new account can take hours). It skips build + signing and
# reuses the .app already in $DD: the notarization ticket is bound to that exact signature's
# cdhash, and re-signing (even identical code) mints a new one, so the ticket would no longer fit.
RESUME_ID="${RESUME_APP_NOTARY_ID:-}"
APP="$DD/Build/Products/$CONFIG/$SCHEME.app"

if [ -n "$RESUME_ID" ]; then
  [ "$ADHOC" -eq 0 ] || { echo "error: RESUME_APP_NOTARY_ID makes no sense with --adhoc" >&2; exit 1; }
  [ -d "$APP" ] || { echo "error: nothing to resume — no signed app at $APP" >&2; exit 1; }
  echo "==> resuming: reusing signed app, skipping build + codesign"
else
  echo "==> xcodegen generate"
  xcodegen generate

  echo "==> xcodebuild ($CONFIG)"
  xcodebuild -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$DD" build
fi

[ -d "$APP" ] || { echo "error: build product not found at $APP" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "==> version $VERSION"

# --- Sign ---------------------------------------------------------------------------------------
# Inside-out, one `codesign` per nested bundle, NEVER `--deep`: --deep re-signs nested code with no
# entitlements (it once stripped the Share extension's sandbox entitlement, and macOS then refuses
# to register the extension at all) and Apple has deprecated it for signing. Order matters — a
# parent's seal covers its children's signatures, so every child is signed before its parent.
# Hardened runtime (`--options runtime`) + secure timestamp are what notarization demands; the
# ad-hoc path skips both because neither is available without a real identity.
if [ -z "$RESUME_ID" ]; then   # (body deliberately not indented: it is the whole signing section)
if [ "$ADHOC" -eq 1 ]; then
  SIGN=(codesign --force --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
fi

echo "==> codesign ($([ "$ADHOC" -eq 1 ] && echo ad-hoc || echo Developer ID))"
SPK="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$SPK/Versions/B/XPCServices/Installer.xpc" ] && "${SIGN[@]}" "$SPK/Versions/B/XPCServices/Installer.xpc"
[ -d "$SPK/Versions/B/XPCServices/Downloader.xpc" ] && \
  "${SIGN[@]}" --preserve-metadata=entitlements "$SPK/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPK/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPK/Versions/B/Updater.app"
"${SIGN[@]}" "$SPK"

# The Share extension MUST carry its sandbox entitlement (see ShareExtension.entitlements).
APPEX="$APP/Contents/PlugIns/SendToPhone.appex"
if [ -d "$APPEX" ]; then
  "${SIGN[@]}" --entitlements ShareExtension/ShareExtension.entitlements "$APPEX"
  codesign -d --entitlements - "$APPEX" 2>&1 | grep -q "app-sandbox" \
    || { echo "ERROR: Share extension lost its sandbox entitlement" >&2; exit 1; }
fi
"${SIGN[@]}" --entitlements Resources/LinkToMac.entitlements "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$ADHOC" -eq 0 ]; then
  # The hardened-runtime flag must really be on every bundle notarization will inspect.
  # Capture codesign's output first, then grep the variable. `codesign … | grep -q` under
  # `set -o pipefail` is racy: grep -q exits on the first match, codesign can still be writing,
  # gets SIGPIPE, and the pipeline reports failure even though the flag is present.
  for BUNDLE in "$APP" "$APPEX" "$SPK"; do
    SIG_INFO="$(codesign -dvv "$BUNDLE" 2>&1)"
    grep -q "flags=.*runtime" <<<"$SIG_INFO" \
      || { echo "ERROR: hardened runtime missing on $BUNDLE" >&2; exit 1; }
  done
  ENTS="$(codesign -d --entitlements - "$APP" 2>&1)"
  grep -q "device.bluetooth" <<<"$ENTS" \
    || { echo "ERROR: main app lost its Bluetooth entitlement" >&2; exit 1; }
fi
fi   # end: skipped when resuming

# --- Notarize ---------------------------------------------------------------------------------
# Grep the verdict explicitly rather than trusting notarytool's exit status, and fetch Apple's log
# on rejection (it names the exact offending binary).
notarize() {   # notarize <file> [existing-submission-id]
  local out id
  if [ -n "${2:-}" ]; then
    out="$(xcrun notarytool wait "$2" --keychain-profile "$NOTARY_PROFILE" 2>&1)" || true
  else
    out="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  fi
  echo "$out"
  if ! grep -q "status: Accepted" <<<"$out"; then
    id="$(sed -n 's/^ *id: *\([0-9a-f-]*\).*/\1/p' <<<"$out" | head -1)"
    if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true; fi
    echo "ERROR: notarization of $1 was not accepted" >&2
    exit 1
  fi
}

if [ "$ADHOC" -eq 0 ]; then
  # App first, and staple it, so the copy a user drags out of the DMG also validates offline;
  # then the DMG itself (below) so mounting it is clean too.
  echo "==> notarize app"
  ZIPDIR="$(mktemp -d)"
  ditto -c -k --keepParent "$APP" "$ZIPDIR/$SCHEME.zip"
  notarize "$ZIPDIR/$SCHEME.zip" "$RESUME_ID"
  rm -rf "$ZIPDIR"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
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

if [ "$ADHOC" -eq 0 ]; then
  echo "==> sign + notarize DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  # What Gatekeeper itself will say about a downloaded copy.
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# --- Sparkle: sign the DMG + write the appcast --------------------------------------------------
# Runs AFTER stapling: the EdDSA signature covers the exact bytes users download, and stapling
# rewrites the DMG.
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
