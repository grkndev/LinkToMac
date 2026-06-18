# Link to macOS

Connect your Android phone to your Mac. **Sync your clipboard both ways, lock your Mac
from your phone, and let it lock itself when you walk away** — directly over your Wi-Fi, or
through a relay you host yourself when you're away. In the spirit of Microsoft's "Link to
Windows", but self-hosted.

> Personal-use project. Not intended for the Play Store / App Store.

## Features

- 📋 **Two-way clipboard** — copy on the phone, paste on the Mac, and vice versa.
- 🔒 **Lock from your phone** — one tap on the Home screen locks your Mac.
- 🚶 **Auto-lock when you leave** — the Mac locks itself once your phone is out of
  Bluetooth range. (Locking only — macOS has no way to auto-*unlock*.)
- 🔗 **Pair once** with a QR code shown on the Mac.
- 📶 **No relay on the same Wi-Fi** — the phone connects straight to the Mac (LAN-direct), and
  falls back to the relay automatically when you leave home. Works relay-free if you never set one up.
- 🏠 **Self-hosted** — the relay runs on your own server; nothing goes through a third party.

## How it works

```
  Android phone                 your relay              Mac
  ┌────────────────┐           ┌───────────┐        ┌───────────────┐
  │ background app  │  ◄─────►  │  tiny WS   │  ◄───► │  menubar app   │
  │  clipboard ·    │           │  server    │        │  clipboard ·   │
  │  lock command   │           │ (room id)  │        │  lock · QR     │
  └───────┬─────────┘           └───────────┘        └──────┬────────┘
          │                                                   │
          └───────────  Bluetooth presence beacon  ───────────┘
                      (proximity auto-lock — fully local)
```

A small **menu bar app** on the Mac and a **background app** on Android stay connected. On the
**same Wi-Fi** the phone connects **straight to the Mac** (the Mac runs a small local server it
finds automatically) — no relay needed. When you're away, it falls back to a tiny **relay server
you host**, routed only by a shared room id. Either way, clipboard text and the "Lock Mac"
command are end-to-end encrypted. **Proximity auto-lock** uses neither: the phone broadcasts a
Bluetooth presence beacon and the Mac locks itself when that signal fades — so it works even with
no internet.

> **The Android trick:** regular apps can't read the clipboard in the background, so the app
> connects to the phone's *own* ADB over Wireless Debugging and runs a tiny helper with the
> permissions to do clipboard I/O. It keeps working after the app is swiped away.

## Components

| Directory | What it is |
|---|---|
| [`mobile/`](mobile/) | Expo (SDK 56) React Native app — pairing, settings, and the background service that does clipboard sync + the Bluetooth beacon. |
| [`mac/`](mac/) | Swift menu bar app — clipboard sync, remote lock, proximity auto-lock, pairing QR, login-item auto-start. |
| [`server/`](server/) | Minimal Node.js WebSocket relay (room routing, auth token, rate limiting). Docker-ready. See [`server/README.md`](server/README.md). |
| [`docs/`](docs/) | Design documents and implementation plans. |

## Getting started

1. **Relay (optional)** — only needed to sync while you're *away* from your Wi-Fi. On the same
   network the app works relay-free. To run one: `cd server && npm install && npm run dev` (or
   `docker compose up -d`). See [`server/README.md`](server/README.md) for env vars and
   reverse-proxy (wss) setup.
2. **Mac app** — open `mac/LinkToMac.xcodeproj` (generated from `project.yml` via XcodeGen)
   and run. **LAN-direct is on by default** (Server Settings… → *LAN-direct*); add a relay's
   address/port/TLS/password there only if you want away-from-home sync. Then show the
   **pairing QR**.
3. **Android app** — `cd mobile && bun install`, then build a dev client
   (`npx expo run:android`). Expo Go isn't supported (custom native module). Turn on
   **Wireless Debugging** and pair once by scanning the Mac's QR — it carries the LAN port (and
   relay address/password, if set), so the phone configures itself and prefers the direct LAN
   link automatically (editable later under **Settings → Relay server**).

## Using the features

- **Clipboard** — just copy on either device; the other one follows. You can pause sending
  from the phone in Settings while still receiving the Mac's copies.
- **Lock Mac** — tap **Lock Mac** on the phone's Home screen (needs the Mac connected).
- **Auto-lock when you leave** — turn it on in **both** apps: the phone's Settings
  (*Auto-lock Mac when I leave*) and the Mac menu (*Lock when phone leaves*). On the Mac you
  can tune **Sensitivity** (Near / Balanced / Far) and **Lock after** (10–60s), and watch the
  live signal to calibrate for your space.

## Security & privacy

- **Pair once:** the Mac generates a random room id + key and shows them as a QR — along with
  the relay address, port, TLS setting, and password — so the phone configures itself in one
  scan. Secrets are stored in the Keychain (macOS) and Keystore-backed storage (Android).
- **You own the relay:** it routes messages by room id and never stores clipboard content.
  The endpoint, password, and TLS are configured at runtime (nothing is baked into the build);
  run it over **TLS (`wss`)** behind a reverse proxy on infrastructure you trust.
- **LAN-direct is safe without TLS:** on the local network the link is plain `ws://`, but the
  payloads are still end-to-end encrypted and the connection is gated by a challenge-response over
  your pairing key — a stranger on the Wi-Fi can neither read it nor impersonate your phone.
- **Proximity lock is local:** it uses Bluetooth only and never touches the relay or internet.
- **End-to-end encrypted:** both clipboard *and* the lock command are sealed with
  **ChaCha20-Poly1305**, keyed by the secret exchanged at pairing. The relay (or anyone on your
  LAN) only ever sees opaque ciphertext — never your clipboard, the command, or the key.

## Scope & status

v1 links **one phone and one Mac** and syncs **text only** (images/files are out of scope).
Clipboard sync (end-to-end encrypted), remote lock, and proximity auto-lock are implemented;
some lifecycle hardening is still on the roadmap. A separate technical document
([`TECHNICAL.md`](TECHNICAL.md)) covers the internals in depth.

## License

Personal project — see [`mobile/LICENSE`](mobile/LICENSE).
