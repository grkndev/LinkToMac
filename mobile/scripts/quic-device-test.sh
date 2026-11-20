#!/usr/bin/env bash
# On-device end-to-end check of the QUIC client (plan stage 1.7): the real phone (Rust quinn client through JNI) against the real Mac
# listener (a Debug build of the Mac app, which serves the debug `echo` kind), over the LAN.
#
#   mobile/scripts/quic-device-test.sh                 # all three scenarios
#   ANDROID_SERIAL=<serial> mobile/scripts/quic-device-test.sh
#
# Preconditions (the script checks what it can):
#   * the phone runs the DEBUG dev build (`com.grkndev.linktomac.dev`, built after stage 1.7: `bun run android`) with the app OPEN (so its
#     foreground service is up; the dev client needs Metro for that: `bun run start`) and linked to the Mac over the LAN, `adb` sees it;
#   * on the Mac, the Debug build of Link to Mac is running and paired with that phone, and the installed release app is QUIT (two
#     instances would fight for the LAN port and the relay room);
#   * Mac and phone are on the same Wi-Fi.
#
# Scenarios (each is an `am broadcast` to the debug-variant-only QuicSelfTestReceiver; a release build has neither the receiver nor the action):
#   none  correct fingerprint + token  -> expects `quic-selftest: PASS echo`
#   fp    one character of the fingerprint flipped -> expects `PASS FpMismatch`
#   tok   one character of the token flipped       -> expects `PASS TokenRejected`
# Afterwards the whole log of the run is searched for what must never be there: the Mac's address, the port, the fingerprint and
# anything shaped like a token. It must find none.
set -uo pipefail

PKG="${PKG:-com.grkndev.linktomac.dev}"
RECEIVER="expo.modules.selfadb.QuicSelfTestReceiver"
ACTION="expo.modules.selfadb.QUIC_SELFTEST"
ADB=(adb)
[[ -n "${ANDROID_SERIAL:-}" ]] && ADB=(adb -s "$ANDROID_SERIAL")

command -v adb >/dev/null || { echo "adb not found"; exit 2; }
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device (set ANDROID_SERIAL if several are attached)"; exit 2; }
"${ADB[@]}" shell pm list packages --user 0 "$PKG" 2>/dev/null | grep -q "$PKG" || { echo "$PKG is not installed on the phone"; exit 2; }

MAC_IP="${MAC_IP:-$(ipconfig getifaddr en0 2>/dev/null || true)}"
# The Mac's QUIC certificate fingerprint(s): what the phone pins. Read from the login keychain (CN "LinkToMac").
FPS="$(security find-certificate -a -c LinkToMac -p 2>/dev/null | awk '/BEGIN CERT/{c=""} {c=c $0 "\n"} /END CERT/{print c "\0"}' | while IFS= read -r -d '' pem; do printf '%s' "$pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ':' | tr 'A-F' 'a-f'; done)"

LOG="$(mktemp)"
fail=0
run() {
  local tamper="$1" expect="$2"
  "${ADB[@]}" logcat -c
  "${ADB[@]}" shell am broadcast -n "$PKG/$RECEIVER" -a "$ACTION" --es tamper "$tamper" >/dev/null 2>&1
  local verdict=""
  for _ in $(seq 1 60); do
    sleep 0.5
    verdict="$("${ADB[@]}" logcat -d -s LinkToMac:I | grep -o 'quic-selftest: .*' | tail -1 || true)"
    [[ -n "$verdict" ]] && break
  done
  "${ADB[@]}" logcat -d -s LinkToMac:I >>"$LOG"
  if [[ "$verdict" == "quic-selftest: $expect" ]]; then
    echo "ok   tamper=$tamper -> $verdict"
  else
    echo "FAIL tamper=$tamper -> '${verdict:-no verdict}' (expected 'quic-selftest: $expect')"
    fail=1
  fi
  sleep 2
}

run none "PASS echo"
run fp "PASS FpMismatch"
run tok "PASS TokenRejected"

echo "-- privacy scan of ${LOG}"
leaks=0
# The app's other code legitimately logs numbers (the on-device daemon bridge listens on 53125 too), so what is address-, port- and
# session-shaped is checked on the QUIC lines only; a fingerprint or a token has no business ANYWHERE in the log.
QLOG="$(mktemp)"
grep -i 'quic' "$LOG" >"$QLOG" || true
scan() { # file, description, fixed string
  [[ -z "$3" ]] && return
  if grep -qF "$3" "$1"; then echo "LEAK: the log contains $2"; leaks=1; fi
}
scan "$QLOG" "the Mac's address" "$MAC_IP"
scan "$QLOG" "the QUIC port" "53125"
for fp in $FPS; do scan "$LOG" "a certificate fingerprint" "$fp"; done
if grep -Eq '[A-Za-z0-9_-]{43}' "$LOG"; then echo "LEAK?: something shaped like a token (43 base64url characters) is in the log:"; grep -Eo '.{0,30}[A-Za-z0-9_-]{43}.{0,10}' "$LOG" | head -3; leaks=1; fi
echo "   ($(wc -l <"$QLOG" | tr -d ' ') QUIC log lines scanned, $(wc -l <"$LOG" | tr -d ' ') lines in all)"
[[ $leaks -eq 0 ]] && echo "ok   no address, port, fingerprint or token in the QUIC log lines"
echo "log kept at $LOG"
[[ $fail -eq 0 && $leaks -eq 0 ]]
