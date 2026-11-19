#!/usr/bin/env bash
#
# Cross-compile the quic-core Rust crate for Android (arm64-v8a) and drop libquic_core.so into the
# selfadb native module's jniLibs, so it ships inside the dev-client / release APK.
#
# Output: ../../modules/selfadb/android/src/main/jniLibs/arm64-v8a/libquic_core.so   (NOT committed: gitignored)
#
# Rebuild ONLY when the Rust sources change. Run it before cutting a release; without the .so the app still
# builds (Gradle only warns) but QUIC is silently unavailable in that build.
#
# Requirements: rustup + cargo, the aarch64-linux-android target, cargo-ndk, and the NDK that Gradle uses
# (the version is read from React Native's libs.versions.toml so the two cannot drift).
#   rustup target add aarch64-linux-android
#   cargo install cargo-ndk --locked
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOBILE="$(cd "$HERE/../.." && pwd)"
OUT_JNI="$MOBILE/modules/selfadb/android/src/main/jniLibs"
SO="$OUT_JNI/arm64-v8a/libquic_core.so"

# --platform must match the app/module minSdk (30). It now has to match in FOUR places: the module's
# build.gradle, app.config.ts (expo-build-properties), build-dex.sh's --min-api and this script.
MIN_SDK=30

: "${ANDROID_SDK_ROOT:=${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
if [[ ! -d "$ANDROID_SDK_ROOT" ]]; then
  echo "ERROR: Android SDK not found at '$ANDROID_SDK_ROOT'. Set ANDROID_SDK_ROOT." >&2
  exit 1
fi

# Same NDK as Gradle: React Native pins it in libs.versions.toml (ndkVersion = "27.1.12297006").
RN_TOML="$MOBILE/node_modules/react-native/gradle/libs.versions.toml"
NDK_VERSION="${NDK_VERSION:-$(grep -E '^ndkVersion' "$RN_TOML" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || true)}"
[[ -n "$NDK_VERSION" ]] || { echo "ERROR: could not read ndkVersion from $RN_TOML (run bun install, or set NDK_VERSION)." >&2; exit 1; }
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
[[ -d "$ANDROID_NDK_HOME" ]] || { echo "ERROR: NDK $NDK_VERSION not installed at $ANDROID_NDK_HOME (sdkmanager \"ndk;$NDK_VERSION\")." >&2; exit 1; }

command -v cargo >/dev/null     || { echo "ERROR: cargo not found (install rustup)." >&2; exit 1; }
command -v cargo-ndk >/dev/null || { echo "ERROR: cargo-ndk not found. Run: cargo install cargo-ndk --locked" >&2; exit 1; }
rustup target list --installed 2>/dev/null | grep -qx 'aarch64-linux-android' \
  || { echo "ERROR: Rust target missing. Run: rustup target add aarch64-linux-android" >&2; exit 1; }

echo "SDK:   $ANDROID_SDK_ROOT"
echo "NDK:   $NDK_VERSION"
echo "rustc: $(rustc --version)"
echo "ndk:   $(cargo ndk --version 2>/dev/null | head -1)"
echo "min:   android-$MIN_SDK"
echo

cd "$HERE"
START=$SECONDS
cargo ndk -t arm64-v8a --platform "$MIN_SDK" -o "$OUT_JNI" build --release
echo "built in $((SECONDS - START)) s"

[[ -f "$SO" ]] || { echo "ERROR: expected $SO was not produced." >&2; exit 1; }

# Both JNI entry points must be exported, or QuicCore.kt would fail at the first call.
NM="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-nm | head -1)"
SYMS="$("$NM" -D --defined-only "$SO")"
for sym in Java_expo_modules_selfadb_quic_QuicCore_nativePing Java_expo_modules_selfadb_quic_QuicCore_nativeProbe; do
  grep -q "$sym" <<<"$SYMS" || { echo "ERROR: $sym not exported by $SO" >&2; exit 1; }
done

echo
echo "OK -> $SO ($(du -h "$SO" | cut -f1))"
echo "JNI symbols: nativePing, nativeProbe exported"
echo "Now rebuild the dev client so the library is bundled."
