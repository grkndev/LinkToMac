#!/usr/bin/env bash
# On-device end-to-end checks of the QUIC data plane (plan stages 1.7 and 1.8): the real phone (Rust quinn client through JNI) against the
# real Mac (a Debug build of the Mac app, which serves the debug `echo` kind), over the LAN.
#
#   mobile/scripts/quic-device-test.sh [basic|link|relay|macasked|oldmac|all]      (default: basic; `all` = everything but oldmac)
#   ANDROID_SERIAL=<serial> mobile/scripts/quic-device-test.sh link
#
# Scenarios
#   basic     correct fingerprint + token -> `PASS echo`; one fingerprint character flipped -> `PASS FpMismatch`; one token character flipped
#             -> `PASS TokenRejected`; then a privacy scan of the log.
#   link      a session is held open; the phone's Wi-Fi is switched off; BOTH ends must have closed within 5 s (the phone's session ends, the
#             Mac holds no QUIC socket any more). The phone tells the Mac with a q.end over the relay, so the phone needs MOBILE DATA and a
#             reachable relay; without them the Mac only notices after QUIC's own 30 s idle time and this scenario reports that honestly.
#   relay     Wi-Fi off: asking is refused plainly ("needs the same Wi-Fi") and a FORCED request makes the Mac refuse (`PASS Refused:relay`).
#   macasked  the Mac asks (`open -a <Debug app> linktomac://quic-test`): the phone accepts on its own, runs the echo check, ends the session;
#             the Mac's log says `Completed`.
#   oldmac    the installed pre-QUIC Mac app (v0.13.0) must run INSTEAD of the Debug build: the gate hides QUIC (no `caps`), a FORCED request is
#             ignored by the old app (`PASS NoAnswer` after 10 s) and the Mac's screen is not locked by it.
#
# Preconditions (checked where possible)
#   * the phone runs the DEBUG dev build (`com.grkndev.linktomac.dev`, `bun run android`) with the app OPEN (so its foreground service is
#     up; the dev client needs Metro for that: `bun run start`), linked to the Mac over the LAN, `adb` sees it;
#   * basic/link/relay/macasked: the Debug build of Link to Mac runs on the Mac, paired with that phone, with the installed release app QUIT
#     (two instances fight for the LAN port and the relay room). Start it with its stdout in a log so `macasked` can read the verdict:
#         nohup "<...>/Debug/LinkToMac.app/Contents/MacOS/LinkToMac" > /tmp/linktomac-debug.log 2>&1 &
#   * Mac and phone are on the same Wi-Fi.
set -uo pipefail

SCENARIO="${1:-basic}"
PKG="${PKG:-com.grkndev.linktomac.dev}"
RECEIVER="expo.modules.selfadb.QuicSelfTestReceiver"
ACTION="expo.modules.selfadb.QUIC_SELFTEST"
MAC_LOG="${MAC_LOG:-/tmp/linktomac-debug.log}"
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
now() { python3 -c 'import time; print(time.time())'; }
mac_debug_pid() { pgrep -f "Debug/LinkToMac.app/Contents/MacOS/LinkToMac" | head -1; }
# QUIC sockets the Mac Debug app holds (anything but mDNS).
mac_quic_sockets() {
  local pid; pid="$(mac_debug_pid)"
  [[ -z "$pid" ]] && { echo 0; return; }
  lsof -nP -a -p "$pid" -iUDP 2>/dev/null | tail -n +2 | grep -vc ':5353' || true
}
mac_locked() {
  swift -e 'import CoreGraphics
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
print((d["CGSSessionScreenIsLocked"] as? Bool) == true ? "locked" : "unlocked")' 2>/dev/null | tail -1
}
phone_log() { "${ADB[@]}" logcat -d -s LinkToMac:I; }
keep_log() { phone_log >>"$LOG"; }
wifi() { "${ADB[@]}" shell svc wifi "$1" >/dev/null 2>&1; }
restore_wifi() { wifi enable; }
trap restore_wifi EXIT
wait_for_lan() { # up to 60 s
  for _ in $(seq 1 120); do phone_log | grep -q 'lan authenticated' && return 0; sleep 0.5; done
  return 1
}
broadcast() { "${ADB[@]}" shell am broadcast -n "$PKG/$RECEIVER" -a "$ACTION" --es tamper "$1" >/dev/null 2>&1; }
verdict() { phone_log | grep -o 'quic-selftest: .*' | tail -1; }
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

run() { # mode, expected verdict text, seconds to wait
  local mode="$1" expect="$2" wait="${3:-30}" v=""
  "${ADB[@]}" logcat -c
  broadcast "$mode"
  for _ in $(seq 1 $((wait * 2))); do sleep 0.5; v="$(verdict)"; [[ -n "$v" ]] && break; done
  keep_log
  if [[ "$v" == "quic-selftest: $expect" ]]; then ok "mode=$mode -> $v"; else bad "mode=$mode -> '${v:-no verdict}' (expected 'quic-selftest: $expect')"; fi
  sleep 2
}

privacy_scan() {
  echo "-- privacy scan of ${LOG}"
  local leaks=0 qlog; qlog="$(mktemp)"
  grep -i 'quic' "$LOG" >"$qlog" || true
  # The app's other code legitimately logs numbers (the on-device daemon bridge listens on 53125 too), so what is address-, port- and
  # session-shaped is checked on the QUIC lines only; a fingerprint or a token has no business ANYWHERE in the log.
  scan() { [[ -z "$3" ]] && return; if grep -qF "$3" "$1"; then echo "LEAK: the log contains $2"; leaks=1; fi; }
  scan "$qlog" "the Mac's address" "$MAC_IP"
  scan "$qlog" "the QUIC port" "53125"
  for fp in $FPS; do scan "$LOG" "a certificate fingerprint" "$fp"; done
  if grep -Eq '[A-Za-z0-9_-]{43}' "$LOG"; then echo "LEAK?: something shaped like a token (43 base64url characters) is in the log:"; grep -Eo '.{0,30}[A-Za-z0-9_-]{43}.{0,10}' "$LOG" | head -3; leaks=1; fi
  echo "   ($(wc -l <"$qlog" | tr -d ' ') QUIC log lines scanned, $(wc -l <"$LOG" | tr -d ' ') lines in all)"
  if [[ $leaks -eq 0 ]]; then ok "no address, port, fingerprint or token in the QUIC log lines"; else fail=1; fi
}

need_debug_mac() { [[ -n "$(mac_debug_pid)" ]] || { echo "the Mac Debug app is not running (see the header)"; exit 2; }; }

scenario_basic() {
  need_debug_mac
  run none "PASS echo"
  run fp "PASS FpMismatch"
  run tok "PASS TokenRejected"
}

scenario_link() {
  need_debug_mac
  "${ADB[@]}" logcat -c
  broadcast hold
  local held=""
  for _ in $(seq 1 30); do sleep 0.5; held="$(phone_log | grep -c 'quic-selftest: HOLDING')"; [[ "$held" -ge 1 ]] && break; done
  [[ "$held" -ge 1 ]] || { bad "the session did not open (no HOLDING)"; keep_log; return; }
  [[ "$(mac_quic_sockets)" -ge 1 ]] || { bad "the Mac holds no QUIC socket although the session is open"; keep_log; return; }
  ok "session open: the phone holds it and the Mac has its QUIC socket"
  local t0 t_phone="" t_mac="" t
  t0="$(now)"; wifi disable
  for _ in $(seq 1 120); do
    t="$(now)"
    if [[ -z "$t_phone" ]] && phone_log | grep -q 'quic-selftest: PASS held until it ended'; then t_phone="$(python3 -c "print(round($t - $t0, 1))")"; fi
    if [[ -z "$t_mac" && "$(mac_quic_sockets)" -eq 0 ]]; then t_mac="$(python3 -c "print(round($t - $t0, 1))")"; fi
    [[ -n "$t_phone" && -n "$t_mac" ]] && break
    sleep 0.25
  done
  keep_log
  echo "   Wi-Fi off at 0 s: the phone's session ended at ${t_phone:-never} s, the Mac released its QUIC socket at ${t_mac:-never} s"
  for pair in "phone:$t_phone" "Mac:$t_mac"; do
    side="${pair%%:*}"; secs="${pair#*:}"
    if [[ -n "$secs" ]] && python3 -c "import sys; sys.exit(0 if $secs <= 5.0 else 1)"; then ok "the $side side closed within 5 s ($secs s)"; else bad "the $side side did not close within 5 s (${secs:-never}); without mobile data / relay the Mac only notices after QUIC's 30 s idle time"; fi
  done
  restore_wifi; wait_for_lan || echo "   (the phone did not rejoin the LAN within 60 s)"
}

scenario_relay() {
  need_debug_mac
  wifi disable; sleep 4
  run force "PASS Refused:relay" 30
  run none "FAIL the Mac does not offer QUIC here (no q1 or not on the LAN)" 15
  restore_wifi; wait_for_lan || echo "   (the phone did not rejoin the LAN within 60 s)"
}

scenario_macasked() {
  need_debug_mac
  [[ -f "$MAC_LOG" ]] || { echo "no Mac log at $MAC_LOG (start the Debug app with its stdout there, see the header)"; exit 2; }
  local app; app="$(ps -o command= -p "$(mac_debug_pid)" | sed 's#/Contents/MacOS/.*##')"
  "${ADB[@]}" logcat -c
  : >"$MAC_LOG.mark"; local before; before="$(wc -l <"$MAC_LOG" | tr -d ' ')"
  open -a "$app" "linktomac://quic-test"
  local done_line=""
  for _ in $(seq 1 60); do sleep 0.5; done_line="$(tail -n +"$((before + 1))" "$MAC_LOG" | grep -E '\[QuicTest\] (Completed|The phone refused|No answer|The phone never|Ended)' | tail -1)"; [[ -n "$done_line" ]] && break; done
  keep_log
  if [[ "$done_line" == *"Completed"* ]]; then ok "Mac: $done_line"; else bad "Mac: '${done_line:-no verdict}' ($(tail -n +"$((before + 1))" "$MAC_LOG" | grep '\[QuicTest\]' | tail -3 | tr '\n' ' '))"; fi
  phone_log | grep -q 'quic-selftest: PASS echo' && ok "phone: PASS echo" || bad "phone: no PASS echo"
}

scenario_oldmac() {
  [[ -z "$(mac_debug_pid)" ]] || { echo "quit the Mac Debug app first: this scenario needs the installed (old) app instead"; exit 2; }
  pgrep -f "/Applications/LinkToMac.app/Contents/MacOS" >/dev/null || { echo "the installed Link to Mac app is not running"; exit 2; }
  local v; v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/LinkToMac.app/Contents/Info.plist 2>/dev/null)"
  echo "   installed app: v${v:-?}"
  [[ "$(mac_locked)" == "unlocked" ]] || { echo "the Mac is locked before the test starts"; exit 2; }
  run none "FAIL the Mac does not offer QUIC here (no q1 or not on the LAN)" 15
  run force "PASS NoAnswer" 40
  [[ "$(mac_locked)" == "unlocked" ]] && ok "the old Mac ignored the request and did not lock" || bad "the Mac LOCKED"
}

case "$SCENARIO" in
  basic) scenario_basic ;;
  link) scenario_link ;;
  relay) scenario_relay ;;
  macasked) scenario_macasked ;;
  oldmac) scenario_oldmac ;;
  all) scenario_basic; scenario_macasked; scenario_link; scenario_relay ;;
  *) echo "unknown scenario '$SCENARIO'"; exit 2 ;;
esac

privacy_scan
echo "log kept at $LOG"
[[ $fail -eq 0 ]]
