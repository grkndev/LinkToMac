#!/usr/bin/env bash
# Looks at the Files screen while a transfer is IN PROGRESS (the state that used to crash it with "Too many re-renders").
#
#   mobile/scripts/files-ui-check.sh [size-in-MB]        (default 800)
#
# Needs: the phone's DEBUG dev build running against Metro, linked to a Mac that is running (LAN or relay), `adb`. The file is staged into the
# app's cache with `run-as`, then the debug receiver's SEND_FILE action sends it exactly like the share sheet's "Send as a File" would; the Files
# screen is opened by deep link while it is sending. Result: the JS error log, a screenshot, and PASS/FAIL.
# The received file lands in the Mac's download folder (~/Downloads/Link to Mac by default): delete it afterwards (this script says which).
set -uo pipefail
MB="${1:-800}"
PKG="${PKG:-com.grkndev.linktomac.dev}"
RECEIVER="expo.modules.selfadb.QuicSelfTestReceiver"
ADB=(adb); [[ -n "${ANDROID_SERIAL:-}" ]] && ADB=(adb -s "$ANDROID_SERIAL")
NAME="ltm-ui-check-$$.bin"
OUT="${OUT:-/tmp}"; mkdir -p "$OUT"
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

command -v adb >/dev/null || { echo "adb not found"; exit 2; }
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device"; exit 2; }

echo "== staging a ${MB} MB file"
local_file="$(mktemp -t ltm-ui-check)"; mkfile -n "${MB}m" "$local_file"
"${ADB[@]}" push "$local_file" "/data/local/tmp/$NAME" >/dev/null
rm -f "$local_file"
"${ADB[@]}" shell "chmod 644 /data/local/tmp/$NAME; run-as $PKG sh -c 'mkdir -p cache/outbox && cp /data/local/tmp/$NAME cache/outbox/$NAME'" || { bad "could not stage the file with run-as (is $PKG a debug build?)"; exit 1; }
"${ADB[@]}" shell "rm -f /data/local/tmp/$NAME"

echo "== opening the Files screen, then sending"
"${ADB[@]}" logcat -c
"${ADB[@]}" shell am start -a android.intent.action.VIEW -p "$PKG" -d "linktomac://files" >/dev/null 2>&1
sleep 3
"${ADB[@]}" shell am broadcast -n "$PKG/$RECEIVER" -a expo.modules.selfadb.SEND_FILE --es name "$NAME" >/dev/null 2>&1
for _ in $(seq 1 20); do "${ADB[@]}" logcat -d | grep -q "files-debug: sending a staged file" && break; sleep 0.5; done
"${ADB[@]}" logcat -d | grep -q "files-debug: sending a staged file" || { bad "the app did not start sending (is the service running?)"; exit 1; }

echo "== watching the screen for ~25 s while it sends"
sleep 8
"${ADB[@]}" exec-out screencap -p > "$OUT/files-ui-during.png"
sleep 17
"${ADB[@]}" exec-out screencap -p > "$OUT/files-ui-later.png"
LOG="$("${ADB[@]}" logcat -d -s ReactNativeJS:V '*:E' | grep -iE 'too many re-renders|Invariant Violation|Error: ' | head -5)"
if echo "$LOG" | grep -qi "too many re-renders"; then bad "\"Too many re-renders\" appeared while a transfer was in progress"; else ok "no \"Too many re-renders\" while a transfer was in progress"; fi
[[ -n "$LOG" ]] && echo "$LOG" | cut -c1-200
echo "   screenshots: $OUT/files-ui-during.png  $OUT/files-ui-later.png"
echo "   cleanup: the Mac keeps the received file in its download folder (look for $NAME or a similar name) — delete it"
"${ADB[@]}" shell "run-as $PKG rm -f cache/outbox/$NAME" 2>/dev/null
[[ $fail -eq 0 ]]
