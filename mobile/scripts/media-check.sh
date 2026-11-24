#!/usr/bin/env bash
# Does the phone start following a media session whose title arrives AFTER the session became active (what many real players do)?
#
#   mobile/scripts/media-check.sh
#
# Needs: the phone's DEBUG dev build running, "Mirror media" ON (Settings), notification access granted, `adb`. The debug receiver creates a
# media session of the app's own, activates it, and writes its title and PLAYING three seconds later (`FakeMedia`). The phone's log says
# "media: session followed of N" once it follows a session and "... none of N" when it picked nothing.
#   PASS = a session is followed after the title appears.   FAIL = it never is (the card on the Mac stays empty).
# DELAY_MS=0 is the positive control: the title is written at once, so the session already has one when the list changes (always worked).
# Close other media apps first: with several sessions present the result is not attributable ("of N" with N > 1), and the script says so.
set -uo pipefail
PKG="${PKG:-com.grkndev.linktomac.dev}"
RECEIVER="expo.modules.selfadb.QuicSelfTestReceiver"
ADB=(adb); [[ -n "${ANDROID_SERIAL:-}" ]] && ADB=(adb -s "$ANDROID_SERIAL")
DELAY_MS="${DELAY_MS:-3000}"
bc() { "${ADB[@]}" shell am broadcast -n "$PKG/$RECEIVER" -a "$1" --el delay "$DELAY_MS" >/dev/null 2>&1; }

command -v adb >/dev/null || { echo "adb not found"; exit 2; }
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device"; exit 2; }

bc expo.modules.selfadb.MEDIA_FAKE_STOP
sleep 1
"${ADB[@]}" logcat -c
bc expo.modules.selfadb.MEDIA_FAKE
echo "== a session was activated; its title and PLAYING state arrive in ${DELAY_MS} ms; watching 12 s"
sleep 12
LOG="$("${ADB[@]}" logcat -d -s LinkToMac:I | grep "media: session")"
echo "$LOG" | cut -c19-100
bc expo.modules.selfadb.MEDIA_FAKE_STOP
if echo "$LOG" | grep -q "session followed"; then
  echo "PASS a session is followed once its title appears"
  echo "$LOG" | grep -qE "followed of [2-9]" && echo "     (other media sessions are open: close them to be sure it was ours)"
  exit 0
else
  echo "FAIL no session was followed: the card on the Mac would stay empty"
  echo "$LOG" | grep -qE "none of [2-9]" && echo "     (other media sessions are open: close them to be sure)"
  exit 1
fi
