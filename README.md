<div align="center">
<img src="/mobile/assets/images/icon.png" 
width="120" height="120">

# Link to Mac

**Your Android phone and your Mac, working as one.**

Two-way clipboard (text _and_ images), lock your Mac from your phone, auto-lock when you
walk away, mirrored notifications and messages, and live battery both ways — over your own
Wi-Fi, or through a relay you host yourself when you're away.

In the spirit of Microsoft's _Link to Windows_, but **self-hosted** and yours end to end.

<sub>Personal-use project. Not intended for the Play Store / App Store.</sub>

</div>

---

## Why

Your phone and your laptop should feel like one machine — copy here, paste there; walk away,
it locks; a text arrives, you read it without reaching for your phone. The commercial versions
of this route your clipboard and messages through someone else's cloud. **Link to Mac does the
same job, but nothing leaves hardware you control.** On the same Wi-Fi it's a direct
phone↔Mac link; away from home it falls back to a tiny relay _you_ run. Either way the payloads
are end-to-end encrypted — the relay only ever sees opaque ciphertext.

## Features

| | Feature | |
|---|---|---|
| 📋 | **Two-way clipboard** | Copy text or an image on either device, and it lands on the other. |
| 🔒 | **Lock from your phone** | One tap on the Home screen locks your Mac. |
| 🚶 | **Auto-lock when you leave** | The Mac locks itself once your phone leaves Bluetooth range. _(Lock-only — macOS can't auto-unlock.)_ |
| 🔋 | **Battery both ways** | Your Mac's charge shows on the phone; your phone's battery + name show on the Mac. Live. |
| 🔔 | **Notification mirroring** | Android notifications pop as native banners on the Mac and collect in a tab. _(One-way, pausable.)_ |
| 💬 | **Read your messages** | Your SMS appear as conversation threads on the Mac. _(Read-only for now, pausable.)_ |
| 🖥️ | **Mac dashboard** | A Material 3 menu-bar card + window: your phone, clip history, notifications, messages. |
| 📶 | **LAN-direct, relay optional** | Same Wi-Fi → straight to the Mac. Leave home → seamless relay fallback. Works relay-free if you never set one up. |
| 🔗 | **Pair once** | Scan one QR shown on the Mac. It carries everything the phone needs. |
| 🏠 | **Self-hosted** | The relay runs on your server. Nothing routes through a third party. |

## How it works

```
  Android phone                 your relay              Mac
  ┌─────────────────┐           ┌────────────┐        ┌───────────────┐
  │ background app  │  ◄─────►  │  tiny WS   │  ◄───► │ menubar app + │
  │  clipboard ·    │           │  server    │        │  dashboard    │
  │  lock · battery │           │  (room id) │        │  clipboard ·  │
  │  notifs · SMS   │           │            │        │  lock · QR    │
  └───────┬─────────┘           └────────────┘        └───────┬───────┘
          │                                                   │
          └───────────  Bluetooth presence beacon  ───────────┘
                      (proximity auto-lock — fully local)
```

A small **menu-bar app** on the Mac and a **background app** on Android stay connected.

- **On the same Wi-Fi** the phone connects **straight to the Mac** (which runs a tiny local
  server the phone discovers automatically) — no relay in the loop.
- **Away from home**, it falls back to a small **relay you host**, routed only by a shared room id.
- Either way, clipboard content and the "Lock Mac" command are **end-to-end encrypted**
  (ChaCha20-Poly1305, keyed by the secret you exchange at pairing).
- **Proximity auto-lock** uses neither path: the phone broadcasts a Bluetooth presence beacon and
  the Mac locks itself when the signal fades — so it works even with no internet.

> **The Android trick:** ordinary apps can't read the clipboard in the background, so the app
> connects to the phone's _own_ ADB over Wireless Debugging and runs a tiny privileged helper
> with clipboard I/O permissions. It keeps working after you swipe the app away.

## Components

| Directory | What it is |
|---|---|
| [`mobile/`](mobile/) | Expo (SDK 56) React Native app — pairing, settings, and the background service doing clipboard sync + the Bluetooth beacon. |
| [`mac/`](mac/) | Swift menu-bar app + dashboard — clipboard sync, remote lock, proximity auto-lock, pairing QR, login-item auto-start. |
| [`server/`](server/) | Minimal Node.js WebSocket relay (room routing, auth token, rate limiting). Docker-ready. See [`server/README.md`](server/README.md). |
| [`docs/`](docs/) | Design documents and implementation plans. |

## Getting started

1. **Relay _(optional)_** — only needed to sync while you're _away_ from your Wi-Fi. On the same
   network the app works relay-free. To run one: `cd server && npm install && npm run dev` (or
   `docker compose up -d`). See [`server/README.md`](server/README.md) for env vars and
   reverse-proxy (`wss`) setup.
2. **Mac app** — open `mac/LinkToMac.xcodeproj` (generated from `project.yml` via XcodeGen) and
   run. **LAN-direct is on by default** (Server Settings… → _LAN-direct_); add a relay's
   address / port / TLS / password there only if you want away-from-home sync. Then show the
   **pairing QR**.
3. **Android app** — `cd mobile && bun install`, then build a dev client (`npx expo run:android`).
   Expo Go isn't supported (custom native module). Turn on **Wireless Debugging** and pair once by
   scanning the Mac's QR — it carries the LAN port (and relay address / password, if set), so the
   phone configures itself and prefers the direct LAN link automatically. Editable later under
   **Settings → Relay server**.

### Building a release (beta)

- **macOS** — `cd mac && ./scripts/build-release.sh` → `build/release/LinkToMac-<version>.dmg`
  (universal, ad-hoc signed). The app is **not notarized** (no Apple Developer team), so on a
  _different_ Mac the first launch must be **right-click → Open** once — or run
  `xattr -dr com.apple.quarantine /Applications/LinkToMac.app` after dragging it in.
- **Android** — `cd mobile && eas login && eas build --platform android --profile preview --local`
  → an installable **APK** (sideload). This `preview` profile **is** the public-release build: it
  bakes in the `preview` EAS Update channel, so OTA JS patches must be published to the same
  channel (`eas update --channel preview`). The `version` in `app.config.ts` is the release
  identity; the `versionCode` is derived from the build date as `YYMMDDNNN` (bump `BUILD_NUMBER`
  only for a 2nd+ build the same day). Attach the APK to a GitHub release — the in-app updater
  discovers new versions from the latest GitHub release.

## Using the features

- **Clipboard** — just copy on either device; the other one follows. Text and images both sync
  both ways. You can pause _sending_ from the phone in Settings while still receiving the Mac's
  copies, and there's a separate **Send images** switch if you want text-only in one direction.
- **Lock Mac** — tap **Lock Mac** on the phone's Home screen (needs the Mac connected).
- **Auto-lock when you leave** — turn it on in **both** apps: the phone's Settings
  (_Auto-lock Mac when I leave_) and the Mac menu (_Lock when phone leaves_). On the Mac you can
  tune **Sensitivity** (Near / Balanced / Far) and **Lock after** (10–60 s), and watch the live
  signal to calibrate for your space.
- **Notification mirroring** — grant **Notification access** to the app once (Settings →
  _Mirror notifications_), and Android notifications appear on the Mac as banners and in the
  dashboard's **Notifications** tab. One-way; pausable from the phone without revoking the grant.
- **Read your messages** — grant **SMS access** once (Settings → _Grant SMS access_), and your
  recent texts plus new ones arrive as conversation threads on the Mac's **Messages** tab.
  Read-only and one-way for now; pausable from the phone without revoking the grant.
- **Battery & phone identity** — the Mac's charge shows on the phone's Home screen; the phone's
  battery and name show on the Mac's dashboard. No setup — it rides the same connection.

## Security & privacy

- **Pair once.** The Mac generates a random room id + key and shows them as a QR — along with the
  relay address, port, TLS setting, and password — so the phone configures itself in one scan.
  Secrets live in the Keychain (macOS) and Keystore-backed storage (Android).
- **You own the relay.** It routes messages by room id and never stores content. The endpoint,
  password, and TLS are configured at runtime (nothing is baked into the build); run it over
  **TLS (`wss`)** behind a reverse proxy on infrastructure you trust.
- **LAN-direct is safe without TLS.** On the local network the link is plain `ws://`, but the
  payloads are still end-to-end encrypted and the connection is gated by a challenge-response over
  your pairing key — a stranger on the Wi-Fi can neither read it nor impersonate your phone.
- **Proximity lock is local.** Bluetooth only — never touches the relay or the internet.
- **End-to-end encrypted.** Clipboard text _and_ images, the lock command, battery telemetry,
  mirrored notifications, and mirrored messages are all sealed with **ChaCha20-Poly1305**, keyed
  by the secret exchanged at pairing. The relay (or anyone on your LAN) only ever sees opaque
  ciphertext — never your clipboard, your images, the command, your notifications, your texts, or
  the key.

## Scope & status

v1 links **one phone and one Mac**. Shipping today:

- ✅ **Two-way clipboard** — text **and images** (end-to-end encrypted; ~1 MiB payload cap, so an
  image is downscaled to fit)
- ✅ **Remote lock** & **proximity auto-lock**
- ✅ **LAN-direct** mode with automatic relay fallback
- ✅ **Two-way battery / phone telemetry**
- ✅ **One-way notification mirroring**
- ✅ **Read-only SMS mirroring** (phone → Mac)

On the roadmap: arbitrary **file** transfer (beyond clipboard images), **screen mirroring**,
**replying** to messages, and read-only **Calls / Photos** tabs. A separate technical document
([`TECHNICAL.md`](TECHNICAL.md)) covers the internals in depth.

## License

Personal project — see [`mobile/LICENSE`](mobile/LICENSE).
