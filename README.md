# Link to macOS

Bidirectional **clipboard synchronization between Android and macOS** — in the spirit of
Microsoft's "Link to Windows", but self-hosted and end-to-end encrypted. Copy on the
phone, paste on the Mac, and vice versa.

> Personal-use project. Not intended for the Play Store / App Store.

## How it works

```
ANDROID (phone)                            CLOUD               macOS
┌──────────────────────────────┐                      ┌─────────────────────┐
│ RN App (Expo, DevClient)     │                      │ Swift menubar app   │
│  ┌────────────────────────┐  │                      │  NSPasteboard watch │
│  │ Foreground Service     │  │   ┌────────────┐     │  /write (changeCount│
│  │  • WS client ──────────┼──┼──►│ Node ws    │◄────┼─  poll)             │
│  │  • self-ADB (libadb)   │  │   │ relay      │     │  WS client          │
│  │  • watchdog            │  │   │ room route │     │  secretbox E2E      │
│  │  • secretbox E2E       │  │   └────────────┘     │  login item         │
│  └─────────┬──────────────┘  │    only carries      └─────────────────────┘
│   connect  │ 127.0.0.1:PORT  │    encrypted bytes
│  ┌─────────▼──────────────┐  │
│  │ Clipboard agent (JAR)  │  │
│  │  shell UID · clipboard │  │
│  │  I/O · localhost socket│  │
│  └────────────────────────┘  │
└──────────────────────────────┘
```

A clipboard change on either end is captured, sealed into an
`{ origin, seq, text }` envelope encrypted with **libsodium secretbox**, and pushed
through a tiny WebSocket relay to the other device, which decrypts it and writes it to
its own clipboard. The relay is a "dumb pipe": it routes by `roomId` only and never
sees plaintext or metadata.

### The Android trick: self-ADB

Regular Android apps cannot read the clipboard in the background. This project works
around that by having the app connect to the phone's **own ADB daemon** over Wireless
Debugging (the LADB pattern, via `libadb-android` with TLS + SPAKE2 pairing) and launch
a small dex'd JAR with `app_process` under the **shell UID**, which *can* do clipboard
I/O. The JAR runs as a detached daemon, listens for clipboard changes, and talks to the
app over a localhost socket (NDJSON) — so it survives ADB disconnects and app restarts.

## Components

| Directory | What it is |
|---|---|
| [`mobile/`](mobile/) | Expo (SDK 56, DevClient) React Native app. UI/pairing in JS; the hot data path lives in a native Kotlin foreground service (`modules/selfadb/`). The shell-UID clipboard agent JAR sources are in `native-src/clipboard-agent/`. |
| [`mac/`](mac/) | Swift menu bar app (`MenuBarExtra`). Polls `NSPasteboard.changeCount`, writes incoming clips, generates the pairing QR, stores secrets in Keychain, auto-starts as a login item. |
| [`server/`](server/) | Minimal Node.js WebSocket relay. Room-based routing, max 2 peers per room, auth token, rate limiting, 256 KB payload cap. Docker + reverse-proxy (wss) ready. See [`server/README.md`](server/README.md). |
| [`docs/`](docs/) | Design documents and implementation plans. |
| [`workflow.md`](workflow.md) | Full architecture & decision log (in Turkish) — the source of truth for design decisions. |

## Pairing & security

- **Pairing:** the Mac generates a random 256-bit `roomId` and a separate 256-bit
  encryption key, and shows them as a QR code. The phone scans it once; both sides
  persist the secrets (Keychain on macOS, Keystore-backed secure storage on Android).
- **End-to-end encryption:** every clip is sealed with libsodium secretbox
  (XSalsa20-Poly1305, random 24-byte nonce). `origin`, `seq`, and the text itself are
  all inside the ciphertext — the relay sees only the `roomId`, ciphertext size, and
  timing.
- **Echo/loop prevention:** each end tags messages with `{ origin, seq }` (a version
  vector) and drops its own echoes and stale sequence numbers. The Mac additionally
  suppresses the `changeCount` bump caused by its own remote writes.
- **Relay hardening:** bearer `roomId` + a server-wide auth token, per-room connection
  cap, rate limiting, payload cap, heartbeat with dead-connection cleanup. TLS (`wss`)
  is terminated by your reverse proxy (e.g. Caddy).
- Clipboard content is never persistently logged; the UI shows only short previews.

## Getting started

Each component has its own setup:

1. **Relay** — `cd server && npm install && npm run dev` (or `docker compose up -d`).
   Details, env vars, and reverse-proxy config: [`server/README.md`](server/README.md).
2. **Mac app** — open `mac/LinkToMac.xcodeproj` (generated from `mac/project.yml` via
   XcodeGen) and run. Use the menu bar item to show the pairing QR.
3. **Android app** — `cd mobile && bun install`, then build a DevClient
   (`npx expo run:android`). Expo Go is not supported (custom native module). Enable
   **Wireless Debugging** on the phone and pair once from the app.

## Scope & status

v1 syncs **text only** between **one phone and one Mac**; images, files, and rich
content are out of scope. The relay, Mac agent, mobile UI, and the self-ADB +
clipboard-agent pipeline are implemented; lifecycle hardening (reboot re-arm UX,
watchdog edge cases) is ongoing. See `workflow.md` for the roadmap and open questions.

## License

Personal project — see [`mobile/LICENSE`](mobile/LICENSE).
