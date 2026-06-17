# Link to macOS

Connect your Android phone to your Mac. **Sync your clipboard both ways, lock your Mac
from your phone, and let it lock itself when you walk away** — all through a relay you host
yourself. In the spirit of Microsoft's "Link to Windows", but self-hosted.

> Personal-use project. Not intended for the Play Store / App Store.

## Features

- 📋 **Two-way clipboard** — copy on the phone, paste on the Mac, and vice versa.
- 🔒 **Lock from your phone** — one tap on the Home screen locks your Mac.
- 🚶 **Auto-lock when you leave** — the Mac locks itself once your phone is out of
  Bluetooth range. (Locking only — macOS has no way to auto-*unlock*.)
- 🔗 **Pair once** with a QR code shown on the Mac.
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

A small **menu bar app** on the Mac and a **background app** on Android stay connected
through a tiny **relay server you host**. Clipboard changes and the "Lock Mac" command
travel through the relay, routed only by a shared room id. **Proximity auto-lock** doesn't
use the relay at all: the phone broadcasts a Bluetooth presence beacon and the Mac locks
itself when that signal fades — so it works even with no internet.

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

1. **Relay** — `cd server && npm install && npm run dev` (or `docker compose up -d`). See
   [`server/README.md`](server/README.md) for env vars and reverse-proxy (wss) setup.
2. **Mac app** — open `mac/LinkToMac.xcodeproj` (generated from `project.yml` via XcodeGen)
   and run. Use the menu bar item to show the pairing QR.
3. **Android app** — `cd mobile && bun install`, then build a dev client
   (`npx expo run:android`). Expo Go isn't supported (custom native module). Turn on
   **Wireless Debugging** and pair once by scanning the Mac's QR.

## Using the features

- **Clipboard** — just copy on either device; the other one follows. You can pause sending
  from the phone in Settings while still receiving the Mac's copies.
- **Lock Mac** — tap **Lock Mac** on the phone's Home screen (needs the Mac connected).
- **Auto-lock when you leave** — turn it on in **both** apps: the phone's Settings
  (*Auto-lock Mac when I leave*) and the Mac menu (*Lock when phone leaves*). On the Mac you
  can tune **Sensitivity** (Near / Balanced / Far) and **Lock after** (10–60s), and watch the
  live signal to calibrate for your space.

## Security & privacy

- **Pair once:** the Mac generates a random room id + key and shows them as a QR; the phone
  scans it once. Secrets are stored in the Keychain (macOS) and Keystore-backed storage
  (Android).
- **You own the relay:** it routes messages by room id and never stores clipboard content.
  Run it over TLS (`wss`) on infrastructure you trust.
- **Proximity lock is local:** it uses Bluetooth only and never touches the relay or internet.
- **End-to-end encrypted:** clipboard payloads are sealed with **ChaCha20-Poly1305**, keyed by
  the secret exchanged at pairing. The relay only ever sees opaque ciphertext — never your
  clipboard or the key.

## Scope & status

v1 links **one phone and one Mac** and syncs **text only** (images/files are out of scope).
Clipboard sync (end-to-end encrypted), remote lock, and proximity auto-lock are implemented;
some lifecycle hardening is still on the roadmap. A separate technical document
([`TECHNICAL.md`](TECHNICAL.md)) covers the internals in depth.

## License

Personal project — see [`mobile/LICENSE`](mobile/LICENSE).
