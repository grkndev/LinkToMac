# Link to macOS — Technical Reference

This document covers **how the system actually works** under the hood: the four
processes, the wire protocols between them, the data paths (clipboard, remote lock,
battery telemetry, proximity), and the platform tricks that make a background
clipboard sync possible on a stock Android phone.

It is the engineering companion to the user-facing [`README.md`](README.md). Where the
README says *"the Android app reads the clipboard through its own ADB"*, this document
explains the dex'd `app_process` daemon, the localhost NDJSON bridge, and the
`WRITE_SECURE_SETTINGS` self-grant that make it survive a reboot.

> **Security note up front:** clipboard payloads are **end-to-end encrypted** with
> ChaCha20-Poly1305 (RFC 8439), keyed by the 32-byte secret established at pairing. The relay
> only ever sees opaque ciphertext — never the key or the plaintext. See
> [§10 Security model](#10-security-model--current-limitations).

---

## 1. System overview

Four separate programs cooperate. Three of them are "yours" (you build/run them); the
fourth is a stock-Android system service the Android app talks to through a trick.

```
  ANDROID (phone)                         CLOUD                  macOS
  ┌────────────────────────────────┐                     ┌───────────────────────────┐
  │ Expo / React Native app (JS)   │                     │ SwiftUI menu-bar agent    │
  │   • UI, pairing, settings      │                     │   • NSPasteboard poll     │
  │   • drives native via Expo     │                     │   • URLSession WS client  │
  │     module (control plane)     │                     │   • CoreBluetooth central │
  │ ┌────────────────────────────┐ │   ┌─────────────┐   │   • SACLockScreen / QR    │
  │ │ Foreground Service (Kotlin)│ │   │  Node `ws`  │   │   • Keychain, login item  │
  │ │  • OkHttp WS → relay ──────┼─┼──►│   relay     │◄──┼── URLSessionWebSocketTask │
  │ │  • ClipBridge (localhost)  │ │   │ (room route)│   └───────────┬───────────────┘
  │ │  • BleAdvertiser           │ │   └─────────────┘               │
  │ └─────────┬──────────────────┘ │   forwards opaque               │
  │  connect  │ 127.0.0.1:53123    │   frames by roomId              │
  │ ┌─────────▼─────────────────┐  │   (no storage, no decrypt)      │
  │ │ ClipboardAgent (shell UID)│  │                                 │
  │ │  app_process daemon       │  │                                 │
  │ │  • IClipboard reflection  │  │                                 │
  │ │  • ServerSocket NDJSON    │  │                                 │
  │ └───────────────────────────┘  │                                 │
  └───────────────┬────────────────┘                                 │
                  └─────────────── BLE presence beacon ──────────────┘
                       (proximity auto-lock — fully local, no relay)
```

### The data paths

| Path | Transport | Touches the relay? | Direction |
|---|---|---|---|
| **Clipboard sync** | WebSocket `clip` frames | Yes — *or* LAN-direct (§5.1) | Both ways |
| **Remote lock** | WebSocket `cmd` frames | Yes — *or* LAN-direct (§5.1) | Phone → Mac |
| **Battery telemetry** | WebSocket `stat` frames | Yes — *or* LAN-direct (§5.1) | Both ways (Mac↔Phone) |
| **Notification mirroring** | WebSocket `note` frames | Yes — *or* LAN-direct (§5.1) | Phone → Mac |
| **Message (SMS) mirroring** | WebSocket `sms` frames | Yes — *or* LAN-direct (§5.1) | Phone → Mac |
| **Proximity auto-lock** | BLE advertisement | **No** (fully local) | Phone advertises → Mac decides |
| **Proximity distance** | BLE measure → `stat` frame | Yes — *or* LAN-direct (§5.1) | Mac measures → Phone shows |

The clipboard, lock, battery, notification, and message paths share one connection per device — the
relay, or, on the same network, a **direct link to the Mac** with no relay (§5.1). The proximity path
is completely independent — it works with no internet at all.

### Tech stack

| Component | Language / runtime | Key dependencies |
|---|---|---|
| `server/` | Node ≥ 20, TypeScript (ESM) | `ws`, `pino`, `dotenv` |
| `mac/` | Swift 6 (strict concurrency), SwiftUI | AppKit, CoreBluetooth, CryptoKit, Security, ServiceManagement — all system frameworks, **no third-party deps** |
| `mobile/` (JS) | Expo SDK 56, React Native 0.85, Expo Router, React 19 | `expo-secure-store`, `expo-camera`, `react-native-keyboard-controller`, `uniwind` |
| `mobile/modules/selfadb` (native) | Kotlin (Expo Module) | `libadb-android` 3.1.1, BouncyCastle, Conscrypt, OkHttp 4.12 |
| `clipboard-agent` | Java → dex | none (reflects into framework `IClipboard`) |

---

## 2. The relay server (`server/`)

A deliberately dumb pipe. It pairs the two ends of a *room* and forwards opaque frames
between them. It never stores anything and never inspects clipboard content.

### Connection lifecycle

1. Client connects to `ws(s)://host:PORT/ws`, authenticated by a `RELAY_AUTH_TOKEN` (the
   operator-defined relay password) passed as `Authorization: Bearer <token>` or `?token=`.
   The check uses `crypto.timingSafeEqual` (`server/src/index.ts`).
2. The first frame **must** be `join` (a `JOIN_TIMEOUT_MS`, default 10 s, drops silent
   sockets). `join` carries `{ room, device }` where `device` is `"android"` or `"mac"`.
3. The relay keeps an in-memory `Map<roomId, Map<device, Conn>>`. A room is capped at
   `MAX_PEERS_PER_ROOM` (default **2**).
4. **Newest-wins:** a reconnecting `android`/`mac` evicts its own stale connection (close
   code `4000`) rather than being rejected — this is what makes reconnect-after-sleep clean.
5. On join, the newcomer gets `{ t: "joined", peers: [...] }`; the existing peer gets
   `{ t: "peer", state: "online", device }`. Disconnect sends the symmetric `offline`.

### Forwarding rules (`server/src/relay.ts`)

- `clip`, `cmd`, `stat`, and `note` frames are `JSON.stringify`'d and sent **verbatim to the
  *other* peer only** — the sender never receives its own echo.
- `cmd` is **fully opaque**: the action plaintext is E2E-encrypted into `nonce`/`ct` (same AEAD
  as `clip`), so the relay can't tell one command from another and forwards it verbatim — new
  remote commands never require a server change, and a malicious relay/room can't forge one.
- `stat` carries **opaque telemetry**, E2E-encrypted into `nonce`/`ct` just like `clip`, and is
  now **bidirectional**: the Mac sends `{level, charging}` (its own battery) and the phone sends
  `{level, charging, name}` (its battery + device name); each side ignores fields it doesn't use.
  The relay forwards it opaquely either direction.
- `note` carries an **opaque mirrored notification** (phone → Mac), E2E-encrypted the same way;
  the relay forwards it verbatim. Like `stat`, the message type was an additive,
  backward-compatible protocol change (the relay just learned a new type to fan out).
- **Backpressure:** if a peer's `ws.bufferedAmount` exceeds `maxPayloadBytes * 8`, it is
  declared a slow consumer and dropped (close code `4003`) instead of buffering unbounded.
- Logs are privacy-preserving: the `roomId` is redacted to a 6-char prefix, and only
  *ciphertext length* + fan-out count are recorded — never `nonce`/`ct`.

### Hardening

- Per-connection **sliding-window rate limit** (`RATE_LIMIT_MSGS` / `RATE_LIMIT_WINDOW_MS`,
  default 120 / 10 s; `server/src/ratelimit.ts`).
- `maxPayload` of 256 KB enforced at the `ws` layer; binary frames rejected.
- ws-level **ping/pong heartbeat** (`PING_INTERVAL_MS`, default 50 s — under the front-proxy's
  60 s WS read timeout, and tuned to minimise mobile radio wakeups) with dead-connection reaping
  (`server/src/heartbeat.ts`).
- `GET /health` returns `{ status, rooms, conns, uptimeSec }`.
- Graceful `SIGTERM`/`SIGINT` shutdown (close code `1001`, 3 s force-exit).

### Deployment

Ships as a Docker image (`server/Dockerfile`, `docker-compose.yml`) serving **plain `ws`**.
TLS (`wss`) is terminated by a reverse proxy — the README shows Caddy (automatic Let's
Encrypt) and Nginx configs; nginx-proxy-manager works too. Public endpoint becomes
`wss://<domain>/ws`. The compose file attaches the relay to the proxy's shared Docker network
and **publishes no host port**, so only the reverse proxy can reach it.

> **Runtime-configured endpoint (no baked-in secrets).** The relay address, port, TLS, and
> password are entered at runtime and carried in the pairing QR — nothing is injected at build
> time. The Mac stores them via **Server Settings…** (`ServerSettings.swift`: UserDefaults +
> Keychain) and embeds them in the QR; the phone reads them from the QR (or **Settings → Relay
> server**) into a `ServerConfig` (`server-config.ts`, SecureStore). A `secure` flag selects
> `ws://` vs `wss://`. Only the server still keeps an env file (`server/.env`) for its
> `RELAY_AUTH_TOKEN` / `HOST` / `PORT`.

---

## 3. Android: the hard part

Regular Android apps **cannot read the clipboard in the background** (Android 10+ restricts
`getPrimaryClip` to the focused app / IME). The whole Android architecture exists to work
around that one restriction without root.

The solution: run a small helper process **as the `shell` user (UID 2000)**, which *is*
allowed to touch the clipboard, and have the app talk to it over a localhost socket. The app
gets `shell` privileges by connecting to the phone's **own** ADB daemon over Wireless
Debugging — "self-ADB".

```
        Expo module (control plane, only alive with JS)
              │  start / pair / deploy / kill
              ▼
  libadb-android  ──TLS+spake2──►  on-device adbd  (Wireless Debugging)
              │  exec / push streams
              ▼
  app_process ──launches──►  ClipboardAgent (shell UID, DETACHED daemon)
                                   │  ServerSocket 127.0.0.1:53123 (NDJSON)
  ClipForegroundService ◄──────────┘
        owns ClipBridge (localhost client) + RelayClient (WS) + BleAdvertiser
        survives app swipe (START_STICKY)
```

### 3.1 Self-ADB (`AdbManager.kt`)

- Built on **`libadb-android`** (MuntashirAkon, v3.1.1) — a pure-Java ADB client that
  implements **adb-over-TLS + spake2 pairing**, required on Android 11+. (The classic
  `cgutman/AdbLib` doesn't do TLS, so it can't connect to a modern adbd.)
- On first use the app generates an **RSA-2048 keypair + a self-signed X.509 cert**
  (BouncyCastle), persisted in `filesDir` as `adbkey` / `adbkey.pub` / `adbcert.pem`. This is
  the app's ADB identity.
- **Pairing** uses the 6-digit code from Android's *"Pair device with pairing code"* dialog
  over the `_adb-tls-pairing._tcp` mDNS service. **Connecting** uses `_adb-tls-connect._tcp`.
  Both are discovered with `AdbMdns` (NsdManager) because the ports are random and change on
  reboot — `discover()` blocks on a `CountDownLatch` until the service is advertised or it
  times out.
- `isPaired()` only checks whether the local key file exists. **This is a local-only signal
  and can lie:** Samsung/One UI wipes the paired-keys list on a Wireless-Debugging toggle or
  reboot, so adbd may reject a key the app still has. That surfaces as an
  `AdbPairingRequiredException` at connect time, which the orchestrator catches and routes to
  the re-pair screen (see §3.6).

### 3.2 The `WRITE_SECURE_SETTINGS` self-grant trick

After reboot, Wireless Debugging is typically **off**, and you'd normally need to re-open the
dialog and type a code. To avoid that, the app grants *itself* a privileged permission while
it briefly holds a `shell` session:

```
pm grant <pkg> android.permission.WRITE_SECURE_SETTINGS
```

This works because `WRITE_SECURE_SETTINGS` carries the `development` protection flag, so it
*can* be granted over ADB. It must also be declared in the manifest for the grant to stick.
Once held, the app can flip `Settings.Global "adb_wifi_enabled"` itself — turning Wireless
Debugging on, mDNS-connecting, deploying, and turning it back off — **with no code and no
taps on subsequent reboots**.

### 3.3 The privileged daemon (`ClipboardAgent.java`)

A tiny Java program compiled to dex (`clipboard-agent.dex`, built by
`native-src/clipboard-agent/build-dex.sh`), bundled as a module asset, pushed to
`/data/local/tmp/`, and launched with:

```
CLASSPATH=/data/local/tmp/clipboard-agent.dex app_process /system/bin \
  --nice-name=linktomac_clip com.grkndev.clipboard.ClipboardAgent 53123 <SECRET>
```

The trailing `<SECRET>` is the **bridge-auth secret**: a random 32-byte base64 value the app
mints once, persists (`PREFS_UI`, so an unpair can't orphan a running daemon), and passes at
every launch. When launched without it (a stale launcher) the daemon runs in legacy open mode.

What it does, all via **reflection into hidden framework APIs** (it runs as `shell`, so it's
allowed to):

- Resolves `IClipboard` via `ServiceManager.getService("clipboard")` →
  `IClipboard$Stub.asInterface`.
- `read()` / `write()` call `getPrimaryClip` / `setPrimaryClip`, spoofing the calling package
  as `com.android.shell` and adapting argument lists by reflection (`args()` fills `ClipData`,
  listener, package, userId slots positionally so it survives signature drift across OEMs/API
  levels).
- Registers a clipboard-change listener via `addPrimaryClipChangedListener`, passing a
  **dynamic `Proxy`** whose `asBinder()` returns a real `Binder`. The system's
  `dispatchPrimaryClipChanged` callback lands as `onTransact(FIRST_CALL_TRANSACTION, …)`,
  where the agent re-reads the clip and emits it.
- Opens `ServerSocket(53123, … 127.0.0.1)` and speaks **NDJSON** (newline-delimited JSON):
  - app → daemon: `{"cmd":"auth","secret":"…"}` — **required first line** when the daemon was
    launched with a secret. Until it arrives (5 s `soTimeout`) and matches (constant-time
    `MessageDigest.isEqual`), the connection is served **nothing** — no initial clip sync, no
    command handling — and a mismatch/timeout closes it. This is what stops any other app with
    `INTERNET` (auto-granted) from reaching loopback and reading/injecting the clipboard.
  - daemon → app: `{"type":"clip","text":"…","ts":1234}`
  - app → daemon: `{"cmd":"write","text":"…"}`
- A `lastSeen` string suppresses the echo of the agent's *own* writes.

> **Bind the socket before any privileged clipboard IPC.** `main()` starts the `serve()` thread
> (the `ServerSocket` bind) **first**, then runs a best-effort, read-only self-test and the
> listener registration **off the main thread / wrapped so they can't be fatal**. The app's
> `waitForDaemon` only checks this socket, so anything that blocks or throws before the bind —
> e.g. `setPrimaryClip`/`getPrimaryClip` stalling under shell UID on some One UI builds — makes
> the launch look like a failure (`DaemonNotStartedException`) and loops the pairing/reconnect
> screen. That was the second half of issue #5: the old `main()` did a `setPrimaryClip` self-test
> on the main thread *before* binding, so the daemon never bound and `clip.log` stayed empty.
> Keep the bind independent of clipboard reflection, and **flush stdout per line** (`log()`) so
> `clip.log` is actually diagnostic when a start fails. Rebuild the dex (`build-dex.sh`) after
> editing this ordering.

**Detached-daemon trick (the key to survival):** the launch command is wrapped in
`nohup setsid sh -c '…' >log 2>&1 </dev/null &`. `setsid` puts it in a new session so adbd's
process-group kill can't reach it; `nohup` ignores `SIGHUP`; stdio is detached. Result: the
daemon **survives ADB disconnect, Wireless Debugging being turned off, and the app being
killed.** Only a reboot, a crash, or an explicit `killDaemon()` stops it. ADB is needed only
to *launch* (or relaunch) it — never for the steady-state data path.

> **`nohup setsid` is NOT enough on its own — `launchDaemon` must block until the daemon binds.**
> We launch over libadb's `exec:` service, and adbd kills that service's process group when the
> stream closes. A daemon that is still cold-starting (ART/dex load, ~1-2s) gets killed *before*
> `setsid` has fully detached it / before it binds, if the launch returns immediately. So the
> launch command's foreground polls `clip.log` for the daemon's flushed `listening` line and only
> then closes the stream — by which point the daemon is detached + bound and survives. Returning
> right after `echo LAUNCHED` was the third and final face of issue #5: the daemon "launched" but
> never bound (empty `clip.log`, `DaemonNotStartedException`, reconnect loop) — even though the
> exact same dex binds fine when launched over the `shell:` service (which doesn't tear the group
> down). Don't shorten the launch to a fire-and-forget.

### 3.4 The bridge + foreground service (`ClipBridge.kt`, `ClipForegroundService.kt`)

- **`ClipBridge`** is the on-device localhost *client* to the daemon. It connects to
  `127.0.0.1:53123`, retries with backoff until the daemon's `ServerSocket` is up, sends the
  `auth` line first (the persisted daemon secret — see §3.3), then reads `clip` lines and
  writes `write` commands. `stop()` closes the socket (an `interrupt()` can't unblock a parked
  `readLine()`), and every exit path closes the per-iteration socket so an abnormal read error
  can't leak the fd. The daemon serves connections on **per-connection handler threads with
  newest-wins eviction**: a freshly authenticated bridge replaces (closes) the previous live
  connection, so a wedged old connection can never lock a restarted bridge out.
- **`ClipForegroundService`** owns the bridge, the relay WS client, and the BLE advertiser. It
  runs as a **`START_STICKY` foreground service** with type `specialUse|connectedDevice`
  (Android 14+ requires a declared type). Because it's `START_STICKY`, the system restarts it
  with a null intent after a kill, and `onStartCommand` re-reads persisted config
  (`SharedPreferences`) and reconnects everything **with no JS runtime present**.
- Echo suppression on the Android side: when a clip arrives from the Mac, the service stamps
  it into a **time-bounded recent-writes map** (10 s window, consumed on match — a single slot
  bounced rapid A-then-B sequences back to the Mac) and writes it to the device clipboard; the
  resulting `onClip` from the daemon is recognized and swallowed.
- A `sendPaused` flag gates **outbound** (Mac-bound) forwarding only — inbound clips from the
  Mac still arrive while paused. This backs the *"pause sending from the phone"* setting.

### 3.5 Relay client + BLE beacon (Android)

- **`RelayClient.kt`** is an OkHttp `WebSocket`. It joins as `"android"`, uses OkHttp's native
  `pingInterval` (50 s — under the relay front-proxy's 60 s WS idle timeout, tuned to minimise
  mobile radio wakeups; matches the server's own heartbeat) for keepalive, and reconnects with
  exponential backoff capped at 30 s.
  All state runs on a single-thread executor; late OkHttp callbacks after shutdown are dropped
  rather than crashing (a `RejectedExecutionException` guard — this was a real "crash on pause"
  bug). It sends `clip` and `cmd` frames and applies received clips through the service.
- **`BleAdvertiser.kt`** advertises a **non-connectable** BLE beacon whose only payload is a
  128-bit service UUID derived from the pairing room (see §8). Balanced advertise mode, medium
  TX power. Presence *is* the entire signal — there's no connection or data exchange.

### 3.6 Boot orchestration (`SelfAdbModule.autoStart` + `use-clip-boot.ts`)

One `autoStart(clipPort)` call drives the whole bring-up and returns a state string the JS
root layout gates a screen on:

```
probe localhost:53123 ── alive + secret known ───────────────────► "ready"   (attach, no ADB)
        │ dead (or alive with an unknown secret -> restart it via ADB below)
   isPaired()? ── no ──────────────────────────────────────────► "need-pair"
        │ yes
   self-enable Wireless Debugging (if WRITE_SECURE_SETTINGS held)
        │
   mDNS discover _adb-tls-connect ── not found ────────────────► "need-connect"
        │ found
   drop stale adb session (isConnected → disconnect), then
   connect ── AdbPairingRequiredException ─────────────────────► "need-pair"  (re-pair gate)
        │ ok
   deploy (push dex if needed + launch daemon) → start service → "ready"
```

The JS hook (`useClipBoot`) wraps the native call in a **20 s timeout** because ADB's TLS
connect and exec streams have no internal deadline and a half-trusted adbd can stall forever.
A timeout is treated as "paired but stuck" → routed to the recoverable reconnect screen, and
the hook re-runs `autoStart` whenever the app returns to the foreground (covers the user
toggling Wireless Debugging in system settings).

> **`adb.connect()` returns `false` only when a session is already live** (libadb's
> `isConnected()` guard) — it is *never* a genuine failure, which always **throws**
> (`AdbPairingRequiredException` / `IOException`). The `AdbManager` is one instance for the
> JS-runtime lifetime, so a link from an earlier `pairAuto`/`autoStart` can still be open here
> — and stale if Wireless Debugging was toggled since. `autoStart` reaches this branch only
> with a **dead daemon it must redeploy**, so it `disconnect()`s any existing session first and
> reconnects fresh. Treating `false` as a failure (the original bug, issue #5) threw "connect
> failed despite mDNS endpoint" and skipped the redeploy, looping the reconnect screen after a
> successful re-pair. Don't reintroduce a `throw` on `connect()==false`.

### 3.7 The JS ↔ native seam (`ClipBus.kt`)

The Expo module only exists while the JS runtime is alive; the foreground service outlives it.
**`ClipBus`** is the process-wide bridge: the service always posts events here, and the module
attaches/detaches its `onClip` / `onMacClip` / `onMacStat` / `onLog` / `onRelay` callbacks in
`OnCreate`/`OnDestroy`. It also holds bounded ring buffers — 400 log lines and 100 Mac-clip
entries — so the Logs and Clipboard-History screens can show events that happened *before* the
JS runtime attached (e.g. an FGS reconnect while the app was swiped away). `lastRelay` and
`lastStat` let a late-attaching UI query the current relay status and Mac battery immediately.

---

## 4. macOS: the menu-bar agent (`mac/`)

A SwiftUI `MenuBarExtra` (`.window` style, so the dropdown is a real panel with switches, not
a plain menu) **plus a separate dashboard window** opened from it. No Dock icon. Swift 6 with
complete strict concurrency; everything observable is `@MainActor`-isolated and async loops hop
back to the main actor on each step. **Zero third-party dependencies except Sparkle** (auto-update)
— otherwise only system frameworks. Built reproducibly from `project.yml` via XcodeGen, ad-hoc
signed (`CODE_SIGN_IDENTITY: "-"`, hardened runtime off) so it runs locally without a Developer
team.

The UI is **Material 3-flavoured** (mirroring the mobile app): the menu-bar dropdown is a compact
phone-identity card (phone render + name + live status dot + tonal transport/battery chips), and
the dashboard window hosts the phone panel, clip history, a Notifications tab, and
roadmap-placeholder feature tiles.

| File | Role |
|---|---|
| `RelayClient.swift` | `URLSessionWebSocketTask` to the relay; join, ping/pong, presence, reconnect; owns the pasteboard + battery monitor, the inbound `stat`/`note`/`sms` decode, clip-history ring, notification ring, and message store (`conversations`) |
| `LanServer.swift` | LAN-direct WS server (`NWListener`) + Bonjour + HMAC handshake; `onRemoteStat`/`onRemoteNote`/`onRemoteSms` for the relay-less path |
| `PasteboardWatcher.swift` | Polls `NSPasteboard.changeCount`; echo suppression |
| `BatteryMonitor.swift` | IOKit power-source poll → outbound `stat` (the Mac's own battery) |
| `ClipCodec.swift` | E2E payload encryption — ChaCha20-Poly1305 (CryptoKit) |
| `MacNotifier.swift` | Raises native banners for mirrored notifications (`UNUserNotificationCenter`; icon as a best-effort attachment with a text-only fallback) |
| `ProximityMonitor.swift` | CoreBluetooth central; RSSI → lock decision |
| `ScreenLock.swift` | Locks the screen |
| `Pairing.swift` | Room/key generation, Keychain, QR rendering (v3 also embeds the server + LAN config) |
| `ServerSettings.swift` | Runtime relay endpoint store — host/port/TLS in `UserDefaults`, password in Keychain |
| `LoginItem.swift` | `SMAppService` auto-start at login |
| `MenuPanel.swift` / `PairingView.swift` | Menu-bar UI (phone-identity card, last-copy glance, Pairing QR, Server Settings) |
| `DashboardWindow.swift` / `DashboardComponents.swift` | Dashboard window shell + shared M3 components |
| `PhonePanel.swift` | Phone identity: name, connection status, transport + battery chips (hidden when nil) |
| `ClipHistoryScreen.swift` | Clip history grouped by recency, tap-to-recopy, clear |
| `FeaturePanel.swift` | Right-column tabs — the **Notifications** tab renders the live note ring, the **Messages** tab renders `conversations` (thread list → chat bubbles); Calls/Photos are placeholders |
| `SettingsScreen.swift` / `AppearanceSettings.swift` / `AboutView.swift` / `RelayScreen.swift` / `ServerSettingsView.swift` | Settings, appearance, about, relay, and "Server Settings…" surfaces |

### 4.1 RelayClient (Swift)

`@Observable`, `@MainActor`. Uses a monotonic **`generation` counter** so that loops belonging
to a replaced socket bail out instead of corrupting current state — important since
receive/heartbeat run as detached `Task`s. App-level ping every 25 s; exponential backoff
reconnect capped at 30 s. Joins as `"mac"`. On a received `clip` it writes to the pasteboard (and
appends to an in-memory clip-history ring the dashboard reads); on a `cmd` it dispatches to a
handler (currently only `"lock"`). It also **reports the Mac's battery** as `stat` frames
(`BatteryMonitor.swift`, IOKit power sources): pushed the moment a peer connects and whenever the
level/charging state changes; a desktop Mac with no battery sends nothing. **Inbound** `stat` is
decoded into `phoneBatteryLevel`/`phoneCharging`/`phoneName` for the dashboard's PhonePanel (the
Mac no longer displays *its own* battery to itself — you're already on the Mac). Inbound `note`
frames are upserted by key into the notification ring and raised as banners (§5.2). A persisted
`sendToAndroid` flag is the Mac-side equivalent of the phone's pause toggle. The endpoint comes
from `ServerSettingsStore`, so it stays **idle until configured** rather than dialing a
placeholder; `reconnect()` re-dials on a Server Settings change, and `wss://` is used when the
`secure` flag is set. Unpair clears the clip-history and notification rings.

### 4.2 Clipboard watching + echo suppression

`NSPasteboard` has **no change notification**, so `PasteboardWatcher` polls `changeCount`
every 500 ms. Echo suppression is a single-stamp scheme: writing a remote clip records the
resulting `changeCount` as `lastChangeCount`, so the next poll sees "no new change" and doesn't
re-broadcast our own write. Because both the write and the poll run on the main actor, the
stamp is race-free (last writer wins within a poll window).

### 4.3 Remote lock (`ScreenLock.swift`)

Primary path: `dlopen` the private `login.framework` and call **`SACLockScreenImmediate`** —
the same call the system "Lock Screen" uses. It locks in place (no fast-user-switch) and needs
no entitlement, which is fine because the app isn't sandboxed and the hardened runtime is off.
If the symbol can't be resolved on a future macOS, it falls back to
`CGSession -suspend` (drops to the login window).

---

## 5. Wire protocol (relay)

JSON text frames over WebSocket. The relay reads control frames but treats `clip`/`cmd`/`stat`/`note`
payloads as opaque. Defined in `server/src/protocol.ts`, mirrored by `RelayProtocol.swift`
(Mac) and inline `JSONObject` building in `RelayClient.kt` (Android).

```jsonc
// client → relay
{ "t": "join", "room": "<roomId>", "device": "android" | "mac" }
{ "t": "clip", "nonce": "<base64>", "ct": "<base64>" }   // forwarded verbatim
{ "t": "cmd",  "nonce": "<base64>", "ct": "<base64>" }   // action E2E-encrypted, forwarded verbatim
{ "t": "stat", "nonce": "<base64>", "ct": "<base64>" }   // telemetry (battery ± name; Mac also ± BLE prox/rssi), bidirectional, E2E-encrypted, forwarded verbatim
{ "t": "note", "nonce": "<base64>", "ct": "<base64>" }   // mirrored notification (phone → Mac), E2E-encrypted, forwarded verbatim
{ "t": "sms",  "nonce": "<base64>", "ct": "<base64>" }   // mirrored SMS batch/delta (phone → Mac), E2E-encrypted, forwarded verbatim
{ "t": "ping" }

// relay → client
{ "t": "joined", "peers": ["mac"] }
{ "t": "peer",   "state": "online" | "offline", "device": "mac" }
{ "t": "clip",   "nonce": "...", "ct": "..." }            // the peer's frame, relayed
{ "t": "cmd",    "nonce": "...", "ct": "..." }            // the peer's command, relayed
{ "t": "stat",   "nonce": "...", "ct": "..." }            // the peer's telemetry (battery ± name; Mac also ± BLE prox/rssi), relayed
{ "t": "note",   "nonce": "...", "ct": "..." }            // the peer's mirrored notification, relayed
{ "t": "sms",    "nonce": "...", "ct": "..." }            // the peer's mirrored SMS batch/delta, relayed
{ "t": "error",  "code": "room-full" | "bad-join" | "not-joined" | "rate-limit"
                       | "join-timeout" | "bad-message", "message": "..." }
{ "t": "pong" }
```

`room` is validated to 16–128 chars (the base64 of 32 random bytes is 44). Malformed frames
get a `bad-message` error and are dropped.

### 5.1 LAN-direct transport (relay-less)

On the same network the phone can skip the relay entirely and talk **straight to the Mac**. The
roles invert: the **Mac becomes the WebSocket server** (`LanServer.swift`, `Network.framework`
`NWListener` + `NWProtocolWebSocket` — all system frameworks, no third-party deps) and the phone
is the client (`LanClient.kt`, OkHttp). Transport is plain `ws://` (no TLS on the LAN), but
`clip`/`cmd`/`stat`/`note` stay E2E-encrypted, so a sniffer sees only opaque ciphertext.

- **Discovery (hybrid).** The Mac advertises Bonjour `_linktomac._tcp` on its LAN port (default
  **53124**) with TXT `rid = base64url(SHA256(room))[:16]` + `name`. The phone recomputes the same
  `rid` from its stored room and connects only to a matching service (`LanDiscovery.kt`,
  `NsdManager`) — so it finds *its* Mac on a multi-Mac LAN and re-finds it after a DHCP change. A
  manual Mac IP (Settings → Relay server) is the escape hatch when mDNS is blocked. **Discovery is
  Wi-Fi-gated** (`ConnectivityManager` callback in `ConnectionManager.kt`): it runs only while a
  Wi-Fi network is present and not already LAN-joined, and stops on join. Off Wi-Fi (e.g. cellular)
  the Mac can't be on the LAN, so the phone drops discovery — releasing its battery-draining Wi-Fi
  multicast lock — and leans on the relay.
- **Auth handshake** (LAN has no relay token/room gate): on connect the Mac sends
  `{ t:"hello", nonce }`; the phone replies `{ t:"auth", proof }` where
  `proof = base64(HMAC-SHA256(key, nonce))`; the Mac verifies in constant time and replies
  `{ t:"ready" }` (else drops the socket). No secret crosses the wire; replay is bounded to a
  single fresh nonce.
- **Auto-switch.** The phone's `ConnectionManager.kt` keeps exactly **one** link live: it prefers
  LAN and falls back to the relay after a short grace window or when LAN drops, switching back
  when the Mac reappears. With no relay configured it's LAN-only. The Mac runs both the LAN server
  and (if configured) the relay client at once; the phone being the sole arbiter prevents
  double-delivery.
- **Config.** Carried in QR **v3** (`lport`, `lan`) alongside the relay fields; persisted in
  `ServerConfig` (`lanEnabled`/`lanPort`/`lanHost`). Cleartext `ws://` is permitted via the
  module manifest's `usesCleartextTraffic` (Android) and `NSAllowsLocalNetworking` (macOS); the
  Mac also declares `NSLocalNetworkUsageDescription` + `NSBonjourServices`.

### 5.2 Notification mirroring (`note`, phone → Mac)

An Android `NotificationListenerService` (`NotificationListener.kt`) captures every posted/removed
notification once the user grants **"Notification access"** (a special access in system settings,
*not* a runtime permission; opened from the app via `SelfAdbModule.openNotificationAccessSettings`).
It runs in the app process and survives a JS swipe like the FGS. It filters out noise (its own FGS
notification, `FLAG_ONGOING_EVENT`/`FLAG_FOREGROUND_SERVICE`/`FLAG_GROUP_SUMMARY`, and notes with no
title and no text), resolves the posting app's label + launcher icon (scaled to ~72 px, PNG,
base64, memoized per package), and forwards a `note` via the running `ClipForegroundService`
(`sendNote` → `ConnectionManager` → the active `RelayClient`/`LanClient`). The decrypted plaintext:

```jsonc
{ "op": "post" | "remove",        // remove = a phone-side dismissal
  "key": "<StatusBarNotification.key>",  // stable across an update → dedup/replace/remove
  "pkg": "com.whatsapp", "app": "WhatsApp",
  "title": "Mom", "text": "are you coming for dinner?",
  "category": "msg", "time": 1719300000000,  // postTime, epoch ms
  "icon": "<base64 PNG ~72px>" }   // omitted on remove; may be absent
```

The Mac (`RelayClient.applyNotification`) upserts by `key` into an in-memory, newest-first ring
(cap 100; caches icons per package), raises a native banner via `MacNotifier`
(`UNUserNotificationCenter`, gated by the **Notification banners** toggle; the source app's icon
rides as a `UNNotificationAttachment` — though macOS still shows *our* app icon in the banner's
top-left, which is fixed to the bundle for local notifications), and renders the list in the
dashboard's Notifications tab (`FeaturePanel`, with the app icon as each row's badge). Mirroring is one-way (the Mac never sends
`note`) and can be paused phone-side (`setNotificationForwarding`, persisted) without revoking the
system access grant. Cleared on unpair.

### 5.3 Message mirroring (`sms`, phone → Mac)

The phone reads its **SMS store** and shows it as real conversation threads on the Mac's Messages
tab. The reader, `SmsMirror.kt`, is **owned by the `ClipForegroundService`** (not a system service),
so it survives a JS swipe like the notification listener. It needs two **dangerous runtime
permissions** — `READ_SMS` (the texts) and `READ_CONTACTS` (resolve sender names) — granted from the
app's settings via `SelfAdbModule.requestSmsAccess`. `READ_SMS` is Play-restricted, but the app is
**sideloaded** (EAS `preview` APK), so the policy doesn't apply. SMS-only for v1 (no MMS/RCS).

Two paths, both gated by the grant + the **Mirror messages** toggle (`getSmsForwarding`, PREFS_UI,
default on; the soft pause that doesn't revoke the OS permission):

- **Backfill.** `SmsMirror.backfill()` queries `content://sms` for the newest ~200 messages,
  resolves each sender's contact name via `ContactsContract.PhoneLookup` (memoized per address in an
  `LruCache`), and pushes them as chunked `op:"batch"` `sms` frames (≤50 msgs/frame to stay well
  under the 256 KB cap). It runs **on every peer-online edge** (next to `pushBatteryStat(force=true)`
  in `ClipForegroundService`) — because the Mac's store is in-memory, a (re)connecting Mac
  re-receives the history. Idempotent: the Mac upserts by `id`.
- **Live deltas.** A `ContentObserver` on `content://sms` fires on any change; `SmsMirror` queries
  rows newer than the last-seen `_id` and pushes them as an `op:"add"` frame (covers received *and*
  sent messages, since `content://sms` includes both).
- **Only INBOX(1) and SENT(2) rows are mirrored** — DRAFT/OUTBOX/FAILED/QUEUED are skipped in the
  cursor loop, otherwise drafts and failed sends would render on the Mac as messages the user sent.

The decrypted plaintext:

```jsonc
{ "op": "batch" | "add",          // batch = backfill chunk; add = live delta (Mac upserts either way)
  "msgs": [
    { "id": 4711,                 // SMS _id — stable, drives dedup/upsert
      "thread": 12,               // thread_id — groups a conversation (falls back to addr)
      "addr": "+90555…", "name": "Ada",   // name omitted if no contact / no READ_CONTACTS
      "body": "see you then", "date": 1719300000000,  // epoch ms
      "dir": "in" | "out", "read": true }, … ] }
```

The Mac (`RelayClient.applySms`) upserts each message by `id` into an in-memory store (cap 500), and
`conversations` groups them by `thread` (newest activity first) for `FeaturePanel`'s Messages tab —
a thread list that drills into a chat-bubble view (outgoing trailing/`primaryContainer`, incoming
leading/`surfaceContainerHigh`). Mirroring is **one-way and read-only** (the Mac never sends `sms`;
replying from the Mac is roadmap). No delete/edit handling in v1 (SMS deletions are rare). Cleared on
unpair.

---

## 6. Clipboard sync — end to end

**Phone → Mac (copy on Android):**

1. The user copies. The system fires `dispatchPrimaryClipChanged` into `ClipboardAgent`'s
   proxy binder.
2. The agent reads the clip and emits `{"type":"clip", …}` over localhost to `ClipBridge`.
3. The foreground service checks it isn't the echo of its own write, records history, and
   (unless `sendPaused`) calls `RelayClient.sendClip`.
4. `ClipCodec.encode` **encrypts** (ChaCha20-Poly1305) → `{ t:"clip", nonce, ct }` → relay → Mac.
5. The Mac **decrypts** `ct`, stamps `lastChangeCount`, and writes `NSPasteboard`.

**Mac → Phone (copy on macOS):**

1. `PasteboardWatcher` poll sees a new `changeCount`, reads the string.
2. `RelayClient.sendClip` → `{ t:"clip", … }` → relay → phone.
3. The Android service stamps the text into its recent-writes map, writes it through the
   bridge → the daemon's `setPrimaryClip`. The agent's resulting change event is swallowed via
   `lastSeen`, and the service's own `onClip` is swallowed by the recent-writes stamp —
   **double echo suppression** because the write traverses two echo-producing boundaries.

Loop prevention is **per-boundary echo stamping** (not the version-vector/seq scheme sketched
in `workflow.md` — the implementation uses the simpler stamp because the relay never echoes to
the sender, so only local write-backs need suppressing).

---

## 7. Remote lock — end to end

1. The user taps **Lock Mac** on the phone's Home screen.
2. JS calls `SelfAdb.sendCommand("lock")` → the active link's `sendCmd` **encrypts** the action
   (`ClipCodec`, ChaCha20-Poly1305) → `{ t:"cmd", nonce, ct }`.
3. The relay (or, on the LAN, the Mac directly) forwards it verbatim to the `mac` peer.
4. The Mac **decrypts** `ct` and routes `cmd("lock")` to `ScreenLock.lock()`; a frame that fails
   to authenticate (forged / wrong key) is dropped.

The lock path is intentionally kept **off the clipboard path** and the `pause sending` toggle
doesn't affect it. Because the action is opaque ciphertext end to end, adding new remote commands
is a client-only change.

---

## 8. Proximity auto-lock — fully local

The phone advertises a BLE presence beacon; the Mac is the BLE **central** that scans for it
and locks when it fades. No relay, no internet.

### Shared beacon identity

Both sides derive the same 128-bit service UUID from the pairing `room`, so only *your* phone
matches and the UUID rotates automatically on unpair:

```
serviceUUID = first 16 bytes of SHA-256(utf8(room))   // big-endian → UUID(msb, lsb)
```

This derivation is byte-identical in `BleAdvertiser.serviceUuid` (Kotlin) and
`ProximityConfig.serviceUUID` (Swift) — that's the contract that makes the two sides find each
other with no extra pairing step.

### The Mac's decision logic (`ProximityMonitor.swift`)

- Scans **filtered to the derived UUID** with duplicates allowed, so every advertisement
  yields a fresh RSSI sample.
- Raw RSSI is noisy, so it's smoothed with an **EMA** (`alpha = 0.4`). Presence is re-evaluated
  every **2.5 s**.
- **Sensitivity** maps to an RSSI cutoff: Near `-68`, Balanced `-76`, Far `-83` dBm
  (calibrated on real hardware — same table ≈ −65/−68, adjacent room w/ door closed ≈ −77/−80).
- A reading at/above the cutoff refreshes `lastStrong` **and arms** the monitor. The Mac only
  locks if it has *previously* seen the phone strong (so leaving is a real departure, not a
  cold start).
- It locks when the phone hasn't been strong for the whole **grace window** (10/20/30/60 s,
  floored at 10 s to avoid RSSI-noise false locks). Crucially, refreshing on *signal strength*
  rather than mere packet receipt means walking to another room — still faintly in range but
  weak — counts as leaving.
- **Fails secure:** if the phone vanishes entirely, the timer ages out and it locks.
- **Distance display (both ends):** the same smoothed reading also feeds a UI label. The Mac shows
  it directly in the dashboard identity row (`ProximityMonitor.distanceText`). For the phone — which
  only *advertises* and so can't measure RSSI itself (RSSI is read by the receiver) — the Mac
  **forwards** its reading inside the `stat` frame (`prox`/`rssi`, throttled to ≥2 dBm moves or a
  bucket flip); `useMacDistance` renders it on Home. No Mac advertiser / phone scanner is needed:
  the phone↔Mac distance is the same number whichever end measures it. Gated on auto-lock being on
  (that's what runs the scan), so distance is hidden when the feature is off.

macOS has no API to auto-*unlock*, so this is lock-only by design.

---

## 9. Pairing & key management

The **Mac is the pairing initiator**. On first launch (`PairingStore.loadOrCreate`) it
generates:

- `room` — base64 of 32 random bytes; the relay bearer / room id.
- `key` — base64 of 32 random bytes; the E2E secret the `ClipCodec` (ChaCha20-Poly1305) keys on.

Both are stored in the macOS **Keychain** (generic-password item). The Mac shows a **v2** QR
encoding `{"v":2,"room":"…","key":"…","name":"<computer name>","host":"…","port":…,
"secure":true,"token":"…"}` via CoreImage's `CIQRCodeGenerator` (`Pairing.swift`) — it carries
both the pairing *and* the relay endpoint + password, so one scan fully configures the phone.
(Legacy v1 QRs without the server fields are still accepted; the phone then keeps its existing
server config.)

The phone scans it with `expo-camera`, validates it (`parsePairingQR`), and stores the pairing
plus the server config in two **`expo-secure-store`** entries (Android Keystore-backed). The
derived URL (`ws(s)://host:port/ws`) + token + room/key are then pushed into the native service
via `setRelay`, which persists them to `SharedPreferences` so the `START_STICKY` service can
reconnect without JS.

**Unpair** on the Mac deletes the Keychain item, mints a fresh room/key, and reconnects into
the new (empty) room — leaving the old phone stranded in the abandoned room. The rotated room
also rotates the BLE UUID, so proximity stops matching the old device automatically.

> Note there are **two distinct pairings**: the phone↔Mac *relay* pairing (room/key, above)
> and the phone↔adbd *self-ADB* pairing (RSA key + cert in the app's `filesDir`, §3.1). They
> are independent and fail independently.

---

## 10. Security model & current limitations

**What holds today:**

- **End-to-end encrypted clipboard.** `clip` payloads are sealed with **ChaCha20-Poly1305**
  (RFC 8439), keyed by the 32-byte pairing secret — `CryptoKit.ChaChaPoly` on the Mac,
  `javax.crypto "ChaCha20-Poly1305"` on Android (no third-party crypto deps). A fresh random
  12-byte nonce per message; the relay sees only `nonce` + ciphertext. **Fails closed:** a
  tampered or wrong-key frame fails the Poly1305 tag and is dropped, never written to a clipboard.
- The relay is a dumb pipe: it never stores content and never parses `nonce`/`ct`.
- `roomId` is an unguessable 256-bit bearer; the **operator-defined relay password**
  (`RELAY_AUTH_TOKEN`) is a second gate so strangers can't even open sockets. It is no longer
  baked into the build — the Mac operator sets it and it rides in the pairing QR (acceptable,
  since the QR already carries the more-sensitive E2E key) or is typed into the app. Per-room
  cap of 2, rate limiting, and payload caps limit abuse.
- Secrets live in the platform secure stores (Keychain / Keystore-backed SecureStore).
- Proximity is BLE-only and never touches the network.
- Remote lock uses no entitlement and can't *unlock*.

**What does NOT hold yet (be explicit about this):**

- 🟠 **Static key, no replay protection.** The pairing key is long-lived (rotates only on
  re-pair) and there's no per-message sequence number, so a captured ciphertext could in
  principle be re-injected by someone who can write to the relay. Low impact for a clipboard
  (last-writer-wins, and the bearer `roomId` + auth token gate relay access), but noted.
- 🟢 **Transport supports `wss`.** A per-server `secure` flag selects `wss://` vs `ws://`:
  point the app at a domain behind a TLS-terminating reverse proxy (Let's Encrypt) and toggle
  TLS on. `ws://` remains available for a trusted LAN. The relay password still benefits from the
  TLS tunnel; **`cmd` is now E2E-encrypted (AEAD) regardless of transport**, so a forged or
  replayed command fails the Poly1305 tag and is dropped even on plaintext `ws://`. The same
  holds for `stat` battery telemetry and `note` mirrored notifications — opaque ciphertext on
  every transport.
- 🟢 **LAN-direct needs no relay or TLS to stay confidential.** In relay-less LAN mode (§5.1)
  the transport is plain `ws://`, but `clip`/`cmd`/`stat`/`note` remain ChaCha20-Poly1305-encrypted
  and the socket is gated by an HMAC challenge-response over the pairing key — so a stranger on the LAN
  can neither read traffic nor occupy the peer slot. The unencrypted `room`/`rid` it could
  observe are non-secret routing ids.
- 🟢 **No secrets baked into the build.** The relay address, password, and TLS setting are
  configured at runtime (Mac **Server Settings…** → `UserDefaults`/Keychain; phone **Settings →
  Relay server** / pairing QR → SecureStore). Only `server/.env` holds the server's
  `RELAY_AUTH_TOKEN`. Rotating the password means updating `server/.env` and re-scanning the QR
  (or re-entering it in the app); nothing sensitive sits in tracked source.
- 🟠 **Wireless Debugging is a device-wide loosening.** Any client on the network holding an
  authorized key can reach adbd. Mitigation here is that it's your own device and the only
  trusted key lives in the app; the app turns Wireless Debugging back *off* after deploying.

---

## 11. Lifecycle & resilience

| Failure | What happens |
|---|---|
| App swiped away | Foreground service + detached daemon keep syncing; JS callbacks just detach |
| Service killed by OS | `START_STICKY` restarts it; it re-reads `SharedPreferences` and reconnects with no JS |
| Relay WS drops | Both clients reconnect with exponential backoff (cap 30 s) |
| Phone reboot | Wireless Debugging usually off → app self-enables it (if it holds `WRITE_SECURE_SETTINGS`), mDNS-reconnects, relaunches the daemon, turns WD back off |
| adbd forgot the key (Samsung) | `connect` throws `AdbPairingRequiredException` → routed to `need-pair` for a fresh code |
| Mac sleep/wake | `URLSession` task fails → generation-guarded reconnect |
| Mac crash | `SMAppService` login item relaunches at next login |

---

## 12. Build & run

Only the **relay** keeps a secret file; the Mac and phone are configured at runtime, so a
fresh checkout builds and runs with nothing to fill in — you just enter the server in the app.

| Component | Config | Where |
|---|---|---|
| Relay | `server/.env` (gitignored, from `server/.env.example`) | `RELAY_AUTH_TOKEN` (the relay password, `openssl rand -hex 32`), `HOST`, `PORT` |
| Mac | **Server Settings…** window | host/port/TLS in `UserDefaults`, password in Keychain (`ServerSettings.swift`) |
| Android | **Settings → Relay server**, or the pairing QR | `ServerConfig` in SecureStore (`server-config.ts`) |

The Mac embeds its endpoint + password in the pairing QR, so scanning it configures the phone
in one step. The relay's `RELAY_AUTH_TOKEN` must match the password you set on the Mac/phone.

| Component | Command |
|---|---|
| Relay | `cd server && cp .env.example .env && npm install && npm run dev` (or `docker compose up -d`) |
| Mac | `cd mac && xcodegen generate && open LinkToMac.xcodeproj` → Run, then set **Server Settings…** |
| Android | `cd mobile && bun install && npx expo run:android` (custom native module → **no Expo Go**) |
| Clipboard agent | rebuild dex with `native-src/clipboard-agent/build-dex.sh` only if `ClipboardAgent.java` changes |

First run: enter your relay in the Mac's **Server Settings…**, show the pairing QR, scan it on
the phone (the QR carries the server config, so the phone is configured in one scan), then open
Android's *Pair device with pairing code* dialog and enter the 6-digit code once.

---

## 13. Scope & roadmap

v1 links **one phone and one Mac** and syncs **text only** (images/files out of scope; the
256 KB payload cap reflects that — mirrored app icons are small base64 PNGs). Implemented: two-way
clipboard (end-to-end encrypted with ChaCha20-Poly1305), remote lock, proximity auto-lock,
**relay-less LAN-direct** mode (§5.1 — phone ↔ Mac over the local network with no relay,
auto-preferred over the relay on the same Wi-Fi), **bidirectional battery/identity telemetry**
(`stat`, Mac↔phone), **one-way notification mirroring** (`note`, phone → Mac; §5.2, surfaced
as a native banner + the dashboard's Notifications tab), and **one-way message (SMS) mirroring**
(`sms`, phone → Mac; §5.3, read-only conversation threads in the dashboard's Messages tab). On the
roadmap (`RoadMap.md`): screen mirroring, file transfer, replying to messages, and read-only access
to gallery/calls from the Mac.

---

## Appendix: file map

```
server/src/
  index.ts        HTTP+WS bootstrap, auth, per-conn wiring, shutdown
  relay.ts        room map, join/clip/cmd/stat/note forwarding, backpressure
  protocol.ts     frame types + validation
  ratelimit.ts    sliding-window limiter
  heartbeat.ts    ws ping/pong reaper
  config.ts       env config

mac/Sources/LinkToMac/
  LinkToMacApp.swift     MenuBarExtra + dashboard scene + AppDelegate
  RelayClient.swift      WS client, reconnect, cmd dispatch; owns the pasteboard + battery monitor, clip-history + notification rings + message store
  LanServer.swift        LAN-direct WS server (NWListener) + Bonjour + HMAC handshake (onRemoteStat/onRemoteNote/onRemoteSms)
  PasteboardWatcher.swift changeCount poll + echo stamp
  BatteryMonitor.swift   IOKit power-source poll → outbound stat (Mac's own battery)
  ClipCodec.swift        E2E payload encryption (ChaCha20-Poly1305 / CryptoKit)
  MacNotifier.swift      native banner for mirrored notes (UNUserNotificationCenter + icon attachment)
  ProximityMonitor.swift BLE central, RSSI → lock
  ProximityConfig.swift  UUID derivation + tunables
  ScreenLock.swift       SACLockScreenImmediate / CGSession
  Pairing.swift          room/key, Keychain, QR (v3 embeds server + LAN config)
  ServerSettings.swift   runtime relay endpoint store (UserDefaults + Keychain)
  ServerSettingsView.swift  "Server Settings…" window
  LoginItem.swift        SMAppService auto-start
  MenuPanel.swift        menu-bar M3 phone-identity card + last-copy glance
  DashboardWindow.swift / DashboardComponents.swift  dashboard window shell + shared M3 components
  PhonePanel.swift       phone identity: name, status, transport + battery chips
  ClipHistoryScreen.swift  clip history (recency groups, recopy, clear)
  FeaturePanel.swift     right-column tabs; Notifications tab renders the note ring, Messages tab renders conversation threads
  SettingsScreen.swift / AppearanceSettings.swift / AboutView.swift / RelayScreen.swift  settings/about/relay surfaces

mobile/modules/selfadb/android/.../selfadb/
  SelfAdbModule.kt          Expo module: autoStart/pair/relay/proximity APIs
  AdbManager.kt             libadb wrapper: pair/connect/discover/push/launch
  ClipboardAgent (java)     → built to assets/clipboard-agent.dex
  ClipForegroundService.kt  START_STICKY host for bridge+connection+BLE
  ClipBridge.kt             localhost NDJSON client to the daemon
  ConnectionManager.kt      LAN-preferred / relay-fallback link arbiter
  RelayClient.kt            OkHttp WS to the relay (sendClip/sendCmd/sendStat/sendNote)
  LanClient.kt              OkHttp WS straight to the Mac (LAN-direct) + HMAC handshake
  LanDiscovery.kt           NsdManager mDNS discovery of the Mac (rid-matched)
  NotificationListener.kt   NotificationListenerService → note frames (label + icon resolve, noise filter)
  SmsMirror.kt              FGS-owned SMS reader → sms frames (backfill + ContentObserver deltas, name resolve)
  BleAdvertiser.kt          BLE presence beacon
  ClipBus.kt                service ↔ module bridge + ring buffers
  ClipCodec.kt              E2E payload encryption (ChaCha20-Poly1305 / javax.crypto)

mobile/native-src/clipboard-agent/
  ClipboardAgent.java       the privileged daemon source
  build-dex.sh              javac → d8 → dex

mobile/src/features/
  selfadb/use-clip-boot.ts  boot state machine (JS gate)
  relay/pairing-store.ts    SecureStore pairing + v2 QR parse (pairing + server config)
  relay/server-config.ts    SecureStore relay endpoint (host/port/TLS/password)
  relay/use-mac-battery.ts  Mac battery (stat) hook → Home-screen chip
mobile/src/app/
  server-config.tsx         Relay server settings screen
```
