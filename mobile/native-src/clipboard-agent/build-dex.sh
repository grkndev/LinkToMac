#!/usr/bin/env bash
#
# Compile ClipboardAgent.java -> classes -> dex, then drop the dex into the
# selfadb native module's assets so it ships inside the dev-client APK.
#
# Output: ../../modules/selfadb/android/src/main/assets/clipboard-agent.dex
#
# Requirements: a local Android SDK with build-tools (for d8) and a platform
# (android.jar). Override ANDROID_SDK_ROOT if auto-detection fails.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_ASSET="$HERE/../../modules/selfadb/android/src/main/assets"
BUILD="$HERE/build"

: "${ANDROID_SDK_ROOT:=${ANDROID_HOME:-$HOME/Library/Android/sdk}}"

if [[ ! -d "$ANDROID_SDK_ROOT" ]]; then
  echo "ERROR: Android SDK not found at '$ANDROID_SDK_ROOT'." >&2
  echo "       Set ANDROID_SDK_ROOT to your SDK path and re-run." >&2
  exit 1
fi

BT_DIR="$(ls -d "$ANDROID_SDK_ROOT"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
PLATFORM_JAR="$(ls "$ANDROID_SDK_ROOT"/platforms/*/android.jar 2>/dev/null | sort -V | tail -1 || true)"
D8="$BT_DIR/d8"

[[ -n "$BT_DIR"       ]] || { echo "ERROR: no build-tools in $ANDROID_SDK_ROOT/build-tools" >&2; exit 1; }
[[ -n "$PLATFORM_JAR" ]] || { echo "ERROR: no platform android.jar in $ANDROID_SDK_ROOT/platforms" >&2; exit 1; }
[[ -x "$D8"           ]] || { echo "ERROR: d8 not found/executable at $D8" >&2; exit 1; }

echo "SDK:         $ANDROID_SDK_ROOT"
echo "build-tools: $BT_DIR"
echo "platform:    $PLATFORM_JAR"
echo

rm -rf "$BUILD"
mkdir -p "$BUILD/classes" "$OUT_ASSET"

# Stamp the build into DEX_VERSION so the daemon logs which dex it is on every start
# ("server up. dex=<stamp> ..."). Compile a stamped COPY — the checked-in source keeps "dev".
DEX_STAMP="$(date +%Y%m%d-%H%M)"
mkdir -p "$BUILD/src"
sed "s/DEX_VERSION = \"dev\"/DEX_VERSION = \"$DEX_STAMP\"/" \
    "$HERE/ClipboardAgent.java" > "$BUILD/src/ClipboardAgent.java"

echo "[1/3] javac (dex version $DEX_STAMP)"
javac -source 1.8 -target 1.8 -cp "$PLATFORM_JAR" \
      -d "$BUILD/classes" "$BUILD/src/ClipboardAgent.java"

# --min-api must match the app/module minSdk (30, see modules/selfadb/android/build.gradle
# and app.config.ts expo-build-properties): a higher value lets d8 emit newer dex
# features/instructions that Android 11-13 could refuse to load.
echo "[2/3] d8 -> dex (min-api 30)"
# shellcheck disable=SC2046
"$D8" $(find "$BUILD/classes" -name '*.class') \
      --lib "$PLATFORM_JAR" --min-api 30 --output "$BUILD"

echo "[3/3] copy asset"
cp "$BUILD/classes.dex" "$OUT_ASSET/clipboard-agent.dex"

echo
echo "OK -> $OUT_ASSET/clipboard-agent.dex"
echo "Now rebuild the dev client so the asset is bundled."
