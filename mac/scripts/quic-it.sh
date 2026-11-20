#!/usr/bin/env bash
# QUIC server integration tests (plan stage 1.6): the real Mac listener against the Rust client of the phone side, over localhost.
#
#   mac/scripts/quic-it.sh            # build the client, regenerate the project, run QuicListenerIntegrationTests
#   mac/scripts/quic-it.sh --release  # also prove that a Release build has no debug `echo` kind (see the end)
#
# The tests are skipped, not failed, when the client binary is missing, so a plain `xcodebuild test` still works without Rust.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

echo "== building the Rust clients (examples/echo_client = protocol probe, examples/session_client = the shipping client)"
(cd "$repo/mobile/native-src/quic-core" && cargo build --example echo_client --example session_client)

echo "== running the integration tests"
cd "$repo/mac"
xcodegen generate >/dev/null
xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -destination 'platform=macOS' \
  -only-testing:LinkToMacTests/QuicListenerIntegrationTests -only-testing:LinkToMacTests/QuicProductionClientIntegrationTests test 2>&1 | grep -E "error:|✘|✔|Test run with|TEST (FAILED|SUCCEEDED)" || true

if [[ "${1:-}" == "--release" ]]; then
  echo "== Release build: the debug-only echo code must not be in the binary"
  out="$(mktemp -d)"
  xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -configuration Release -derivedDataPath "$out" build >/dev/null
  app="$(find "$out" -name 'LinkToMac' -path '*MacOS*' -type f | head -n1)"
  # Positive control first: the same marker MUST be in a Debug build, or the check below proves nothing.
  dbg="$(mktemp -d)"
  xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -configuration Debug -derivedDataPath "$dbg" build >/dev/null
  debug_bin="$(find "$dbg" -path '*MacOS/LinkToMac*' -type f \( -name 'LinkToMac' -o -name 'LinkToMac.debug.dylib' \))"
  found=0
  for f in $debug_bin; do if strings "$f" | grep -q "debug echo kind is enabled"; then found=1; fi; done
  rm -rf "$dbg"
  if [[ $found -ne 1 ]]; then echo "FAIL: the marker is not in the Debug build, so this check cannot tell anything"; rm -rf "$out"; exit 1; fi
  if strings "$app" | grep -q "debug echo kind is enabled"; then echo "FAIL: the echo code is in the Release binary"; rm -rf "$out"; exit 1; fi
  echo "ok: the debug echo is in Debug and not in Release"
  rm -rf "$out"
fi
