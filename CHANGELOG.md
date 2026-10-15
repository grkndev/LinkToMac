# Changelog

## v0.11.0 (2026-10-15)

Full notes: [`release-notes/v0.11.0.md`](release-notes/v0.11.0.md). Update **both** apps (Android 0.10.0 → 0.11.0, Mac 0.10.0 → 0.11.0).

### Features
- **Files screen on the phone** — Home's "Received files" placeholder is now **Files**: *Send files*, *Send folder* (system pickers), an in-progress row (tap to cancel), and a persisted history of everything sent and received (tap to open, **Retry** a failed or cancelled send, Clear).
- **Files up to 1 GB** (was 64 MB). The Mac now streams received chunks to disk instead of holding them in memory; the phone sends a large share-sheet file straight from its content URI instead of copying it into its cache.
- **Resume** — send the same file again after a cut-off (cancel, dropped link) and only the missing part goes. Acks carry `have`, transfer ids are deterministic, a receiver keeps a half-received file for 10 min.
- **Folders from the phone** — the Mac now receives folders and recreates the tree; folder paths are sanitised by twin functions pinned by shared vectors.
- **Cancel from the notification** — the outgoing progress notification has a Cancel button.
- **"Grant SMS Send Access" explains itself** — on a sideloaded APK Android blocks SMS access as a restricted setting and then refuses to prompt; the button used to do nothing. It now shows the steps and opens App info.
- **One banner for a burst of files** on the Mac ("3 files"), as on the phone.

### Changes
- "Send copies" and "Send images" were removed from the phone's Settings (the phone always sends; the Mac keeps its own switches).
- The dev (`.dev`) and release builds installed side by side no longer mirror each other's notifications.

### Internal
- `protocol-vectors/` — shared vectors (`file-frame.json`, `dir-sanitize.json`) run by both the Swift and the Kotlin suite; first JVM unit tests for the Android module.
- `AckWindow` replaced a `DispatchSemaphore`; `FileInbox` is disk-backed on both sides; `SendItem` / `FolderWalker` / `FileHistory` / `PickActivity` on Android.
- `npx expo lint` is clean again.

### Known limitations
- Finder ▸ Share ▸ "Send to Phone" still can't run (ad-hoc signing); drags from Mail / Photos aren't supported; resume needs the *receiving* app to still hold the partial; Retry exists only for sends started inside the app.

### Updating
- **macOS** auto-updates via Sparkle. **Android** needs the new APK — native code changed, so this is not an EAS Update.

## v0.10.0 (2026-10-15)

Full notes: [`release-notes/v0.10.0.md`](release-notes/v0.10.0.md).

### Fixes
- **The Mac no longer crashes when you drop a file** — especially a second file, or several at once. A Mac→phone file under ~640 KB never got a receipt (Swift omitted `id` on one-chunk files), so the Mac waited 30 s, reported a false failure, and a transfer ending short of its acks crashed the next one (a `DispatchSemaphore` deallocated below its initial value). Both halves are fixed.
- "Sent" now means **saved**: the last chunk is acked only after the file is written, and a file that can't be saved is nacked so the sender reports it at once.
- A transfer now moves onto whichever link is up per chunk, or ends immediately if there is none; a vanished sender no longer leaves the Mac's "receiving" row up forever; big received files are written off the main thread.

### Features
- **Several files and whole folders** from the Mac in one drop: one progress bar (`name.ext (50%)`, `3 / 5`, Cancel), one summary notification. Folders keep their structure on the phone.
- **Multi-select share** on the phone ("Send as a File"), under one progress notification; received files in a burst collapse into one notification.

### Known limitations
- Dragging from Mail / Photos / Safari isn't supported; 64 MB per file; Finder Share still can't run.

### Updating
- **macOS** auto-updates. **Android** needs the new APK (native code changed).

## v0.9.0 (2026-09-15)

Full notes: [`release-notes/v0.9.0.md`](release-notes/v0.9.0.md).

### Features
- **Send files, both ways.** From the phone's share sheet: **Send to Clipboard** (images, downscaled, ready to paste) and **Send as a File** (any type, original quality), also in the sheet's top row (Direct Share). From the Mac: drop a file on the dashboard window or the menu-bar icon (a hand-built `NSStatusItem` that is a drag destination). Files land in `Downloads/Link to Mac` on the phone and in the folder chosen under Settings ▸ Files on the Mac.
- Chunked (640 KiB) and **acknowledged** (4 in flight; paced on the relay), so "sent" is a delivery receipt and the 1 MiB frame cap isn't a size limit; progress notifications / drop-zone percentage on both ends.
- The Mac's name reaches the phone so the share entries can say which Mac they mean.

### Fixes
- A full-resolution photo no longer risks taking the phone's background service down (bounded decode); fewer images rejected as too large.

### Known limitations
- Finder ▸ Share ▸ "Send to Phone" can't run (macOS refuses an ad-hoc signed app extension); 64 MB per file.

## v0.8.5 (2026-09-13)

Android 0.8.4 → 0.8.5, Mac 0.8.3 → 0.8.5 (the reply feature needs both).

### Features
- **The Android app no longer depends on ADB.** ADB buys exactly one thing — *automatic* clipboard capture; the link, lock, battery, notification/SMS mirroring and Mac→phone clipboard never needed it, but a full-screen gate used to hold the app hostage to it (a dead end on Mobile Hotspot, or after a Samsung reboot dropped adbd's key trust). ADB is now a capability, reported only in Settings ▸ Automatic capture.
- **Send a copy without ADB** — a **Link to Mac** entry in the text-selection toolbar, and a **Send clipboard** action on the ongoing notification.
- **Reply to messages from the Mac** (1:1 threads) — the phone sends a real SMS via `SmsManager` (needs `SEND_SMS`, requested lazily) and acks back.

### Fixes
- Mac→phone clipboard no longer needs the daemon (it writes the clipboard directly when the daemon is down); the Logs screen no longer drowns in "can't reach the daemon" lines.

## v0.8.4 (2026-07-23)

Android only.

### Security
- **Confused-deputy fix (#32).** The shell-UID clipboard daemon read image URIs with shell's elevated privilege; a hostile app could forge an `image/*` clip pointing at content it couldn't read and have it synced to the Mac. The daemon now resolves who set the clip and reads the image only if that app could read it (explicit grant / static permission, owns the provider, or holds `READ_MEDIA_*` for MediaStore); it fails closed.

## v0.8.3 (2026-07-22)

### Fixes (Android; issues #29, #30, #31)
- **The clipboard daemon self-heals from an OS memory kill (#31)** — it is wrapped in a shell-UID supervisor loop that respawns it in ~3 s with the same port and secret (no ADB, no Wi-Fi).
- **"Try again" no longer hangs forever (#30)** — `adb.connect()`'s handshake is now bounded and the button shows a spinner.
- **Mobile Hotspot no longer locks you out (#29)** — the daemon gets a grace window to reattach on a cold launch, and the full-screen gate became a banner.

### Fixes (Mac; issue #23)
- The first mirrored notification no longer races the permission prompt; a denied permission shows an "Open Notification Settings…" row; opening the dashboard at login no longer steals focus.

## v0.8.1 (2026-07-17)

Hotfix over **0.8.0, which was retracted** (fresh installs got stuck on the Reconnect screen: `IOException: Stream Closed` — libadb ties a connection to its creating thread, and a throwaway worker thread broke it). Reverted to the synchronous connect.

### Changes (carried from 0.8.0)
- **Update both apps together:** the legacy v1 encryption fallback is gone; a 0.8.x phone and a pre-0.8 Mac fail closed.
- Reliability and hardening: Mac remote-lock fallback, queued early copies, build-stamped dex version in the daemon log, fixed-length token comparison, room-id / `nonce` / `ct` validation, replay-cache cap, relay crash handlers, truncated-dex detection.

## v0.7.0 (2026-07-07)

### Features
- **Bidirectional clipboard image sync** — copy an image on either device and it lands on the other's clipboard (E2E-encrypted, auto-fit under the 1 MiB frame cap).
- A **Daemon Log** screen with a Restart-daemon action; a "Send images" switch (removed again in 0.11.0).

### Fixes
- Clipboard history records every image; larger WebSocket frames are no longer dropped.

## v0.6.1 (2026-07-06)

Android only; the Mac stays on 0.6.0.

### Fixes
- **The clipboard daemon self-heals when two installs fight over it** (flap detection, back-off, redeploy under our own key) and each app variant runs its daemon on its own port, so a dev and a release install can coexist.
- "Device Log" works again on One UI (`BufferOverflowException` on a grown log).

### Internal
- The app's JavaScript was split into modular features and shared M3 components (no visual change).

## v0.6.0 (2026-07-02)

A reliability, security and correctness pass across phone, Mac and relay.

### Security
- **Authenticated clipboard bridge** — the on-device bridge to the privileged daemon requires a per-install secret, so no other app can read or inject the clipboard over loopback.
- **Replay protection and type binding** — every frame is bound to its type (AAD) and timestamped (±2 min window + nonce cache): the v2 envelope.
- Pairing keys and the relay token are device-only in the Keychain; the LAN peer slot is auth-gated.

### Fixes
- The Mac no longer shows "linked" after a silently dead connection; the phone no longer shows the Mac online during reconnection; the bridge recovers from half-open connections; LAN discovery and handshakes time out and self-heal.
- SMS threads open at the newest message; drafts/failed/queued texts no longer show as sent; "Check for updates" honestly reports a failure; a corrupt pairing QR is rejected.
- **Minimum Android version is now 11.**

## v0.5.1 (2026-06-28)

### Features
- **Read your phone's messages on the Mac** — your Android SMS now show up on the Mac's
  dashboard **Messages** tab as real **conversation threads** (one row per contact, latest
  message previewed; tap to open the thread and read the back-and-forth in chat bubbles). Grant
  **"SMS access"** once on the phone (Settings → *Grant SMS access*) and keep the **"Mirror
  messages"** toggle on. It's **read-only** and one-way (the Mac can't reply yet), resolves
  contact names, and can be paused phone-side without revoking the system grant. Cleared on unpair.
- **Paged Messages & Notifications lists** — both dashboard tabs now page through their history
  (7 per page, with a ‹ / › control) so a long backlog no longer overflows the window; long
  threads scroll.

### Internal
- New `sms` wire frame (phone → Mac), E2E-encrypted (ChaCha20-Poly1305) and forwarded opaquely by
  the relay exactly like `clip`/`cmd`/`stat`/`note`, over both LAN-direct and relay transports —
  hand-mirrored across `server/` (`protocol.ts`/`relay.ts`/`index.ts`), `mac/`
  (`RelayProtocol.swift`), and `mobile/` (`RelayClient.kt`/`LanClient.kt`). `smoke.ts` asserts a
  one-way `sms` round-trip.
- Android: an FGS-owned `SmsMirror` reads `content://sms` (newest ~200, chunked) and observes it
  for live deltas, resolving sender names via `PhoneLookup`; gated by the `READ_SMS`/`READ_CONTACTS`
  runtime grants + a "Mirror messages" toggle. New JS surface: `hasSmsAccess`, `requestSmsAccess`,
  `get/setSmsForwarding`, `syncSms`.
- Mac: `RelayClient` upserts inbound messages by `id` and groups them into `conversations`
  (by thread, newest-activity first); `FeaturePanel`'s Messages tab renders the thread list +
  chat-bubble view, both paged.

### Known limitations
- The Mac's message list is **in-memory** (like Notifications): it clears when the Mac app
  relaunches, and the phone re-sends the history when it next sees the Mac connect.

### Updating
- **macOS** auto-updates via Sparkle. **Android** needs the new APK reinstalled — this release
  changes native code, so it is **not** an over-the-air (EAS Update) change.

## v0.5.0 (2026-06-27)

### Features
- **Live distance to your phone, on both dashboards** — the Mac measures the phone's BLE signal
  and now shows the proximity/distance ("Nearby", "Away", with the live dBm) right in the
  dashboard's identity row, *and* forwards that reading to the phone so the phone's Home screen
  shows the same distance (it only advertises the beacon, so it can't measure it itself). Shown
  only while auto-lock is on (that's what runs the scan).

### Internal
- The Mac's outbound `stat` frame now merges battery **and** BLE proximity (`prox`/`rssi`,
  throttled), and each side updates only the fields present — so battery and proximity frames
  never clobber each other.
- Updated app icon.

### Updating
- **macOS** auto-updates via Sparkle. **Android** needs the new APK reinstalled (native code changed).

## v0.4.0 (2026-06-25)

### Features
- **Notification mirroring (phone → Mac)** — when your Android phone gets a notification, it
  now shows up on the Mac: as a native banner *and* in the dashboard's **Notifications** tab,
  each row badged with the source app's icon. Grant **"Notification access"** once on the phone
  and flip the **"Mirror notifications"** toggle. It's one-way (Mac never sends back), can be
  paused phone-side without revoking the system grant, and is cleared on unpair. Noise (the
  app's own foreground-service note, ongoing/group-summary notifications, title-and-text-empty
  ones) is filtered out.

### Internal
- New `note` wire frame (phone → Mac), E2E-encrypted (ChaCha20-Poly1305) and forwarded opaquely
  by the relay exactly like `clip`/`cmd`/`stat`, over both LAN-direct and relay transports —
  hand-mirrored across `server/` (`protocol.ts`/`relay.ts`/`index.ts`), `mac/`
  (`RelayProtocol.swift`), and `mobile/` (`RelayClient.kt`/`LanClient.kt`). `smoke.ts` asserts a
  one-way `note` round-trip.
- Android: a `NotificationListenerService` (`NotificationListener.kt`) runs in the app process
  (survives a JS swipe like the FGS), resolves each app's label + launcher icon (~72 px PNG,
  base64, memoized per package), and forwards via `ClipForegroundService.sendNote`. New JS
  surface: `hasNotificationAccess`, `openNotificationAccessSettings`,
  `get/setNotificationForwarding`.
- Mac: `RelayClient` upserts inbound notes into a deduped (by `sbn.key`), newest-first ring with
  a per-package icon cache; `MacNotifier` raises the banner (the source icon rides as a
  best-effort `UNNotificationAttachment` with a text-only fallback, so an icon problem never
  suppresses the banner).

### Updating
- **macOS** auto-updates via Sparkle. **Android** needs the new APK reinstalled — this release
  changes native code, so it is **not** an over-the-air (EAS Update) change.

## v0.3.0 (2026-06-24)

### Features
- **Mac app redesign + dashboard window** — the menu-bar dropdown is now a compact **Material 3
  phone-identity card** (phone render + name + live status dot + tonal transport/battery chips),
  and a full **dashboard window** (PhonePanel, clip history, feature tabs) opens from it. The
  Mac no longer shows *its own* battery to itself (you're already on the Mac).
- **Phone battery + name on the Mac** — the phone now reports *its* battery level, charging
  state, and device name to the Mac (over the same end-to-end-encrypted link), so the dashboard
  shows your phone's real identity and charge. Battery telemetry is now **bidirectional** (Mac's
  battery → phone, phone's battery → Mac).
- **Clip history on the Mac** — the dashboard keeps an in-memory history of synced clips, grouped
  by recency (Today / Earlier) with relative times; tap to re-copy, or clear it. Cleared on
  unpair.

### Internal
- The `stat` telemetry frame is now bidirectional: both ends send `{level, charging}` (their own
  battery) and the phone additionally includes `name`; each side ignores fields it doesn't use.
  Decoded on the LAN-direct path too (`LanServer.onRemoteStat`).
- The dashboard's previously-placeholder telemetry is wired to live data; the right-panel media
  player and Lock/Cast tiles stay placeholder (roadmap).

### Updating
- **macOS** auto-updates via Sparkle. **Android** needs the new APK reinstalled (native code
  changed).

## v0.2.1 (2026-06-22)

Android-only maintenance release.

### Features
- **In-app update flow** — a dedicated *"App is updating"* dialog with a native (Jetpack Compose)
  progress bar and a **"Continue in background"** button, replacing the old freeze-then-restart
  button. The About screen now shows the build number (versionCode).

### Fixes
- **Self-ADB reconnect loop fixed** — a dead daemon no longer loops the pairing/reconnect screen
  (issue #5: `connect()==false` is a live-session signal, not a failure).
- Localized the Reconnect screen and fixed an Auto-lock toggle race.
- Cut idle background battery use (WS ping 20→50 s, LAN ping, Wi-Fi-gated mDNS).
- Date-based `versionCode` (`YYMMDDNNN`).

## v0.2.0 (2026-06-20)

### Features
- **Mac battery on the phone** — the phone's Home screen now shows the Mac's battery
  percentage and charging state as a chip next to the connection status, synced live over the
  same end-to-end-encrypted link as the clipboard (LAN-direct or relay). A charging Mac is
  tinted differently; desktop Macs (no internal battery) show nothing.

### Internal
- New `stat` telemetry message (Mac → phone), E2E-encrypted (ChaCha20-Poly1305) and forwarded
  opaquely by the relay exactly like `clip`/`cmd`, over both the LAN-direct and relay transports.
- The Mac now treats a per-frame `bad-message` relay error as non-fatal (logged, not surfaced
  as a connection error).

### Updating
- **macOS** auto-updates via Sparkle. **Android** needs the new APK reinstalled — this release
  changes native code, so it is **not** an over-the-air (EAS Update) change.

## v0.1.0 — Beta (2026-06-18)

First public **beta**. Links one Android phone and one Mac. Personal-use project — not
intended for the Play Store / App Store.

### Features
- **Two-way clipboard sync**, end-to-end encrypted (ChaCha20-Poly1305).
- **Remote "Lock Mac"** from the phone — now also end-to-end encrypted (opaque to the relay).
- **Proximity auto-lock** via a BLE presence beacon (fully local, no network).
- **LAN-direct mode** (relay-less): on the same Wi-Fi the phone connects straight to the Mac
  (the Mac runs a WebSocket server), discovered over Bonjour/mDNS and gated by an HMAC
  challenge-response over the pairing key. It is auto-preferred over the relay, falls back to
  the relay when you're away, and switches back on return. Works with no relay configured at all.
- **Self-hosted relay** for away-from-home sync (optional).
- Pair once with a QR code (v3: carries the relay + LAN config so the phone self-configures).

### Notes / known limitations
- Distributed for **sideload**: the Android APK is debug-signed; the macOS app (`.dmg`) is
  ad-hoc signed and **not notarized** — first launch on another Mac needs right-click → Open
  (or clear the quarantine attribute). Not for the app stores.
- LAN transport is plain `ws://` (no TLS on the LAN); payloads stay E2E-encrypted regardless.
- When off the LAN, the direct client keeps retrying the last known address in the background.
