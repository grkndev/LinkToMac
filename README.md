<div align="center">
<img src="/mobile/assets/images/icon.png" 
width="120" height="120">

# Link to Mac

**Your Android phone and your Mac, working as one.**

Two-way clipboard (text _and_ images), files and whole folders both ways, lock your Mac from
your phone, auto-lock when you walk away, mirrored notifications and messages (reply from the Mac),
and live battery both ways — over your own Wi-Fi, or through a relay you host yourself when you're away.

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
| 📎 | **Files & folders, both ways** | Share from the phone's share sheet or its **Files** screen; drop files or a folder on the Mac's window or menu-bar icon. Up to 1 GB each, resumable if cut off, with a history on the phone. |
| 💬 | **Your messages** | Your SMS appear as conversation threads on the Mac, and you can reply to 1:1 threads from there. _(Pausable.)_ |
| 🖥️ | **Mac dashboard** | A Material 3 menu-bar card + window: your phone, clip history, notifications, messages, settings. |
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
- Either way, clipboard content, files, messages and the "Lock Mac" command are **end-to-end
  encrypted** (ChaCha20-Poly1305, keyed by the secret you exchange at pairing).
- **Proximity auto-lock** uses neither path: the phone broadcasts a Bluetooth presence beacon and
  the Mac locks itself when the signal fades — so it works even with no internet.

> **The Android trick:** ordinary apps can't read the clipboard in the background, so the app
> connects to the phone's _own_ ADB over Wireless Debugging and runs a tiny privileged helper
> with clipboard I/O permissions. It keeps working after you swipe the app away. That helper is
> only for **automatic** clipboard capture — the link, files, lock, messages and notifications work
> without it, and the text-selection menu and the notification's **Send clipboard** button cover
> copying when it's off.

## Components

| Directory | What it is |
|---|---|
| [`mobile/`](mobile/) | Expo (SDK 56) React Native app — pairing, settings, the Files screen, and the background service doing clipboard sync, file transfer, notification/SMS mirroring and the Bluetooth beacon. |
| [`mac/`](mac/) | Swift menu-bar app + dashboard — clipboard sync, file transfer, notifications and messages, remote lock, proximity auto-lock, pairing QR, login-item auto-start, auto-update (Sparkle). |
| [`server/`](server/) | Minimal Node.js WebSocket relay (room routing, auth token, rate limiting). Docker-ready. See [`server/README.md`](server/README.md). |
| [`protocol-vectors/`](protocol-vectors/) | Shared test vectors for the wire formats the Swift and Kotlin sides mirror by hand — both test suites run them. |
| [`docs/`](docs/) | Design documents and implementation plans. |

## Getting started

0. **Just want to try it?** Download the Mac `.dmg` and the Android `.apk` from the latest
   [GitHub release](https://github.com/grkndev/LinkToMac/releases/latest) (both are unsigned — see
   _Building a release_ below for the first-launch steps) and skip to step 2's pairing.
1. **Relay _(optional)_** — only needed to sync while you're _away_ from your Wi-Fi. On the same
   network the app works relay-free. To run one: `cd server && npm install && npm run dev` (or
   `docker compose up -d`). See [`server/README.md`](server/README.md) for env vars and
   reverse-proxy (`wss`) setup.
2. **Mac app** — open `mac/LinkToMac.xcodeproj` (generated from `project.yml` via XcodeGen) and
   run. **LAN-direct is on by default** (Settings ▸ Relay Server → _LAN-direct_); add a relay's
   address / port / TLS / password there only if you want away-from-home sync. Then show the
   **pairing QR**.
3. **Android app** — `cd mobile && bun install`, then build a dev client (`bun run android`, which
   installs a separate `.dev` variant next to any release build). Expo Go isn't supported (custom
   native module). Pair once by scanning the Mac's QR — it carries the LAN port (and relay
   address / password, if set), so the phone configures itself and prefers the direct LAN link
   automatically. Editable later under **Settings → Relay server**. For **automatic** clipboard
   capture, also turn on **Wireless Debugging** and pair it once (Settings → _Automatic capture_);
   the app works without it.

### Tests

```sh
cd mac && xcodegen generate && xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -destination 'platform=macOS' test
cd mobile/android && ./gradlew :selfadb:testDebugUnitTest      # first run needs network (JUnit, org.json)
cd mobile && npx tsc --noEmit && npx expo lint
cd server && npm run typecheck && npm run smoke                # smoke needs `npm run dev` running
```

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
  both ways. Copies on the phone are always sent; the Mac side still has its own switches
  (**Send copies to Android**, **Sync images**) if you want a one-way flow.
- **Send a file** — from the phone, share anything and pick **Send to Clipboard** (images, ready
  to paste) or **Send as a File** (any type, original quality, several at once). Or open **Files**
  on the phone's Home screen: **Send files**, **Send folder** (its structure is kept), the history of
  everything sent and received (tap to open, **Retry** a failed send). From the Mac, drop files
  and/or folders on the dashboard window or the menu-bar icon.
  Files land in `Downloads/Link to Mac` on the phone, and in the folder you pick under
  **Settings ▸ Files** on the Mac. Up to **1 GB per file**, with progress on both ends; if a
  transfer is cut off, sending the same file again **resumes** where it stopped.
- **Lock Mac** — tap **Lock Mac** on the phone's Home screen (needs the Mac connected).
- **Auto-lock when you leave** — turn it on in **both** apps: the phone's Settings
  (_Auto-lock_) and the Mac's Settings ▸ Security (_Lock when phone leaves_). On the Mac you can
  tune **Sensitivity** (Near / Balanced / Far) and **Lock after** (10–60 s), and watch the live
  signal to calibrate for your space.
- **Notification mirroring** — grant **Notification access** to the app once (Settings →
  _Notifications_), and Android notifications appear on the Mac as banners and in the
  dashboard's **Notifications** tab; you can choose which apps are mirrored. One-way; pausable
  from the phone without revoking the grant.
- **Messages** — grant **SMS access** once (Settings → _Mirror messages_ → _Grant SMS access_), and
  your recent texts plus new ones arrive as conversation threads on the Mac's **Messages** tab.
  Open a 1:1 thread and type in the composer to **reply**: the phone sends a real SMS (grant
  **SMS Send Access** the first time). If Android blocks the permission on a sideloaded app, the
  button tells you the steps (_allow restricted settings_ in App info, then _Permissions → SMS_).
  Pausable from the phone without revoking the grants.
- **Battery & phone identity** — the Mac's charge shows on the phone's Home screen; the phone's
  battery and name show on the Mac's dashboard. No setup — it rides the same connection.
- **Updates** — the Mac checks for updates itself (Sparkle); the Android app tells you when a newer
  release is out and links its APK.

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
- **End-to-end encrypted.** Clipboard text _and_ images, files and folders, the lock command,
  battery telemetry, mirrored notifications, and messages (and your replies) are all sealed with
  **ChaCha20-Poly1305**, keyed by the secret exchanged at pairing. The relay (or anyone on your
  LAN) only ever sees opaque ciphertext — never your clipboard, your files, the command, your
  notifications, your texts, or the key. Anything a peer sends (file names, folder paths, sizes)
  is validated before it touches the disk.

## Scope & status

v1 links **one phone and one Mac**. Shipping today:

- ✅ **Two-way clipboard** — text **and images** (end-to-end encrypted; ~1 MiB frame cap, so a
  clipboard image is downscaled to fit)
- ✅ **Remote lock** & **proximity auto-lock**
- ✅ **LAN-direct** mode with automatic relay fallback
- ✅ **Two-way battery / phone telemetry**
- ✅ **One-way notification mirroring**
- ✅ **SMS mirroring** (phone → Mac) with **replies** to 1:1 threads from the Mac
- ✅ **Files and folders both ways** — phone share sheet and **Files** screen, and drag-and-drop onto
  the Mac's window or menu-bar icon (chunked + acknowledged, up to 1 GB per file, resumable, with a
  persisted history and retry on the phone)
- ✅ **Updates** — Sparkle on the Mac, in-app release check on Android

Known gaps: **Finder ▸ Share ▸ "Send to Phone"** doesn't work (macOS won't run an ad-hoc signed app
extension), and dragging from Mail/Photos isn't supported (use Finder). On the roadmap: FCM push-wake
for minimum idle battery, **screen mirroring**, and read-only **Calls / Photos** tabs. A separate
technical document ([`TECHNICAL.md`](TECHNICAL.md)) covers the internals in depth; per-release notes
are in [`release-notes/`](release-notes/) and the [`CHANGELOG`](CHANGELOG.md).

## License

Personal project — see [`mobile/LICENSE`](mobile/LICENSE).
