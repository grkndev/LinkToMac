# Changelog

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
