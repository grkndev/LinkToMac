# Link to macOS — Technical Reference

This document covers **how the system actually works** under the hood: the four
processes, the wire protocols between them, the three independent data paths
(clipboard, remote lock, proximity), and the platform tricks that make a
background clipboard sync possible on a stock Android phone.

It is the engineering companion to the user-facing [`README.md`](README.md). Where the
README says *"the Android app reads the clipboard through its own ADB"*, this document
explains the dex'd `app_process` daemon, the localhost NDJSON bridge, and the
`WRITE_SECURE_SETTINGS` self-grant that make it survive a reboot.

> **Honesty note up front:** clipboard payloads currently travel **base64-encoded, not
> encrypted**. The wire format, the pairing `key`, and a `ClipCodec` seam are all in place
> for libsodium secretbox, but the crypto is not wired up yet. See
> [§10 Security model](#10-security-model--current-limitations).

---

## 1. System overview

Four separate programs cooperate. Three of them are "yours" (you build/run them); the
fourth is a stock-Android system service the Android app talks to through a trick.

```
  ANDROID (phone)                         CLOUD                  macOS
  ┌───────────────────────────────┐                     ┌──────────────────────────┐
  │ Expo / React Native app (JS)  │                     │ SwiftUI menu-bar agent    │
  │   • UI, pairing, settings     │                     │   • NSPasteboard poll     │
  │   • drives native via Expo    │                     │   • URLSession WS client  │
  │     module (control plane)    │                     │   • CoreBluetooth central │
  │ ┌───────────────────────────┐ │   ┌─────────────┐   │   • SACLockScreen / QR    │
  │ │ Foreground Service (Kotlin)│ │   │  Node `ws`  │   │   • Keychain, login item  │
  │ │  • OkHttp WS → relay ──────┼─┼──►│   relay     │◄──┼── URLSessionWebSocketTask │
  │ │  • ClipBridge (localhost)  │ │   │ (room route)│   └──────────┬───────────────┘
  │ │  • BleAdvertiser           │ │   └─────────────┘              │
  │ └─────────┬─────────────────┘ │   forwards opaque              │
  │  connect  │ 127.0.0.1:53123   │   frames by roomId             │
  │ ┌─────────▼─────────────────┐ │   (no storage, no decrypt)     │
  │ │ ClipboardAgent (shell UID)│ │                                │
  │ │  app_process daemon       │ │                                │
  │ │  • IClipboard reflection  │ │                                │
  │ │  • ServerSocket NDJSON    │ │                                │
  │ └───────────────────────────┘ │                                │
  └───────────────┬───────────────┘                                │
                  └────────────── BLE presence beacon ─────────────┘
                       (proximity auto-lock — fully local, no relay)
```

### The three data paths

| Path | Transport | Touches the relay? | Direction |
|---|---|---|---|
| **Clipboard sync** | WebSocket `clip` frames | Yes | Both ways |
| **Remote lock** | WebSocket `cmd` frames | Yes | Phone → Mac |
| **Proximity auto-lock** | BLE advertisement | **No** (fully local) | Phone advertises → Mac decides |

The clipboard and lock paths share one relay connection per device. The proximity path is
completely independent — it works with no internet at all.

### Tech stack

| Component | Language / runtime | Key dependencies |
|---|---|---|
| `server/` | Node ≥ 20, TypeScript (ESM) | `ws`, `pino`, `dotenv` |
| `mac/` | Swift 6 (strict concurrency), SwiftUI | AppKit, CoreBluetooth, CryptoKit, Security, ServiceManagement — all system frameworks, **no third-party deps** |
| `mobile/` (JS) | Expo SDK 56, React Native 0.85, Expo Router, React 19 | `expo-secure-store`, `expo-camera`, `uniwind` |
| `mobile/modules/selfadb` (native) | Kotlin (Expo Module) | `libadb-android` 3.1.1, BouncyCastle, Conscrypt, OkHttp 4.12 |
| `clipboard-agent` | Java → dex | none (reflects into framework `IClipboard`) |

---

## 2. The relay server (`server/`)

A deliberately dumb pipe. It pairs the two ends of a *room* and forwards opaque frames
between them. It never stores anything and never inspects clipboard content.

### Connection lifecycle

1. Client connects to `ws://host:PORT/ws`, authenticated by a `RELAY_AUTH_TOKEN` passed as
   `Authorization: Bearer <token>` or `?token=`. The check uses `crypto.timingSafeEqual`
   (`server/src/index.ts`).
2. The first frame **must** be `join` (a `JOIN_TIMEOUT_MS`, default 10 s, drops silent
   sockets). `join` carries `{ room, device }` where `device` is `"android"` or `"mac"`.
3. The relay keeps an in-memory `Map<roomId, Map<device, Conn>>`. A room is capped at
   `MAX_PEERS_PER_ROOM` (default **2**).
4. **Newest-wins:** a reconnecting `android`/`mac` evicts its own stale connection (close
   code `4000`) rather than being rejected — this is what makes reconnect-after-sleep clean.
5. On join, the newcomer gets `{ t: "joined", peers: [...] }`; the existing peer gets
   `{ t: "peer", state: "online", device }`. Disconnect sends the symmetric `offline`.

### Forwarding rules (`server/src/relay.ts`)

- `clip` and `cmd` frames are `JSON.stringify`'d and sent **verbatim to the *other* peer
  only** — the sender never receives its own echo.
- `cmd.action` is treated as **opaque**: the relay forwards `"lock"` (or any future action)
  without interpreting it, so new remote commands never require a server change.
- **Backpressure:** if a peer's `ws.bufferedAmount` exceeds `maxPayloadBytes * 8`, it is
  declared a slow consumer and dropped (close code `4003`) instead of buffering unbounded.
- Logs are privacy-preserving: the `roomId` is redacted to a 6-char prefix, and only
  *ciphertext length* + fan-out count are recorded — never `nonce`/`ct`.

### Hardening

- Per-connection **sliding-window rate limit** (`RATE_LIMIT_MSGS` / `RATE_LIMIT_WINDOW_MS`,
  default 120 / 10 s; `server/src/ratelimit.ts`).
- `maxPayload` of 256 KB enforced at the `ws` layer; binary frames rejected.
- ws-level **ping/pong heartbeat** (`PING_INTERVAL_MS`, default 30 s) with dead-connection
  reaping (`server/src/heartbeat.ts`).
- `GET /health` returns `{ status, rooms, conns, uptimeSec }`.
- Graceful `SIGTERM`/`SIGINT` shutdown (close code `1001`, 3 s force-exit).

### Deployment

Ships as a Docker image (`server/Dockerfile`, `docker-compose.yml`) serving **plain `ws`**.
TLS (`wss`) is terminated by a reverse proxy — the README shows Caddy (automatic Let's
Encrypt) and Nginx configs. Public endpoint becomes `wss://<domain>/ws`.

> **Current reality:** both clients connect over plain `ws://` (not `wss://`). The host +
> bearer token are **not** in tracked source: the Mac reads them from `Config.xcconfig` →
> `Secrets.xcconfig` (gitignored) → Info.plist → `Config.swift`, and the phone reads them
> from a gitignored `.env` via `app.config.ts` → `expoConfig.extra` → `relay-config.ts`.
> Productionizing means moving to `wss://`; the secret-injection seam is already in place.

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
  --nice-name=linktomac_clip com.grkndev.clipboard.ClipboardAgent 53123
```

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
  - daemon → app: `{"type":"clip","text":"…","ts":1234}`
  - app → daemon: `{"cmd":"write","text":"…"}`
- A `lastSeen` string suppresses the echo of the agent's *own* writes.

**Detached-daemon trick (the key to survival):** the launch command is wrapped in
`nohup setsid sh -c '…' >log 2>&1 </dev/null &`. `setsid` puts it in a new session so adbd's
process-group kill can't reach it; `nohup` ignores `SIGHUP`; stdio is detached. Result: the
daemon **survives ADB disconnect, Wireless Debugging being turned off, and the app being
killed.** Only a reboot, a crash, or an explicit `killDaemon()` stops it. ADB is needed only
to *launch* (or relaunch) it — never for the steady-state data path.

### 3.4 The bridge + foreground service (`ClipBridge.kt`, `ClipForegroundService.kt`)

- **`ClipBridge`** is the on-device localhost *client* to the daemon. It connects to
  `127.0.0.1:53123`, retries with backoff until the daemon's `ServerSocket` is up, reads
  `clip` lines, and writes `write` commands.
- **`ClipForegroundService`** owns the bridge, the relay WS client, and the BLE advertiser. It
  runs as a **`START_STICKY` foreground service** with type `specialUse|connectedDevice`
  (Android 14+ requires a declared type). Because it's `START_STICKY`, the system restarts it
  with a null intent after a kill, and `onStartCommand` re-reads persisted config
  (`SharedPreferences`) and reconnects everything **with no JS runtime present**.
- Echo suppression on the Android side: when a clip arrives from the Mac, the service records
  it as `lastWritten` and writes it to the device clipboard; the resulting `onClip` from the
  daemon is recognized and swallowed.
- A `sendPaused` flag gates **outbound** (Mac-bound) forwarding only — inbound clips from the
  Mac still arrive while paused. This backs the *"pause sending from the phone"* setting.

### 3.5 Relay client + BLE beacon (Android)

- **`RelayClient.kt`** is an OkHttp `WebSocket`. It joins as `"android"`, uses OkHttp's native
  `pingInterval` (20 s) for keepalive, and reconnects with exponential backoff capped at 30 s.
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
probe localhost:53123 ── alive ──────────────────────────────────► "ready"   (attach, no ADB)
        │ dead
   isPaired()? ── no ──────────────────────────────────────────► "need-pair"
        │ yes
   self-enable Wireless Debugging (if WRITE_SECURE_SETTINGS held)
        │
   mDNS discover _adb-tls-connect ── not found ────────────────► "need-connect"
        │ found
   connect ── AdbPairingRequiredException ─────────────────────► "need-pair"  (re-pair gate)
        │ ok
   deploy (push dex if needed + launch daemon) → start service → "ready"
```

The JS hook (`useClipBoot`) wraps the native call in a **20 s timeout** because ADB's TLS
connect and exec streams have no internal deadline and a half-trusted adbd can stall forever.
A timeout is treated as "paired but stuck" → routed to the recoverable reconnect screen, and
the hook re-runs `autoStart` whenever the app returns to the foreground (covers the user
toggling Wireless Debugging in system settings).

### 3.7 The JS ↔ native seam (`ClipBus.kt`)

The Expo module only exists while the JS runtime is alive; the foreground service outlives it.
**`ClipBus`** is the process-wide bridge: the service always posts events here, and the module
attaches/detaches its `onClip` / `onMacClip` / `onLog` / `onRelay` callbacks in
`OnCreate`/`OnDestroy`. It also holds bounded ring buffers — 400 log lines and 100 Mac-clip
entries — so the Logs and Clipboard-History screens can show events that happened *before* the
JS runtime attached (e.g. an FGS reconnect while the app was swiped away). `lastRelay` lets a
late-attaching UI query current relay status immediately.

---

## 4. macOS: the menu-bar agent (`mac/`)

A SwiftUI `MenuBarExtra` (`.window` style, so the dropdown is a real panel with switches, not
a plain menu). No Dock icon. Swift 6 with complete strict concurrency; everything observable is
`@MainActor`-isolated and async loops hop back to the main actor on each step. **Zero
third-party dependencies** — only system frameworks. Built reproducibly from `project.yml` via
XcodeGen, ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`, hardened runtime off) so it runs locally
without a Developer team.

| File | Role |
|---|---|
| `RelayClient.swift` | `URLSessionWebSocketTask` to the relay; join, ping/pong, presence, reconnect |
| `PasteboardWatcher.swift` | Polls `NSPasteboard.changeCount`; echo suppression |
| `ClipCodec.swift` | base64 placeholder codec (crypto seam) |
| `ProximityMonitor.swift` | CoreBluetooth central; RSSI → lock decision |
| `ScreenLock.swift` | Locks the screen |
| `Pairing.swift` | Room/key generation, Keychain, QR rendering |
| `LoginItem.swift` | `SMAppService` auto-start at login |
| `MenuPanel.swift` / `PairingView.swift` | UI |

### 4.1 RelayClient (Swift)

`@Observable`, `@MainActor`. Uses a monotonic **`generation` counter** so that loops belonging
to a replaced socket bail out instead of corrupting current state — important since
receive/heartbeat run as detached `Task`s. App-level ping every 25 s; exponential backoff
reconnect capped at 30 s. Joins as `"mac"`. On a received `clip` it writes to the pasteboard;
on a `cmd` it dispatches to a handler (currently only `"lock"`). A persisted `sendToAndroid`
flag is the Mac-side equivalent of the phone's pause toggle.

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

JSON text frames over WebSocket. The relay reads control frames but treats `clip`/`cmd`
payloads as opaque. Defined in `server/src/protocol.ts`, mirrored by `RelayProtocol.swift`
(Mac) and inline `JSONObject` building in `RelayClient.kt` (Android).

```jsonc
// client → relay
{ "t": "join", "room": "<roomId>", "device": "android" | "mac" }
{ "t": "clip", "nonce": "<base64>", "ct": "<base64>" }   // forwarded verbatim
{ "t": "cmd",  "action": "lock" }                         // forwarded verbatim, action ≤ 32 chars
{ "t": "ping" }

// relay → client
{ "t": "joined", "peers": ["mac"] }
{ "t": "peer",   "state": "online" | "offline", "device": "mac" }
{ "t": "clip",   "nonce": "...", "ct": "..." }            // the peer's frame, relayed
{ "t": "cmd",    "action": "lock" }
{ "t": "error",  "code": "room-full" | "bad-join" | "not-joined" | "rate-limit"
                       | "join-timeout" | "bad-message", "message": "..." }
{ "t": "pong" }
```

`room` is validated to 16–128 chars (the base64 of 32 random bytes is 44). Malformed frames
get a `bad-message` error and are dropped.

---

## 6. Clipboard sync — end to end

**Phone → Mac (copy on Android):**

1. The user copies. The system fires `dispatchPrimaryClipChanged` into `ClipboardAgent`'s
   proxy binder.
2. The agent reads the clip and emits `{"type":"clip", …}` over localhost to `ClipBridge`.
3. The foreground service checks it isn't the echo of its own write, records history, and
   (unless `sendPaused`) calls `RelayClient.sendClip`.
4. `ClipCodec.encode` → `{ t:"clip", nonce, ct }` → relay → Mac.
5. The Mac decodes `ct`, stamps `lastChangeCount`, and writes `NSPasteboard`.

**Mac → Phone (copy on macOS):**

1. `PasteboardWatcher` poll sees a new `changeCount`, reads the string.
2. `RelayClient.sendClip` → `{ t:"clip", … }` → relay → phone.
3. The Android service records the text as `lastWritten`, writes it through the bridge → the
   daemon's `setPrimaryClip`. The agent's resulting change event is swallowed via `lastSeen`,
   and the service's own `onClip` is swallowed via `lastWritten` — **double echo suppression**
   because the write traverses two echo-producing boundaries.

Loop prevention is **per-boundary echo stamping** (not the version-vector/seq scheme sketched
in `workflow.md` — the implementation uses the simpler stamp because the relay never echoes to
the sender, so only local write-backs need suppressing).

---

## 7. Remote lock — end to end

1. The user taps **Lock Mac** on the phone's Home screen.
2. JS calls `SelfAdb.sendCommand("lock")` → the foreground service's `RelayClient.sendCmd` →
   `{ t:"cmd", action:"lock" }`.
3. The relay forwards it verbatim to the `mac` peer.
4. The Mac's `RelayClient` routes `cmd("lock")` to `ScreenLock.lock()`.

The lock path is intentionally kept **off the clipboard path** and the `pause sending` toggle
doesn't affect it. Because the relay forwards `action` opaquely, adding new remote commands is
a client-only change.

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

macOS has no API to auto-*unlock*, so this is lock-only by design.

---

## 9. Pairing & key management

The **Mac is the pairing initiator**. On first launch (`PairingStore.loadOrCreate`) it
generates:

- `room` — base64 of 32 random bytes; the relay bearer / room id.
- `key` — base64 of 32 random bytes; the future E2E secret.

Both are stored in the macOS **Keychain** (generic-password item). The Mac shows a QR encoding
`{"v":1,"room":"…","key":"…","name":"<computer name>"}` via CoreImage's `CIQRCodeGenerator`
(`Pairing.swift`).

The phone scans it with `expo-camera`, validates it (`parsePairingQR`), and stores it in
**`expo-secure-store`** (Android Keystore-backed). The room/token are then pushed into the
native service via `setRelay`, which persists them to `SharedPreferences` so the
`START_STICKY` service can reconnect without JS.

**Unpair** on the Mac deletes the Keychain item, mints a fresh room/key, and reconnects into
the new (empty) room — leaving the old phone stranded in the abandoned room. The rotated room
also rotates the BLE UUID, so proximity stops matching the old device automatically.

> Note there are **two distinct pairings**: the phone↔Mac *relay* pairing (room/key, above)
> and the phone↔adbd *self-ADB* pairing (RSA key + cert in the app's `filesDir`, §3.1). They
> are independent and fail independently.

---

## 10. Security model & current limitations

**What holds today:**

- The relay is a dumb pipe: it never stores content and never parses `nonce`/`ct`.
- `roomId` is an unguessable 256-bit bearer; `RELAY_AUTH_TOKEN` is a second gate so strangers
  can't even open sockets. Per-room cap of 2, rate limiting, and payload caps limit abuse.
- Secrets live in the platform secure stores (Keychain / Keystore-backed SecureStore).
- Proximity is BLE-only and never touches the network.
- Remote lock uses no entitlement and can't *unlock*.

**What does NOT hold yet (be explicit about this):**

- 🔴 **No end-to-end encryption.** `ClipCodec` on all three sides is a placeholder:
  `ct = base64(utf8(text))` and `nonce` is random filler so the wire shape already matches
  secretbox. The pairing `key` is carried but **unused**. Anyone who can read the relay's
  traffic (or runs the relay) can read clipboard content. The seam is designed so that
  swapping in **libsodium secretbox** touches only `ClipCodec.{swift,kt,ts}`.
- 🟠 **Transport is plain `ws`.** Both clients use `ws://<host>:<port>`, not `wss://`. TLS
  exists only if you put the relay behind the documented reverse proxy and repoint the clients.
- 🟢 **Relay host + token are out of tracked source.** They're injected at build time from
  gitignored files (`mac/Secrets.xcconfig`, `mobile/.env`) — see §12. Rotating the token is a
  one-line change in those files plus `server/.env`. Note the *old* token still lives in git
  history, so a rotation is only complete once the relay restarts with the new one.
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

Each component reads its relay host + token from a **gitignored** secret file you create once
from a committed template:

| Component | Secret file (gitignored) | Template |
|---|---|---|
| Relay | `server/.env` | `server/.env.example` |
| Mac | `mac/Secrets.xcconfig` | `mac/Secrets.example.xcconfig` |
| Android | `mobile/.env` | `mobile/.env.example` |

All three carry the same `RELAY_AUTH_TOKEN` (generate with `openssl rand -hex 32`). The Mac
flows it through `Config.xcconfig` → Info.plist → `Config.swift`; the phone through
`app.config.ts` → `expoConfig.extra` → `relay-config.ts`. A fresh checkout still generates and
builds without the secret files — it just connects with non-working placeholders.

| Component | Command |
|---|---|
| Relay | `cd server && cp .env.example .env && npm install && npm run dev` (or `docker compose up -d`) |
| Mac | `cd mac && cp Secrets.example.xcconfig Secrets.xcconfig && xcodegen generate && open LinkToMac.xcodeproj` → Run |
| Android | `cd mobile && cp .env.example .env && bun install && npx expo run:android` (custom native module → **no Expo Go**) |
| Clipboard agent | rebuild dex with `native-src/clipboard-agent/build-dex.sh` only if `ClipboardAgent.java` changes |

First run: show the pairing QR from the Mac's menu bar, scan it on the phone, open Android's
*Pair device with pairing code* dialog, and enter the 6-digit code once.

---

## 13. Scope & roadmap

v1 links **one phone and one Mac** and syncs **text only** (images/files out of scope; the
256 KB payload cap reflects that). Implemented: two-way clipboard, remote lock, proximity
auto-lock. On the roadmap (`RoadMap.md`): **E2E encryption (libsodium secretbox)**, notification
sync, screen mirroring, file transfer, and read-only access to gallery/messages/calls from the
Mac.

---

## Appendix: file map

```
server/src/
  index.ts        HTTP+WS bootstrap, auth, per-conn wiring, shutdown
  relay.ts        room map, join/clip/cmd forwarding, backpressure
  protocol.ts     frame types + validation
  ratelimit.ts    sliding-window limiter
  heartbeat.ts    ws ping/pong reaper
  config.ts       env config

mac/Sources/LinkToMac/
  LinkToMacApp.swift     MenuBarExtra + AppDelegate
  RelayClient.swift      WS client, reconnect, cmd dispatch
  PasteboardWatcher.swift changeCount poll + echo stamp
  ClipCodec.swift        base64 placeholder (crypto seam)
  ProximityMonitor.swift BLE central, RSSI → lock
  ProximityConfig.swift  UUID derivation + tunables
  ScreenLock.swift       SACLockScreenImmediate / CGSession
  Pairing.swift          room/key, Keychain, QR
  LoginItem.swift        SMAppService auto-start

mobile/modules/selfadb/android/.../selfadb/
  SelfAdbModule.kt          Expo module: autoStart/pair/relay/proximity APIs
  AdbManager.kt             libadb wrapper: pair/connect/discover/push/launch
  ClipboardAgent (java)     → built to assets/clipboard-agent.dex
  ClipForegroundService.kt  START_STICKY host for bridge+relay+BLE
  ClipBridge.kt             localhost NDJSON client to the daemon
  RelayClient.kt            OkHttp WS to the relay
  BleAdvertiser.kt          BLE presence beacon
  ClipBus.kt                service ↔ module bridge + ring buffers
  ClipCodec.kt              base64 placeholder (crypto seam)

mobile/native-src/clipboard-agent/
  ClipboardAgent.java       the privileged daemon source
  build-dex.sh              javac → d8 → dex

mobile/src/features/
  selfadb/use-clip-boot.ts  boot state machine (JS gate)
  relay/pairing-store.ts    SecureStore pairing + QR parse
  relay/relay-config.ts     relay host/port/token resolution
```
