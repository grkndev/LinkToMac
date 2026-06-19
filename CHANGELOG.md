# Changelog

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
