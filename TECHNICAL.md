# Link to macOS — Technical Reference

This document covers **how the system actually works** under the hood: the four
processes, the wire protocols between them, the data paths (clipboard, files and folders,
remote lock, telemetry, notification and message mirroring, proximity), and the platform
tricks that make a background clipboard sync possible on a stock Android phone.

The per-directory guides (`mac/CLAUDE.md`, `mobile/CLAUDE.md`, `server/CLAUDE.md`) carry the
file-by-file detail; this document is the *why* and the cross-component contracts. The wire
formats that are mirrored by hand in two languages are additionally pinned by shared test
vectors in [`protocol-vectors/`](protocol-vectors/README.md).

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
  │ Expo / React Native app (JS)   │                     │ SwiftUI menu-bar + window │
  │   • UI, pairing, settings,     │                     │   • NSPasteboard poll     │
  │     Files screen               │                     │   • LAN WS server (NWList)│
  │   • drives native via Expo     │                     │   • CoreBluetooth central │
  │ ┌────────────────────────────┐ │   ┌─────────────┐   │   • SACLockScreen / QR    │
  │ │ Foreground Service (Kotlin)│ │   │  Node `ws`  │   │   • Keychain, Sparkle     │
  │ │  • OkHttp WS → relay ──────┼─┼──►│   relay     │◄──┼── • URLSession WS client  │
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
| **Clipboard sync** | WebSocket `clip` frames (images: `file`) | Yes — *or* LAN-direct (§5.1) | Both ways |
| **Files and folders** | WebSocket `file` frames, chunked + acked (§5.4) | Yes — *or* LAN-direct (§5.1) | Both ways |
| **Remote lock** | WebSocket `cmd` frames | Yes — *or* LAN-direct (§5.1) | Phone → Mac |
| **Battery telemetry** | WebSocket `stat` frames | Yes — *or* LAN-direct (§5.1) | Both ways (Mac↔Phone) |
| **Notification mirroring** | WebSocket `note` frames | Yes — *or* LAN-direct (§5.1) | Phone → Mac |
| **Message (SMS) mirroring + replies** | WebSocket `sms` frames | Yes — *or* LAN-direct (§5.1) | Phone → Mac (mirror); Mac → phone (reply request), phone → Mac (ack) |
| **App updates** | Sparkle appcast (Mac) / GitHub "latest release" API (Android) | No — GitHub | GitHub → app |
| **Proximity auto-lock** | BLE advertisement | **No** (fully local) | Phone advertises → Mac decides |
| **Proximity distance** | BLE measure → `stat` frame | Yes — *or* LAN-direct (§5.1) | Mac measures → Phone shows |

The clipboard, file, lock, telemetry, notification, and message paths share one connection per
device — the relay, or, on the same network, a **direct link to the Mac** with no relay (§5.1). The
proximity path is completely independent — it works with no internet at all.

### Tech stack

| Component | Language / runtime | Key dependencies |
|---|---|---|
| `server/` | Node ≥ 20, TypeScript (ESM) | `ws`, `pino`, `dotenv` |
| `mac/` | Swift 6 (strict concurrency), SwiftUI + AppKit | AppKit, Network (`NWListener`), CoreBluetooth, CryptoKit, Security, ServiceManagement, UserNotifications, IOKit — system frameworks; the **only third-party dependency is Sparkle** (auto-update) |
| `mobile/` (JS) | Expo SDK 56, React Native 0.85, Expo Router, React 19 | `@expo/ui` (Jetpack Compose), `expo-secure-store`, `expo-camera`, `expo-updates`, `react-native-keyboard-controller`, `uniwind` |
| `mobile/modules/selfadb` (native) | Kotlin (Expo Module) | `libadb-android` 3.1.1, BouncyCastle, Conscrypt, OkHttp 4.12 |
| tests | swift-testing (`mac/Tests`), JUnit 4 (`…/selfadb/android/src/test`) | `protocol-vectors/` run by both |
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

- `clip`, `cmd`, `stat`, `note`, `sms`, and `file` frames are `JSON.stringify`'d and sent **verbatim
  to the *other* peer only** — the sender never receives its own echo.
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
- `sms` carries an **opaque mirrored SMS batch/delta** (phone → Mac); same additive, opaque fan-out.
- `file` carries **opaque clipboard images and opaque file/folder transfers, both bidirectional**:
  the same additive, opaque fan-out. The relay never sees a name, a size or a byte of a file; what
  matters to it is that frames are ≤ 1 MiB (`maxPayloadBytes`), that a peer buffering more than
  `maxPayloadBytes * 8` is dropped, and that a connection is limited to 120 frames / 10 s — which is
  why the senders chunk, window and pace (§5.4). The plaintext format, chunking, acks, resume and
  the folder/size rules are specified in §5.4.
- **Backpressure:** if a peer's `ws.bufferedAmount` exceeds `maxPayloadBytes * 8`, it is
  declared a slow consumer and dropped (close code `4003`) instead of buffering unbounded.
- Logs are privacy-preserving: the `roomId` is redacted to a 6-char prefix, and only
  *ciphertext length* + fan-out count are recorded — never `nonce`/`ct`.

### Hardening

- Per-connection **sliding-window rate limit** (`RATE_LIMIT_MSGS` / `RATE_LIMIT_WINDOW_MS`,
  default 120 / 10 s; `server/src/ratelimit.ts`).
- `maxPayload` of 1 MiB enforced at the `ws` layer (fits an E2E-encrypted clipboard image ~700 KB
  raw after base64); binary frames rejected.
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
> time. The Mac stores them via **Settings ▸ Relay Server** (`ServerSettings.swift`: UserDefaults +
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
killed.** ADB is needed only to *launch* (or relaunch) it — never for the steady-state data path.

**Supervisor loop (issue #31):** `nohup setsid` does nothing against **lmkd/One UI memory
kills**, which take the ~50 MB Java daemon down *without a reboot* (seen in the field on One UI).
So the `sh -c '…'` body is not the bare `app_process` line but a tiny watchdog:
`: linktomac_sup_<port>; while :; do app_process …; <backoff>; done`. The 1–2 MB `sh` supervisor
is a far less attractive lmkd target; when the daemon dies it relaunches it **with the same port
and secret — no ADB, no Wi-Fi, no user** (the FGS bridge retries every 3 s, so sync self-heals
end to end). Healthy runs (≥ 30 s) respawn in 3 s; fast deaths back off 6→12→…→120 s and the
supervisor **gives up after 10 consecutive fast exits** (bad dex / stolen port — `deploy()`'s
self-heal owns that case and re-arms it). Its log lines are prefixed `supervisor:` and never
contain `listening`, so the launch gate can't false-fire. Only a reboot or `killDaemon()` stops
the pair for good. Three contracts around it (all verified on-device):
- **Two-stage kill, supervisor first**: `killDaemon(port)` = `pkill -f 'linktomac_su[p]_<port>'`
  then `pkill -xf 'linktomac_cli[p]'` — a dead supervisor can't resurrect the daemon it just
  lost. The `[]` bracket trick means a shell whose own cmdline contains the pattern text never
  matches itself. The daemon is matched by **exact cmdline** (`--nice-name` replaces argv with
  the bare `linktomac_clip`; its comm stays `main` on One UI, so `pgrep -x` won't find it), which
  spares the *other* variant's supervisor — the marker is **port-scoped** (dev `53125` / prod
  `53123`) so the two installs can't kill each other's supervisor.
- **Launch is self-cleaning, via a separate exec**: `launchDaemon` calls `killDaemon` first in
  its own exec session — `deploy()` launches without killing when the daemon is dead, and a
  leftover supervisor mid-backoff would resurrect the old daemon to duel the new one over the
  port bind. The kill can't ride inline in the launch cmd: the supervisor script (raw marker
  included) is part of that shell's own cmdline, so an inline pkill would kill the launcher
  itself.
- The supervisor script rides inside `sh -c '…'`: **no single quotes** in the body, POSIX
  arithmetic + toybox `date +%s` only.

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

- **`ClipBridge`** is the on-device localhost *client* to the daemon. It connects to the
  per-variant clip port (dev `53125` / prod `53123` — `app.config.ts extra.clipPort`, persisted
  natively as `KEY_CLIP_PORT`), retries with backoff until the daemon's `ServerSocket` is up,
  sends the `auth` line first (the persisted daemon secret — see §3.3), then reads `clip` lines
  and writes `write` commands. `stop()` closes the socket (an `interrupt()` can't unblock a
  parked `readLine()`), and every exit path closes the per-iteration socket so an abnormal read
  error can't leak the fd. The daemon serves connections on **per-connection handler threads
  with newest-wins eviction**: a freshly authenticated bridge replaces (closes) the previous
  live connection, so a wedged old connection can never lock a restarted bridge out.
- **Flap detection**: the backoff only resets after a connection *survives* ≥ 3 s — a daemon
  that accepts-then-drops the bridge (wrong secret, or another install's client evicting ours;
  both happen when two installs share a daemon) no longer produces a silent 500 ms
  "bridge connected" spam loop. Three consecutive short-lived drops = **flapping**: the bridge
  logs the reason once, backs off to 15 s, and `isDaemonAlive` starts reporting `false` so the
  JS heartbeat triggers `autoStart`, whose fast path and `deploy()` both treat a flapping
  bridge as "daemon not ours" and **kill + relaunch it under our secret** (self-heal, no
  reboot needed). A **supervisor respawn is not a flap**: the respawned daemon runs under our
  persisted secret, so the reconnected bridge survives ≥ 3 s and the streak resets. A
  never-binding crash-loop (bad dex) shows as ECONNREFUSED — not accept-then-drop — and the
  same heartbeat→redeploy self-heal clears the crash-looping supervisor too (its kill is part
  of every launch).
- **`ClipForegroundService`** owns the bridge, the link to the Mac (`ConnectionManager` → relay
  and/or LAN), the BLE advertiser, the SMS mirror, and the whole file-send pipeline (§3.8). It
  runs as a **`START_STICKY` foreground service** with type `specialUse|connectedDevice`
  (Android 14+ requires a declared type). Because it's `START_STICKY`, the system restarts it
  with a null intent after a kill, and `onStartCommand` re-reads persisted config
  (`SharedPreferences`) and reconnects everything **with no JS runtime present**.
- Echo suppression on the Android side: when a clip arrives from the Mac, the service stamps
  it into a **time-bounded recent-writes map** (10 s window, consumed on match — a single slot
  bounced rapid A-then-B sequences back to the Mac) and writes it to the device clipboard; the
  resulting `onClip` from the daemon is recognized and swallowed.
- There is no send gate on the phone any more: every captured clip is forwarded. (A "Send copies"
  / "Send images" pair of switches used to live in the phone's Settings; they were removed as
  unneeded. The Mac keeps its own outbound switches.)
- **Clipboard images (`file`, bidirectional):**
  - *Mac → phone (inbound):* `applyFile` decodes the frame's `u16 header-len ‖ header JSON ‖ raw
    bytes` plaintext, writes the image to `cacheDir/clips`, and puts it on the system clipboard as a
    `${applicationId}.selfadb.fileprovider` **content URI** via `ClipboardManager.setPrimaryClip` —
    **directly, not through the shell daemon** (a background clipboard *write* is permitted; the
    daemon holds no read grant to our provider).
  - *phone → Mac (outbound):* a copied image is a `content://` URI on the clipboard, not text. The
    shell daemon can't resolve it without a `ContentResolver`, so it lazily builds a **system
    Context** — a bare `ActivityThread` instance + `getSystemContext()` (deliberately *not*
    `systemMain()`, which would re-prepare the main Looper the daemon already owns) — and reads the
    bytes via `openInputStream`; the clipboard read-grant follows the shell `getPrimaryClip` caller.
    It emits `{"type":"image",…}` over the bridge; `captureImage` fits the bytes under the frame
    budget (`fitImage`) and sends a `file` frame via `conn.sendFile`. Fails soft: if the Context
    can't be built on some OEM build, text sync is unaffected and images are simply skipped.
  - *Confused-deputy guard (outbound, issue #32):* the daemon runs as **shell (uid 2000)** and its
    provider read uses shell's ambient privilege — which can over-read providers a normal app can't
    (MediaStore, Contacts, …). A hostile co-installed app could `setPrimaryClip` a forged `image/*`
    clip pointing at such a URI and have the daemon read + sync it to the Mac. So before reading an
    image URI, the daemon resolves **who set the clip** (`IClipboard.getPrimaryClipSource`) and only
    proceeds if that source could itself read the URI — checked three ways: (1) an explicit URI grant
    or a static provider `readPermission` the source holds (`Context.checkUriPermission`), (2) the
    source **owns** the backing provider (its own FileProvider), or (3) for MediaStore
    (`content://media/…`, which enforces `READ_MEDIA_*` *dynamically* and exposes no static
    permission for (1) to see) the source holds a media read grant. This blocks privilege
    *escalation* only — an app that could already read the content itself is allowed (a plain gallery
    copy lands in case 3). **Fails closed:** if the source or its access can't be determined, the
    image is skipped (text sync unaffected). Our own Mac→phone writes are skipped earlier by the
    `*.selfadb.fileprovider` authority check, so they never reach this guard.
  - *Echo:* the Mac→phone write lands on the clipboard, the daemon re-reads it, and would bounce it
    back — so `applyFile` stamps the raw bytes' **SHA-256** in `recentImageWrites` and `captureImage`
    drops the matching re-capture (the image analogue of the text `recentWrites` map). The outbound
    path forwards unconditionally.

### 3.5 Relay client + BLE beacon (Android)

- **`RelayClient.kt`** is an OkHttp `WebSocket`. It joins as `"android"`, uses OkHttp's native
  `pingInterval` (50 s — under the relay front-proxy's 60 s WS idle timeout, tuned to minimise
  mobile radio wakeups; matches the server's own heartbeat) for keepalive, and reconnects with
  exponential backoff capped at 30 s.
  All state runs on a single-thread executor; late OkHttp callbacks after shutdown are dropped
  rather than crashing (a `RejectedExecutionException` guard — this was a real "crash on pause"
  bug). It sends `clip`, `cmd`, `stat`, `note`, `sms` and `file` frames and hands every received one
  to the service (clips, `file` chunks/acks, `sms` reply requests). `LanClient.kt` is its
  LAN-direct twin (§5.1); `ConnectionManager.kt` keeps exactly one of them joined.
- **`BleAdvertiser.kt`** advertises a **non-connectable** BLE beacon whose only payload is a
  128-bit service UUID derived from the pairing room (see §8). Balanced advertise mode, medium
  TX power. Presence *is* the entire signal — there's no connection or data exchange.

### 3.6 Capture bring-up (`SelfAdbModule.autoStart` + `use-clip-boot.ts`)

**ADB is a capability, not a boot phase.** The self-ADB pipeline buys exactly one thing:
*automatic* clipboard capture, i.e. background clipboard **reads**, which AOSP focus-gates
(§3.3). Nothing else in the app needs it — the relay/LAN link, remote lock, telemetry,
notification + SMS mirroring, and even Mac→phone clipboard and images all run without it. So
`autoStart` runs in the background and its result is *reported*, never routed on: the only route
gate left in `_layout.tsx` is the Mac (relay) pairing. `use-clip-boot.ts` maps the native string
onto a `CaptureState` (`starting` | `live` | `needs-setup` | `pairing` | `error`) plus a
`CaptureSetupReason` (`never-paired` | `debugging-unreachable`). A degraded state is reported in
exactly one place — the Settings ▸ "Automatic capture" row, which opens `adb-setup`, now an
ordinary sub-screen with a header and a working back button. No banner and nothing on Home:
capture being off doesn't warrant interrupting the main screen.

This matters because the old full-screen gate was unescapable exactly where ADB is impossible:
Wireless Debugging needs a Wi-Fi *client* connection, so on Mobile Hotspot it can never come up
(issue #29), and adbd silently drops key trust across a Samsung reboot — which `isPaired()`, a
local key-file check, can't see (§3.1). A working phone↔Mac link was being held hostage by both.

When automatic capture is down, capture degrades rather than stopping: `ProcessTextActivity`
(the text-selection toolbar entry) and `ClipboardReadActivity` (the sticky notification's "Send
clipboard" action) both cost one tap and need no ADB, no Wi-Fi and no permission. Every path —
daemon or manual — funnels through `ClipForegroundService.ingestClip(text, ts, source)`, which
owns echo suppression and the clip history (§6).

`autoStart` therefore starts the **foreground service first**, before touching ADB at all
(and `setRelay` starts it too when the service is down, so a fresh QR pair connects immediately
rather than at the next launch). Previously the FGS was started only on the two ADB *success*
paths, which was invisible behind the old gate and became a total connection failure the moment
the gate was removed.

One `autoStart(clipPort)` call still drives the whole bring-up and returns a state string:

```
poll daemonAlive (≤2.4s, issue #29) ─ alive + secret known + not flapping ─► "ready" (no ADB)
        │ still dead after the grace window (or alive w/ unknown secret / flapping bridge)
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

**Fast-path grace window (issue #29):** step 1 isn't a single instant snapshot — a cold app
launch races the FGS's own `START_STICKY` restart + bridge reconnect, so one bad-luck sample
can lose that race even though the daemon is already up and just hasn't finished (re)attaching
the bridge yet. `autoStart` polls `daemonAlive()` every 300 ms for up to 2.4 s before falling
through to the ADB path — cheap, and small next to the 20 s JS-side ceiling below. This matters
most on **Mobile Hotspot**, where losing the race is unrecoverable: Wireless Debugging can never
come up while the phone is a Wi-Fi *access point* rather than a *client*, so falling into the
ADB path there used to strand the user on a Reconnect screen forever even though the FGS-owned
relay/LAN link, remote lock, and battery/notification/SMS mirroring were all working fine behind
it. That whole class of dead end is gone: the root layout no longer gates on ADB **at all** (its
only gate is the Mac pairing), so every capture state renders the app normally. See "Capture
bring-up" above.

The JS hook (`useClipBoot`) wraps the native call in a **20 s timeout** to flip the UI even
though the native call can (legitimately) still be running. **`adb.connect()` itself is bounded
too (issue #30):** a preflight raw-TCP `Socket.connect(addr, timeoutMs)` (12 s) catches a
half-up adbd that never completes the TCP handshake (Mobile Hotspot, Samsung right after a
Wireless-Debugging toggle), then `AbsAdbConnectionManager.setTimeout()` (12 s) bounds the ADB
protocol handshake wait — safe to bound because libadb runs that handshake on **its own**
persistent thread and the calling thread only waits on a deadline, so this can't repeat the
`d21e16e` regression (that one wrapped the *whole* call, including the raw-TCP phase, in a
throwaway Kotlin thread whose exit broke the connection). Before this, a stalled `connect()` had
no deadline at all: the busy gate in `use-clip-boot.ts` intentionally outlives the 20 s UI
timeout (so a second `autoStart` can't interleave on the shared `AdbManager` — issue #5's
failure class) but never freed, and **Try Again went dead** — no spinner, no retry, forever.
`refreshing` (exposed by `useClipBoot`) now drives the button's spinner/disabled state so an
in-flight retry never looks like a no-op. A timeout is treated as "paired but stuck" → routed to
the recoverable reconnect screen, and the hook re-runs `autoStart` whenever the app returns to
the foreground (covers the user toggling Wireless Debugging in system settings).

> **`adb.connect()` returns `false` only when a session is already live** (libadb's
> `isConnected()` guard) — it is *never* a genuine failure, which always **throws**
> (`AdbPairingRequiredException` / `IOException`). The `AdbManager` is one instance for the
> JS-runtime lifetime, so a link from an earlier `pairAuto`/`autoStart` can still be open here
> — and stale if Wireless Debugging was toggled since. `autoStart` reaches this branch only
> with a **dead daemon it must redeploy**, so it `disconnect()`s any existing session first and
> reconnects fresh. Treating `false` as a failure (the original bug, issue #5) threw "connect
> failed despite mDNS endpoint" and skipped the redeploy, looping the reconnect screen after a
> successful re-pair. Don't reintroduce a `throw` on `connect()==false`.

**Every ADB-touching `AsyncFunction` runs on its own single-thread queue, not Expo's shared
one (issue found 2026-08-01).** `expo-modules-core` dispatches every module's default-queue
`AsyncFunction` — including `expo-secure-store`'s — onto one shared HandlerThread
(`expo.modules.AsyncFunctionQueue`, `AppContext.modulesQueue`). Before this fix, a stalled
`autoStart()` (or `pairAuto`/`deploy`/etc.) blocked that thread, which blocked **every other
module in the app**, not just self-ADB. Concretely: `pairing-context.tsx`'s `loadPairing()`
(SecureStore) queued behind the wedged `autoStart`, and `_layout.tsx`'s Booting gate is
`boot.state === "booting" || pairing === undefined` — the 20 s JS timeout in `use-clip-boot.ts`
only clears the first half, so the user was stuck on "Connecting to Mac…" with no way out except
Force Stop. `SelfAdbModule` now builds its own `HandlerThread` + single-thread `CoroutineScope`
(`adbQueue`) and chains `.runOnQueue(adbQueue)` onto `isPaired`/`pair`/`connect`/`deployAndRun`/
`autoStart`/`pairAuto`/`readDaemonLog`/`killDaemon`/`restartDaemon`/`stop` — still serialized
against each other (preserves issue #5's invariant that only one ADB session-manipulating call
runs at a time), but isolated from the rest of the app.

**libadb's exec-stream I/O has no timeout of its own — only `connect()`'s two phases were ever
bounded.** Decompiling `libadb-android:3.1.1`: `AdbConnection.open` (`openStream`)'s wait and
`AdbStream.read`/`write`'s waits are all bare `Object.wait()`/`Queue.wait()`, no deadline, and
`PairingConnectionCtx` opens its own raw `Socket(host, port)` with no connect timeout either. So
everything `deploy()` does past `connect()` — `pushAsset`, `launchDaemon`, `killDaemon`,
`grantSecureSettings` (all through `AdbManager.runShort`) — could hang forever on a half-dead
session (Wireless Debugging dropped mid-call, a half-trusted adbd). `AdbManager.bounded()` fixes
this: it arms a watchdog `Thread` that, after a deadline, calls `disconnect()` from a thread
other than the caller's (`AdbConnection.close()` does its own unbounded `Thread.join()`, so the
watchdog must never be the blocked thread) — `disconnect()` closes the socket, `interrupt()`s +
`join()`s the connection thread, and `notifyAll()`s every open stream's write lock and read
queue, so the pending `wait()` wakes and throws. `runShort` (15 s default, 25 s for
`launchDaemon`'s longer poll) and each `pushAsset` phase (20 s) are wrapped; `pair()` gets the
same raw-TCP preflight `connect()` already used, since `PairingConnectionCtx`'s socket is outside
`disconnect()`'s reach. A resulting timeout surfaces as `AdbManager.AdbTimeoutException` — a
plain `IOException` subtype, so existing `catch (Exception)` call sites need no changes.

**`cancelAdb()` makes "Try Again" instant instead of racing the native timeout.** It's the one
ADB-touching call that deliberately stays on the *default* Expo queue (not `adbQueue`) — its
whole point is to be reachable while `adbQueue` is occupied. It just calls `adb.disconnect()`,
the same force-wake `bounded()`'s watchdog uses. `use-clip-boot.ts`'s `refresh()` calls it in the
`TimeoutError` branch, right after landing on `needs-setup`/`debugging-unreachable`, so the stuck native call settles
within milliseconds of the JS timeout instead of however long is left on its own internal bound.

### 3.7 The JS ↔ native seam (`ClipBus.kt`)

The Expo module only exists while the JS runtime is alive; the foreground service outlives it.
**`ClipBus`** is the process-wide bridge: the service always posts events here, and the module
attaches/detaches its `onClip` / `onMacClip` / `onMacStat` / `onLog` / `onRelay` /
`onFileTransfer` callbacks in `OnCreate`/`OnDestroy`. It also holds bounded ring buffers — 400 log lines and 100 Mac-clip
entries — so the Logs and Clipboard-History screens can show events that happened *before* the
JS runtime attached (e.g. an FGS reconnect while the app was swiped away). `lastRelay` and
`lastStat` let a late-attaching UI query the current relay status and Mac battery immediately.

### 3.8 File transfer on Android (`ClipForegroundService`, `SendItem`, `FileInbox`, `FileHistory`)

The wire side is §5.4; this is how the phone implements it. Everything runs in the foreground
service, so a transfer outlives the JS runtime and the activity that started it.

**Ways in.** Four entry points, all ending in `ClipForegroundService.sendShared`:
- **Share sheet** — `ShareActivity` (two targets: `ShareToClipboardActivity` for `image/*`,
  `ShareAsFileActivity` for `*/*` *and* `ACTION_SEND_MULTIPLE`). It can't read a URI after it
  finishes, so a file ≤ 64 MB is **staged** into `cacheDir/outbox` while its grant is alive; a larger
  one is **not copied** — its content URI travels on the start intent with `ClipData` +
  `FLAG_GRANT_READ_URI_PERMISSION` and the service streams it. A share with no stream (a link, a text
  block) is sent as a plain clip.
- **Files screen** — `PickActivity` (invisible, not exported) shows `ACTION_OPEN_DOCUMENT` (multiple)
  or `ACTION_OPEN_DOCUMENT_TREE`, takes a **persistent** read grant, and hands the URIs to the service
  (`submitPick`). The persistent grant is what makes **Retry** possible.
- **Retry** (`retrySend`) — rebuilds the item from the history row's saved `source` URI. It reuses the
  failed row and, because the transfer id is deterministic, resumes (§5.4).
- **Cancel** — the progress notification's action, or the Files screen's in-progress row, both end in
  `cancelShare()`.

**`SendItem`** is what the pipeline sends: a stream opener plus `name`/`size`/`mtime`/`dir`, built from a
staged copy, from a content URI, or from a folder walk. `FolderWalker` flattens a picked tree
(`DocumentsContract`, behind a small `DocTree` interface so a fake can unit-test it): hidden entries
skipped, empty/oversized files, an empty folder and a tree past 1,000 files reported rather than
dropped, depth-capped. `TransferId.of(name, size, mtime, dir)` is the deterministic id.

**The send loop** (`sendAllAsFiles` → `sendAsFile`) runs on one `shareExec` thread, so two sends can
never interleave on one ack window. Per file it holds an ack window of 4 (a `Semaphore`), paces itself at
`RELAY_CHUNK_INTERVAL_MS` = 125 ms **only on the relay** (re-read per chunk via `ClipBus.onLan()`), skips
the chunks the Mac reports it already has (`Transfer.have`, `InputStream.skipFully`), and honours a nack
or a cancel by over-releasing the semaphore so a sender blocked on the window or the final drain wakes at
once. One progress notification covers the whole batch (`Sending 2/5`, `name.ext (50%)`, bar = batch
chunks) and one toast closes it; a dead link (`MAC_STOPPED`) ends the batch, a nack only skips that file.

**Receiving.** `applyFile` handles every inbound `file` frame: a clipboard image goes to the clipboard as
a FileProvider URI (§3.4); a chunk goes to `FileInbox`, which writes it into a temp file at
`seq × 640 KiB` (`RandomAccessFile`) — never a map of chunks — and reports `have`. A chunk is acked once
stored and the last one only after `FileSink.saveToDownloads` wrote the file into `MediaStore.Downloads`
under `Link to Mac/<dir>` (no runtime permission on API 29+); a refused or unwritable file is nacked.
`FileSink.sanitize` / `sanitizeDir` treat the peer's name and folder path as untrusted. A burst of
received files raises **one** updating notification (`postReceivedNotification`).

**History.** `FileHistoryStore` (a bounded 200-row JSON file in `filesDir`, plain Kotlin so it is
unit-tested) records one row per file — `queued → active → done / failed / cancelled` for sends, `done` /
`failed` with the MediaStore URI for receives — and `FileHistory` emits every change as the
`onFileTransfer` event. Only a status change is written; a progress tick stays in memory; a row still
`queued`/`active` when the file is loaded belonged to a dead process and is marked `failed`
("Interrupted"). The JS side (`use-file-history.ts`, `files.tsx`) seeds from `getFileHistory()` and applies
the events.

**Two installs side by side.** The dev (`….dev`) and release builds can coexist (separate daemon ports);
`NotificationListener.isOurs` makes each skip *both* packages' notifications, or each would mirror the
other's transfer notifications to the Mac.

---

## 4. macOS: the menu-bar app (`mac/`)

A SwiftUI app with **two surfaces**: a menu-bar item and a **dashboard window**. The menu-bar item is
hand-built on `NSStatusItem` + `NSPopover` (`StatusItemController`) rather than SwiftUI's
`MenuBarExtra`, because the icon has to be a **drag destination** (drop a file on it and the panel
opens with a drop zone) and `MenuBarExtra` exposes no access to its status item; the popover still
hosts the same SwiftUI `MenuPanel`. By default it is a regular Dock app, and both surfaces are
runtime-toggleable (Settings ▸ Appearance: *Show in Dock* flips `.regular` ↔ `.accessory`, *Show in Menu
Bar* adds/removes the status item; `AppearanceStore` keeps at least one visible). Closing the dashboard
leaves the app alive; a Dock click reopens it. The window is a fixed 1280×760 with a chromeless title
bar. Swift 6 with complete strict concurrency; everything observable is `@MainActor`-isolated and async
loops hop back to the main actor on each step. **The only third-party dependency is Sparkle**
(auto-update); everything else is system frameworks. Built reproducibly from `project.yml` via XcodeGen
and ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`, hardened runtime off) so it runs locally without a
Developer team — which is also why the Finder Share extension cannot run (`amfid` refuses an ad-hoc
signed app extension; see `RoadMap.md`).

The UI is **Material 3-flavoured** (mirroring the mobile app): the popover is a compact phone-identity
card (phone render, name, live status dot, tonal transport/battery chips), and the dashboard hosts the
phone panel, a Notifications / Messages tab strip, clip history and Settings.

| File | Role |
|---|---|
| `LinkToMacApp.swift` | `@main` + `AppDelegate`: owns `RelayClient`, `LanServer`, `ProximityMonitor`, `AppearanceStore`, the Sparkle updater and the dashboard window; handles `linktomac://send?path=…` |
| `StatusItemController.swift` | The `NSStatusItem` + popover; a transparent overlay makes the status button a drag destination |
| `RelayClient.swift` | The hub (§4.1): relay WebSocket, pasteboard + battery owners, inbound decode of `stat`/`note`/`sms`/`file`, the clip/notification/message stores, outbound `clip`/`stat`/`sms`/`file` |
| `RelayProtocol.swift` | `ClientMessage`/`ServerMessage` (mirror of `server/src/protocol.ts`) and the **`FileFrame`** codec (§5.4) |
| `LanServer.swift` | LAN-direct WS server (`NWListener`) + Bonjour + HMAC handshake; the relay-less twin of the relay path |
| `Config.swift` / `ServerSettings.swift` | Runtime relay endpoint (host/port/TLS in `UserDefaults`, password in Keychain) |
| `ClipCodec.swift` | E2E payload encryption — ChaCha20-Poly1305 (CryptoKit); String + raw-`Data` variants |
| `PasteboardWatcher.swift` / `ImagePrep.swift` | Pasteboard poll + echo stamp (§4.2); fits a copied image under the frame cap |
| `BatteryMonitor.swift` | IOKit power-source poll → outbound `stat` |
| `FileTransfer.swift` | Sender and planner (§4.4): `FileSender`, `AckWindow`, `FileBatchPlanner`, `BatchProgress`, `BurstCounter` — Foundation only, so the test target compiles it |
| `FileDrop.swift` | `FileDropStore` (download folder, safe save/move) and `FileInbox` (disk-backed chunk reassembly) |
| `FileDropZone.swift` | The "drop to send" surface and the `.phoneFileDrop` modifier (dashboard window + popover) |
| `MacNotifier.swift` | Native banners (`UNUserNotificationCenter`), with a foreground delegate and replace-by-identifier |
| `ProximityMonitor.swift` / `ProximityConfig.swift` | CoreBluetooth central, RSSI → lock decision (§8); UUID derivation |
| `ScreenLock.swift` | Locks the screen (§4.3) |
| `Pairing.swift` / `PairingView.swift` | Room/key generation, Keychain, the v3 QR |
| `LoginItem.swift` | `SMAppService` auto-start at login |
| `MenuPanel.swift`, `DashboardWindow.swift`, `PhonePanel.swift`, `FeaturePanel.swift`, `ClipHistoryScreen.swift` | The popover and the dashboard: phone identity, Notifications/Messages tabs (the Messages tab has the reply composer), clip history |
| `SettingsScreen.swift`, `AppearanceSettings.swift`, `RelayScreen.swift`, `ServerSettingsView.swift`, `AboutView.swift`, `DashboardComponents.swift`, `PanelComponents.swift` | Settings, appearance, relay, about, shared M3 components |
| `ShareExtension/` | Finder ▸ Share ▸ "Send to Phone" — **inert**: it is sandboxed (so it hands the path over via `linktomac://`) and ad-hoc signing can't run it |

### 4.1 RelayClient (Swift)

`@Observable`, `@MainActor`. Uses a monotonic **`generation` counter** so that loops belonging
to a replaced socket bail out instead of corrupting current state — important since
receive/heartbeat run as detached `Task`s. App-level ping every 25 s with a 50 s no-inbound-frame
"pong timeout" that tears down a half-open socket (after sleep/wake or a NAT timeout, *sending*
proves nothing — only receiving does); exponential backoff reconnect capped at 30 s. Joins as `"mac"`.
On a received `clip` it writes to the pasteboard (and appends to an in-memory clip-history ring the
dashboard reads); on a `cmd` it dispatches to a handler (currently only `"lock"`). It also **reports the
Mac's battery** as `stat` frames (`BatteryMonitor.swift`, IOKit power sources) merged with the BLE
proximity reading (§8): pushed the moment a peer connects and whenever either changes; a desktop Mac with
no battery sends only proximity. **Inbound** `stat` is decoded into `phoneBatteryLevel`/`phoneCharging`/
`phoneName` for the PhonePanel. Inbound `note` frames are upserted by key into the notification ring and
raised as banners (§5.2); inbound `sms` frames feed the message store and resolve reply acks (§5.3);
inbound `file` frames go through `receiveRemoteFile` (§4.4). Two persisted outbound gates
(`sendToAndroid`, `syncImages`, Settings ▸ Clipboard) are the Mac-side switches for one-way flows — the
phone no longer has any. The endpoint comes from `ServerSettingsStore`, so it stays **idle until
configured** rather than dialing a placeholder; `reconnect()` re-dials on a relay-settings change, and
`wss://` is used when the `secure` flag is set. Unpair clears the clip-history, notification and message
stores.

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

### 4.4 File transfer on the Mac (`FileTransfer.swift`, `FileDrop.swift`, `FileDropZone.swift`)

The wire side is §5.4; this is how the Mac implements it.

**Ways in.** Every one hands *all* the dropped items to `RelayClient.sendFilesToPhone(_:)` at once: the
dashboard window and popover (`.phoneFileDrop`: an `.onDrop` that resolves **every** provider through a
lock-guarded box, reporting items that carry no file URL — Mail/Photos "file promises" — instead of
ignoring them), the menu-bar icon (`StatusDropView.performDragOperation`, file URLs only), and a
`linktomac://send?path=…` URL (the inert Share extension, or `open` from a shell). A folder is allowed.

**Planning.** `FileBatchPlanner.plan` flattens the drop off the main actor: folders are walked with
`FileManager.enumerator` (hidden files and nested symlinks skipped, packages sent as trees, at most 1,000
files), each file keeps its folder path as `dir`, and empty / oversized / unreadable things become
`problems` for the summary instead of vanishing.

**Sending.** `FileSender` is **not** `@MainActor` — it blocks on an ack window — and works through a batch
one file at a time on a private serial queue; a drop that arrives mid-batch **joins** it, so there is one
bar and one summary however many drags it took. Per chunk it asks a `Transport` closure to emit on the link
that is up *right now* (LAN, else relay, else the transfer ends at once instead of waiting out a timeout),
paces relay chunks at 125 ms, and uses `AckWindow` — a per-chunk set behind an `NSCondition` — for flow
control. **It replaced a `DispatchSemaphore`:** libdispatch kills the process when a semaphore is
deallocated below its initial value, and a transfer that ended short of its acks (timeout, nack, dead
link) left exactly that behind; the next send crashed the app. The window can also be *failed*, so a nack,
a lost link or a cancel wakes a blocked sender immediately. A refused file (nack) doesn't stop the batch; a
dead link or a silent phone does, because every remaining file would wait out the same 30 s. The id is
deterministic and the loop skips what the phone reports having (`have`) — see §5.4.

**UI.** One determinate bar over the batch's bytes (`BatchProgress.overallFraction`), the file in flight
labelled `name.ext (50%)`, a `3 / 5` counter and a Cancel button; one summary banner at the end.

**Receiving.** `receiveRemoteFile` parses the frame and routes it: `ack`/`nack` to the sender; a chunk to
`FileInbox`, which writes it into a temp file at `seq × chunkRawBytes` (a one-frame file or clipboard image
stays in memory), reports `have`, evicts a stale partial when full, and deletes temp files on completion,
reject, sweep (a 15 s timer while a transfer shows) and at launch. The finished file is **moved** into place
by `FileDropStore.moveIn` off the main actor — recreating the sender's folder under the download folder
from the sanitised `dir` and never overwriting (a clash becomes `photo 2.jpg`) — and only then is the
last chunk acked; a failure nacks. A burst raises one updating banner (`BurstCounter` + a fixed
notification identifier).

---

## 5. Wire protocol (relay)

JSON text frames over WebSocket. The relay reads control frames but treats `clip`/`cmd`/`stat`/`note`/`sms`/`file`
payloads as opaque. Defined in `server/src/protocol.ts`, mirrored by `RelayProtocol.swift`
(Mac) and inline `JSONObject` building in `RelayClient.kt` (Android).

```jsonc
// client → relay
{ "t": "join", "room": "<roomId>", "device": "android" | "mac" }
{ "t": "clip", "nonce": "<base64>", "ct": "<base64>" }   // forwarded verbatim
{ "t": "cmd",  "nonce": "<base64>", "ct": "<base64>" }   // action E2E-encrypted, forwarded verbatim
{ "t": "stat", "nonce": "<base64>", "ct": "<base64>" }   // telemetry (battery ± name; Mac also ± BLE prox/rssi), bidirectional, E2E-encrypted, forwarded verbatim
{ "t": "note", "nonce": "<base64>", "ct": "<base64>" }   // mirrored notification (phone → Mac), E2E-encrypted, forwarded verbatim
{ "t": "sms",  "nonce": "<base64>", "ct": "<base64>" }   // phone → Mac: mirrored SMS batch/delta, reply ack; Mac → phone: reply request. E2E-encrypted, forwarded verbatim
{ "t": "file", "nonce": "<base64>", "ct": "<base64>" }   // both ways: clipboard image, file chunk, chunk ack/nack. plaintext = u16 header-len ‖ header JSON ‖ raw bytes (§5.4), E2E-encrypted, forwarded verbatim
{ "t": "ping" }

// relay → client
{ "t": "joined", "peers": ["mac"] }
{ "t": "peer",   "state": "online" | "offline", "device": "mac" }
{ "t": "clip",   "nonce": "...", "ct": "..." }            // the peer's frame, relayed
{ "t": "cmd",    "nonce": "...", "ct": "..." }            // the peer's command, relayed
{ "t": "stat",   "nonce": "...", "ct": "..." }            // the peer's telemetry (battery ± name; Mac also ± BLE prox/rssi), relayed
{ "t": "note",   "nonce": "...", "ct": "..." }            // the peer's mirrored notification, relayed
{ "t": "sms",    "nonce": "...", "ct": "..." }            // the peer's mirrored SMS batch/delta, reply request or reply ack, relayed
{ "t": "file",   "nonce": "...", "ct": "..." }            // the peer's clipboard image, file chunk, or chunk ack/nack, relayed
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
`clip`/`cmd`/`stat`/`note`/`sms`/`file` stay E2E-encrypted, so a sniffer sees only opaque ciphertext. (LAN has no
  relay-side frame cap or rate limit, so files are not paced there — §5.4.)

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
  double-delivery. Outbound `clip`/`file`/`cmd` produced while **no** link is joined (the grace
  window, a socket still connecting) are queued (cap 8, 30 s TTL) and replayed FIFO on the next
  joined edge instead of being dropped.
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

### 5.3 Message mirroring and replies (`sms`)

The phone reads its **SMS store** and shows it as real conversation threads on the Mac's Messages
tab. The reader, `SmsMirror.kt`, is **owned by the `ClipForegroundService`** (not a system service),
so it survives a JS swipe like the notification listener. It needs two **dangerous runtime
permissions** — `READ_SMS` (the texts) and `READ_CONTACTS` (resolve sender names) — granted from the
app's settings via `SelfAdbModule.requestSmsAccess`. `READ_SMS` is Play-restricted, but the app is
**sideloaded** (EAS `preview` APK), so the policy doesn't apply. SMS only (no MMS/RCS).

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
leading/`surfaceContainerHigh`). No delete/edit handling (SMS deletions are rare). Cleared on unpair.

**Replying (Mac → phone), 1:1 threads only.** The `sms` frame type carries the reverse direction as
extra ops — the same move the `file` ack/nack makes, rather than a new frame type:

```jsonc
// Mac → phone: a reply request
{ "op": "send", "corr": "<uuid>", "addr": "+90555…", "body": "on my way" }
// phone → Mac: the outcome, on the same channel
{ "op": "sent",   "corr": "<uuid>", "id": 4712 }        // id only if the phone could record it
{ "op": "failed", "corr": "<uuid>", "error": "…" }
```

The Mac's inline composer (`RelayClient.sendReply`) appends an optimistic `.sending` placeholder (a
synthetic negative `id`, tracked by `corr`; **15 s timeout → `.failed`**) and the phone's ack resolves it
(`applySmsAck`), rewriting the placeholder's `id` to the real SMS-store id when the phone reports one so the
later genuine mirror delta upserts over it instead of duplicating. The phone sends with
`SmsManager.sendMultipartTextMessage` (`SmsMirror.sendReply`), resolving the result from a sent-intent
receiver. It needs the separate **`SEND_SMS`** runtime grant (requested lazily — not bundled with the
mirroring grant). Because the app is not the default SMS handler it generally can't write its own sent
message into the SMS store, so `id` is often absent and the Mac keeps its placeholder as the only record of
that reply. If `SEND_SMS` is missing, the phone raises a one-time notification
(`postSmsSendPermissionAlert`) and Settings shows a **Grant SMS Send Access** row.

**Granting on a sideloaded APK.** Both SMS requests go through `SelfAdbModule.requestWithSettingsFallback`,
which resolves `granted | denied | blocked`. `blocked` means Android refused in under 600 ms — it declined
to prompt, a person can't tap "Don't allow" that fast. That is the sideloaded-APK case: the first request
is blocked as a restricted setting, the user allows it under App info, comes back, and the system *still*
shows no dialog, so the button used to look dead. On `blocked`, Settings shows an alert with the steps
(⋮ → *Allow restricted settings*, then *Permissions → SMS → Allow*) and an "Open App info" button, and the
grant rows carry the same hint until the permission is held.

### 5.4 File transfer (`file`, both directions)

One frame type carries four things: a **clipboard image**, a **chunk of a file**, and a chunk's **ack** or
**nack**. The plaintext inside the v2 envelope (AAD `"file"`) is

```
u16 BE header-len ‖ header JSON (utf-8) ‖ raw bytes      // raw bytes inside the AEAD, so only the outer `ct` is base64
```

Header keys past `mime` are all optional and additive, so a peer that understands only `mime` still pastes an
image:

| key | meaning | absent means |
|---|---|---|
| `op` | `data` (payload), `ack` (receiver stored one chunk), `nack` (it could not) | `data` |
| `mime` | content type | `image/png` |
| `name` | original file name, for `disp:"save"` | receiver invents one |
| `dir` | relative folder (`Photos/2024`) the file sat in when a folder was sent | the download folder itself |
| `disp` | `clip` (paste it) or `save` (write it to the download folder) | `clip` |
| `id` / `seq` / `n` | transfer id, 0-based chunk index, chunk count; written **even for a one-chunk file** — `id` is what makes the receiver ack | a clipboard image |
| `err` | on a `nack`: why (free text) | no reason |
| `have` | on an `ack`: leading chunks `[0, have)` already stored (resume) | no resume info |

The header repeats in full on every chunk, so chunks may arrive in any order. A header must fit its u16
length: a long `name`/`dir` is shortened (the folder is shed first) rather than wrapped. **The format is
pinned by `protocol-vectors/file-frame.json`**, which the Swift (`FileFrameVectorTests`) and Kotlin
(`FileFrameVectorTest`) codecs must both pass — they are mirrored by hand and drifted once already (Swift
omitted `id` on one-chunk files, so the phone never acked anything small and every such send timed out).
Change the vectors and both codecs together.

**Clipboard image vs. file.** A clipboard image is squeezed to fit one frame (`ImagePrep.swift` on the Mac,
`ClipForegroundService.fitImage` on the phone: downscale + JPEG to ~700 KB raw) so the sealed + base64'd
frame stays under the 1 MiB `maxPayload`, and carries no `id` (so it is never acked). A **file** keeps its
original bytes and is split into **640 KiB chunks**.

**Flow control and pacing.** Two relay limits are load-bearing, because each drops the *connection*, not the
frame: the 8 MiB per-peer send buffer and the 120-frames-per-10 s rate limit. So a sender keeps only **4
chunks unacked** (the ack is flow control, not politeness) and, **on the relay only**, spaces chunks 125 ms
apart (~5 MB/s). LAN-direct has neither limit and is not paced. A chunk unacked for 30 s fails the transfer.

**Honest receipts.** A chunk is acked once it is stored, and the **last** chunk only after the file has been
written to its final place, so "sent" means the file exists on the other device. A file that can't be
written (full disk, a refused write, a cap) is **nacked**, and the sender fails that file immediately with
the reason instead of waiting out the timeout. The sender's window can be failed from outside (nack, lost
link, cancel), which wakes it at once.

**Resume.** The transfer id is **deterministic** — the first 8 hex of SHA-256 of `name|size|mtime|dir` — on
both senders, so sending the *same file again* reuses it. The receiver recognises the partial, every ack
reports `have`, and the sender seeks past those chunks (clamped so the last chunk always goes: it is what
completes the file and earns the final ack). Only the few chunks that were in the ack window when it
stopped are re-sent. No UI is needed — re-drop on the Mac, re-share on the phone, or Retry in the phone's
Files screen. A receiver keeps a half-received transfer for **10 min**; one idle for 2 min stops showing as
"receiving" and may be evicted to make room for a new transfer (a live one never is). An edited file changes
size or mtime and so starts fresh (an edit preserving both can't be told apart). An old peer ignores `have`
and re-sends everything — correct, just slower. Resume needs the *receiver* to still hold the partial, so it
survives a dropped link or a cancel, not a restart of the receiving app.

**Size and memory.** The cap is **1 GiB per file** (`FileFrame.maxTransferBytes` / `MAX_TRANSFER_BYTES` —
they must match). Both receivers stream each chunk into a temp file at `seq × chunk size` and move the
finished file into place, so a gigabyte costs one chunk of RAM instead of two gigabytes (holding chunks in a
dictionary is what used to cap files at 64 MB). The phone also sends a large share-sheet file straight from
its content URI instead of copying it into its cache first. Time (≈ 3–4 min per GiB over the paced relay)
and free space are the real limits.

**Folders.** `dir` carries the relative path; both receivers recreate the tree under the download folder.
The path is untrusted input: the twin sanitisers (`FileDropStore.sanitizeDir` in Swift, `FileSink.sanitizeDir`
in Kotlin) split on `/` and `\`, drop empty / `.` / `..` parts, replace `:`, cap a part at 100 characters and
the path at 8 levels, so it can't escape the folder — pinned by `protocol-vectors/dir-sanitize.json`. A
sender walks at most 1,000 files per folder and skips hidden entries and nested symlinks.

**Cancel** is one-sided: the Mac drop zone's Cancel and the phone notification's Cancel just stop sending.
There is deliberately no `cancel` op: an *old* peer parses an unknown `op` as a data chunk, so adding one
would corrupt transfers with older apps. The receiver stops hearing from the sender and drops the partial
when it expires.

**Receiver bounds** (an inbound transfer is peer-controlled): 2 concurrent transfers, 1 GiB each, no chunk
longer than the chunk size, a temp file name that can't be steered by the (untrusted) id (the phone sanitises
the id into the name; the Mac uses a random one), a 10 min retention, and a purge of leftover temp files at
startup.

**Notifications.** A burst of received files raises **one** updating notification on each side (the first is
named, later ones turn it into "N files" / "N files in Photos"), not one per file; sends raise one progress
notification / bar for the whole batch and one summary.

---

## 6. Clipboard sync — end to end

**Phone → Mac (copy on Android):**

1. The user copies. The system fires `dispatchPrimaryClipChanged` into `ClipboardAgent`'s
   proxy binder.
2. The agent reads the clip and emits `{"type":"clip", …}` over localhost to `ClipBridge`.
3. `ClipForegroundService.ingestClip(text, ts, DAEMON)` checks it isn't the echo of its own
   write, records history, and calls `ConnectionManager.sendClip`.
4. `ClipCodec.encode` **encrypts** (ChaCha20-Poly1305) → `{ t:"clip", nonce, ct }` → relay → Mac.
5. The Mac **decrypts** `ct`, stamps `lastChangeCount`, and writes `NSPasteboard`.

Steps 1–2 are the **only** part that needs ADB, and they're the only reason the shell daemon
exists. When it's gone, steps 3–5 are reached through a manual source instead — `ClipSource.MANUAL`,
from either `ProcessTextActivity` (the text-selection toolbar entry; the text arrives in
`EXTRA_PROCESS_TEXT`, so the clipboard is never touched and no focus is needed) or
`ClipboardReadActivity` (the sticky notification's "Send clipboard" action; a real translucent
window so `clipboardAccessAllowed`'s `isUidFocused` check passes, read in `onWindowFocusChanged`).
Both hand off via `ClipForegroundService.submitClip`, so **`ingestClip` is the single funnel**
every capture path goes through and no source can skip echo suppression or the history.

**Mac → Phone (copy on macOS):**

1. `PasteboardWatcher` poll sees a new `changeCount`, reads the string.
2. `RelayClient.sendClip` → `{ t:"clip", … }` → relay → phone.
3. `writeRemoteText` stamps the text into the recent-writes map, then `putOnClipboard` writes
   it: through the bridge → the daemon's `setPrimaryClip` while the bridge is up, else **directly**
   via `ClipboardManager.setPrimaryClip`. Background clipboard *writes* are allowed — only reads
   are focus-gated — which is the same property `applyFile` already relied on for images. Before
   that fallback existed, a dead daemon made this whole direction a silent no-op while the log
   still claimed success, so ADB dying took Mac→phone down with it despite it never needing ADB.
   The two paths log distinctly (`clip -> clipboard via daemon` / `... direct`) so the direct one
   can be confirmed on-device and the daemon branch eventually dropped.
   On the daemon path the agent's resulting change event is swallowed via `lastSeen`, and the
   service's own `onClip` is swallowed by the recent-writes stamp — **double echo suppression**
   because the write traverses two echo-producing boundaries.

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

The lock path is intentionally kept **off the clipboard path**: no clipboard gate (the Mac's
*Send copies to Android*, for instance) affects it. Because the action is opaque ciphertext end to end, adding new remote commands
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

Both are stored in the macOS **Keychain** (generic-password item). The Mac shows a **v3** QR
encoding `{"v":3,"room":"…","key":"…","name":"<computer name>","host":"…","port":…,
"secure":true,"token":"…","lport":53124,"lan":true}` via CoreImage's `CIQRCodeGenerator`
(`Pairing.swift`) — it carries the pairing, the relay endpoint + password, *and* the LAN-direct
parameters (§5.1), so one scan fully configures the phone. (Older v1/v2 QRs are still accepted; a v1
has no server fields, so the phone then keeps its existing server config.)

The phone scans it with `expo-camera`, validates it (`parsePairingQR`; v1, v2 and v3 are accepted), and
stores the pairing plus the server config in two **`expo-secure-store`** entries (Android Keystore-backed). The
derived URL (`ws(s)://host:port/ws`) + token + room/key are then pushed into the native service
via `setRelay` (relay URL + token + room/key + the LAN host/port), which persists them to `SharedPreferences` so the `START_STICKY` service can
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
- **Replay protection + type binding (v2 envelope).** Every frame binds its wire type as AEAD
  **AAD** (`utf8("clip"|"cmd"|"stat"|"note"|"sms"|"file")`) — a captured ciphertext can't be relabeled
  to another frame type — and the plaintext is prefixed with an **8-byte big-endian
  epoch-milliseconds timestamp**. Receivers reject frames outside a **±120 s freshness window**
  and keep a **seen-nonce cache** within the window, so a captured frame (e.g. a `cmd:lock`)
  can't be replayed at all. The envelope is a **byte-exact cross-language contract** between
  `ClipCodec.swift` and `ClipCodec.kt` — change both together (cross-verified via Node/JVM/
  CryptoKit test vectors). Legacy v1 (no AAD, raw payload) is **no longer accepted** on either
  end: a v1 frame carried no freshness and was replayable indefinitely. A peer running a
  pre-v2 build fails closed (its frames are dropped) — update both apps together.
- The relay is a dumb pipe: it never stores content and never parses `nonce`/`ct`.
- `roomId` is an unguessable 256-bit bearer; the **operator-defined relay password**
  (`RELAY_AUTH_TOKEN`) is a second gate so strangers can't even open sockets. It is no longer
  baked into the build — the Mac operator sets it and it rides in the pairing QR (acceptable,
  since the QR already carries the more-sensitive E2E key) or is typed into the app. Per-room
  cap of 2, rate limiting, and payload caps limit abuse.
- Secrets live in the platform secure stores (Keychain / Keystore-backed SecureStore).
- Proximity is BLE-only and never touches the network.
- Remote lock uses no entitlement and can't *unlock*.
- **Everything a peer sends is validated before it touches the disk or the UI.** A received file name is
  reduced to a safe last path component (`sanitize`), a folder path is sanitised by twin functions
  pinned by shared vectors (no `..`, no separators, bounded depth/length — §5.4), the transfer id never
  becomes a path, sizes and chunk lengths are capped (1 GiB, ≤ one chunk), and a received file is
  never overwritten. The shell daemon refuses to read a clipboard-image URI its setter couldn't read
  itself (confused-deputy guard, §3.4).
- **Updates are signed.** The Mac's Sparkle appcast entries carry an EdDSA signature
  (`SUPublicEDKey` in `Info.plist`; the private half lives in the release machine's login Keychain).
  The Android app only *finds* a newer release (the GitHub "latest release" API) and sends the user to
  download the APK; it installs nothing itself.

**What does NOT hold yet (be explicit about this):**

- 🟡 **Static key.** The pairing key is long-lived (rotates only on re-pair). The v2 envelope
  above closes the replay/relabel hole — and with v1 acceptance now removed from both codecs,
  legacy-format frames are rejected outright — but a leaked key still decrypts everything
  until the user re-pairs.
- 🟢 **Transport supports `wss`.** A per-server `secure` flag selects `wss://` vs `ws://`:
  point the app at a domain behind a TLS-terminating reverse proxy (Let's Encrypt) and toggle
  TLS on. `ws://` remains available for a trusted LAN. The relay password still benefits from the
  TLS tunnel; **`cmd` is now E2E-encrypted (AEAD) regardless of transport**, so a forged or
  replayed command fails the Poly1305 tag and is dropped even on plaintext `ws://`. The same
  holds for `stat` telemetry, `note` mirrored notifications, `sms` messages and replies, and `file`
  clipboard images and files — opaque ciphertext on every transport.
- 🟢 **LAN-direct needs no relay or TLS to stay confidential.** In relay-less LAN mode (§5.1)
  the transport is plain `ws://`, but `clip`/`cmd`/`stat`/`note`/`sms`/`file` remain ChaCha20-Poly1305-encrypted
  and the socket is gated by an HMAC challenge-response over the pairing key — so a stranger on the LAN
  can neither read traffic nor occupy the peer slot. The unencrypted `room`/`rid` it could
  observe are non-secret routing ids.
- 🟢 **No secrets baked into the build.** The relay address, password, and TLS setting are
  configured at runtime (Mac **Settings ▸ Relay Server** → `UserDefaults`/Keychain; phone **Settings →
  Relay server** / pairing QR → SecureStore). Only `server/.env` holds the server's
  `RELAY_AUTH_TOKEN`. Rotating the password means updating `server/.env` and re-scanning the QR
  (or re-entering it in the app); nothing sensitive sits in tracked source.
- 🟡 **The Mac's `linktomac://send?path=…` URL scheme can be invoked by any local app or web page**
  (it exists for the inert Share extension, §4). It checks the path exists but not who asked, so a page
  could make the Mac send a chosen file *to the paired phone* — never anywhere else, but still a
  surprise on the phone. Gating it (a confirmation, or removing the scheme until the extension can run)
  is open.
- 🟡 **The Mac app is ad-hoc signed, not notarized.** First launch on another Mac needs right-click → Open;
  Sparkle updates are EdDSA-verified, but Gatekeeper never vets the app. This is also why the Finder
  Share extension cannot run (`amfid` refuses an ad-hoc signed app extension).
- 🟠 **Wireless Debugging is a device-wide loosening.** Any client on the network holding an
  authorized key can reach adbd. Mitigation here is that it's your own device and the only
  trusted key lives in the app; the app turns Wireless Debugging back *off* after deploying.

---

## 11. Lifecycle & resilience

| Failure | What happens |
|---|---|
| App swiped away | Foreground service + detached daemon keep syncing; JS callbacks just detach |
| Service killed by OS | `START_STICKY` restarts it; it re-reads `SharedPreferences` and reconnects with no JS |
| Daemon killed by lmkd/One UI (no reboot) | The shell-UID supervisor loop respawns it in ~3 s with the same port + secret — no ADB, no Wi-Fi, no JS (§3.3, issue #31) |
| Relay WS drops | Both clients reconnect with exponential backoff (cap 30 s) |
| Phone reboot | Wireless Debugging usually off → app self-enables it (if it holds `WRITE_SECURE_SETTINGS`), mDNS-reconnects, relaunches the daemon, turns WD back off |
| adbd forgot the key (Samsung) | `connect` throws `AdbPairingRequiredException` → routed to `need-pair` for a fresh code |
| Mac sleep/wake | `URLSession` task fails (or the 50 s no-inbound-frame timeout fires on a half-open socket) → generation-guarded reconnect |
| A file transfer is interrupted (link drop, cancel, a timeout) | The sender fails that file — at once on a nack, a lost link or a cancel, after 30 s of unacked chunks otherwise. The receiver keeps the partial for 10 min; sending the same file again **resumes** (§5.4) |
| Phone service killed mid-transfer | `START_STICKY` restarts it; the Files-screen row that was `active` is shown as "Interrupted"; the Mac keeps its partial for a resume |
| Mac app quit mid-transfer | The phone keeps its partial (in memory) for 10 min; re-dropping the file resumes it |
| An update is out | Mac: Sparkle checks the appcast; Android: the app compares the installed version with the GitHub latest release and links the APK |
| Mac crash | `SMAppService` login item relaunches at next login |

---

## 12. Build & run

Only the **relay** keeps a secret file; the Mac and phone are configured at runtime, so a
fresh checkout builds and runs with nothing to fill in — you just enter the server in the app.

| Component | Config | Where |
|---|---|---|
| Relay | `server/.env` (gitignored, from `server/.env.example`) | `RELAY_AUTH_TOKEN` (the relay password, `openssl rand -hex 32`), `HOST`, `PORT` |
| Mac | **Settings ▸ Relay Server** (dashboard) | host/port/TLS in `UserDefaults`, password in Keychain (`ServerSettings.swift`) |
| Android | **Settings → Relay server**, or the pairing QR | `ServerConfig` in SecureStore (`server-config.ts`) |

The Mac embeds its endpoint + password in the pairing QR, so scanning it configures the phone
in one step. The relay's `RELAY_AUTH_TOKEN` must match the password you set on the Mac/phone.

| Component | Command |
|---|---|
| Relay | `cd server && cp .env.example .env && npm install && npm run dev` (or `docker compose up -d`); `npm run typecheck`; `npm run smoke` (against a running dev server) |
| Mac | `cd mac && xcodegen generate && open LinkToMac.xcodeproj` → Run, then set **Settings ▸ Relay Server** (the `.xcodeproj` is generated and gitignored) |
| Mac tests | `cd mac && xcodegen generate && xcodebuild -project LinkToMac.xcodeproj -scheme LinkToMac -destination 'platform=macOS' test` (swift-testing, no host app) |
| Android (dev) | `cd mobile && bun install && bun run android` — builds the **`.dev`** variant (own app id, own daemon port 53125) so it coexists with a release install; custom native module → **no Expo Go** |
| Android tests | `cd mobile/android && ./gradlew :selfadb:testDebugUnitTest` (JUnit + the real `org.json`; first run needs network); `cd mobile && npx tsc --noEmit && npx expo lint` |
| Clipboard agent | rebuild dex with `native-src/clipboard-agent/build-dex.sh` only if `ClipboardAgent.java` changes |

There is no CI: `protocol-vectors/` (run by both the Swift and the Kotlin suite), the Mac and Android
test suites, `tsc` and `expo lint` are run by hand before a change merges. The cross-language contracts
(`ClipCodec`, `FileFrame`, the BLE UUID, `dir` sanitising) are the reason both test suites exist.

**Releasing.** One GitHub release carries both apps. Bump `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `mac/project.yml` (Sparkle decides "is there an update?" by the build number)
and `VERSION` in `mobile/app.config.ts` (the Android `versionCode` is `YYMMDDNNN` from the build date —
set `BUILD_NUMBER=2` for a second build the same day, or the new APK has the same `versionCode`). Write
`release-notes/v<version>.md` (it becomes the release body; the publish script refuses without it). Build
the APK with `eas build --platform android --profile preview --local` (the `preview` profile *is* the
public release channel). `cd mac && ./scripts/build-release.sh --publish` builds the universal DMG,
EdDSA-signs it, writes the appcast and creates the GitHub release; then attach the APK
(`gh release upload`). Native changes mean a new APK — a JS-only change could go out as an EAS Update on
the same `runtimeVersion`, but nothing that touches `modules/selfadb` can.

First run: enter your relay in the Mac's **Settings ▸ Relay Server** (or stay LAN-only), show the pairing QR, scan it on
the phone (the QR carries the server config, so the phone is configured in one scan), then open
Android's *Pair device with pairing code* dialog and enter the 6-digit code once.

---

## 13. Scope & roadmap

v1 links **one phone and one Mac**. Implemented:

- **Clipboard** — two-way text (end-to-end encrypted with ChaCha20-Poly1305) and **bidirectional
  images** (`file`; §5.4 — auto-fitted under the 1 MiB frame cap, applied on the phone as a FileProvider
  content URI, read on the phone by the shell daemon via a system Context).
- **Files and folders, both ways** (`file`; §5.4) — chunked, windowed, acked, with honest receipts,
  **resume**, a 1 GiB per-file cap, folders that keep their structure, and cancel. Phone → Mac comes from
  the system share sheet ("Send to Clipboard" for images, "Send as a File" for anything, several at once),
  from the phone's **Files screen** (send files, send a folder, a persisted history, retry), and lands in
  the folder chosen under the Mac's Settings ▸ Files. Mac → phone comes from dropping files and/or folders
  on the dashboard window or the menu-bar icon (one bar, one summary), and lands in the phone's
  `Downloads/Link to Mac`.
- **Remote lock**, **proximity auto-lock** (with the live BLE distance on both dashboards).
- **Relay-less LAN-direct** mode (§5.1) — auto-preferred over the relay on the same Wi-Fi.
- **Bidirectional telemetry** (`stat`: each side's battery, the phone's name, the Mac's BLE reading).
- **One-way notification mirroring** (`note`, phone → Mac; §5.2) as a native banner and the dashboard's
  Notifications tab.
- **Message (SMS) mirroring and replies** (`sms`; §5.3) — conversation threads in the Messages tab, and a
  reply composer for 1:1 threads that sends a real SMS from the phone.
- **Updates** — Sparkle on the Mac; the Android app points at the GitHub release.

Not working today: **Finder ▸ Share ▸ "Send to Phone"** — the extension ships in the bundle but macOS
(`amfid`) refuses to run an *ad-hoc signed* app extension (`AppleMobileFileIntegrityError -423`); it needs a
Developer ID, or an `NSServices` entry the app provides itself. On the roadmap (`RoadMap.md`): FCM push-wake
for minimum idle battery, screen mirroring, and read-only access to the gallery and calls from the Mac.

---

## Appendix: file map

```
server/
  src/
    index.ts        HTTP+WS bootstrap, auth, per-conn wiring, shutdown
    relay.ts        room map, join + clip/cmd/stat/note/sms/file forwarding, backpressure
    protocol.ts     frame types + validation (mirrored by RelayProtocol.swift / RelayClient.kt)
    ratelimit.ts    sliding-window limiter
    heartbeat.ts    ws ping/pong reaper
    config.ts       env config
    logger.ts       pino logger (redacts the room id, never logs nonce/ct)
  scripts/smoke.ts  end-to-end check against a running dev server

protocol-vectors/   wire vectors BOTH codecs must pass (README.md explains the format)
  file-frame.json   the `file` frame plaintext: parse, encode, over-long header, malformed
  dir-sanitize.json how a peer-supplied folder path is made safe

mac/
  project.yml                    XcodeGen spec (app + share extension + LinkToMacTests); the .xcodeproj is generated
  scripts/build-release.sh       universal DMG + Sparkle appcast (+ --publish to GitHub)
  Sources/LinkToMac/
    LinkToMacApp.swift           @main + AppDelegate: owns the services, Sparkle, the dashboard window, linktomac:// URLs
    StatusItemController.swift   NSStatusItem + popover; the icon is a drag destination
    RelayClient.swift            the hub: relay WS, pasteboard + battery owners, inbound stat/note/sms/file, stores, outbound frames
    RelayProtocol.swift          ClientMessage/ServerMessage + the FileFrame codec
    LanServer.swift              LAN-direct WS server (NWListener) + Bonjour + HMAC handshake
    Config.swift / ServerSettings.swift   runtime relay endpoint (UserDefaults + Keychain)
    ClipCodec.swift              E2E encryption (ChaCha20-Poly1305 / CryptoKit; String + Data variants)
    PasteboardWatcher.swift      changeCount poll (text + image copies) + echo stamp
    ImagePrep.swift              fit a copied image under the frame cap
    BatteryMonitor.swift         IOKit power-source poll → outbound stat
    FileTransfer.swift           FileSender, AckWindow, FileBatchPlanner, BatchProgress, BurstCounter (Foundation only)
    FileDrop.swift               FileDropStore (download folder, safe save/move, sanitize) + FileInbox (disk-backed reassembly)
    FileDropZone.swift           the drop-to-send surface + .phoneFileDrop modifier
    MacNotifier.swift            native banners (foreground delegate, replace-by-identifier)
    ProximityMonitor.swift / ProximityConfig.swift   BLE central, RSSI → lock; UUID derivation
    ScreenLock.swift             SACLockScreenImmediate / CGSession
    Pairing.swift / PairingView.swift   room/key, Keychain, v3 QR
    LoginItem.swift              SMAppService auto-start
    MenuPanel.swift / DashboardWindow.swift / PhonePanel.swift / FeaturePanel.swift / ClipHistoryScreen.swift   popover + dashboard
    SettingsScreen.swift / AppearanceSettings.swift / RelayScreen.swift / ServerSettingsView.swift / AboutView.swift   settings surfaces
    DashboardComponents.swift / PanelComponents.swift   shared M3 components
  ShareExtension/                Finder ▸ Share ▸ "Send to Phone" (inert: ad-hoc signing; hands the path over via linktomac://)
  Tests/                         swift-testing: AckWindow, FileSender (resume), FileInbox, FileBatchPlanner, FileFrame, FileFrameVectors, BurstCounter

mobile/modules/selfadb/android/src/main/java/expo/modules/selfadb/
  SelfAdbModule.kt          Expo module: autoStart / pair / relay / proximity / SMS-permission / file-history APIs
  AdbManager.kt             libadb wrapper: pair/connect/discover/push/launch
  ClipboardAgent (java)     → built to assets/clipboard-agent.dex (captures text + images)
  ClipForegroundService.kt  START_STICKY host: bridge + connection + BLE + SMS mirror + the whole file pipeline
  ClipBridge.kt             localhost NDJSON client to the daemon
  ConnectionManager.kt      LAN-preferred / relay-fallback link arbiter (+ outbound queue)
  RelayClient.kt / LanClient.kt / LanDiscovery.kt   OkHttp WS to the relay / to the Mac; mDNS discovery
  ClipCodec.kt              E2E encryption (ChaCha20-Poly1305 / javax.crypto; String + ByteArray variants)
  FileFrame.kt              the file-frame codec (mirrors RelayProtocol.swift)
  SendItem.kt               what the pipeline sends + TransferId (deterministic id) + skipFully + ShareRef
  FileInbox.kt              chunk reassembly into a temp file + FileSink (MediaStore Downloads, name/dir sanitising)
  FolderWalker.kt           picked folder → files (DocTree interface + the SAF implementation)
  FileHistory.kt            the persisted Files-screen history (store + the app-wide object that emits onFileTransfer)
  ShareActivity.kt          share-sheet targets (Send to Clipboard / Send as a File, single or multiple)
  PickActivity.kt           system file / folder picker for the Files screen (persistent read grant)
  ProcessTextActivity.kt / ClipboardReadActivity.kt   the two ADB-free manual capture paths
  NotificationListener.kt   NotificationListenerService → note frames (skips both app variants)
  SmsMirror.kt              FGS-owned SMS reader/sender → sms frames
  BleAdvertiser.kt          BLE presence beacon
  ClipBus.kt                service ↔ module bridge + ring buffers + file-transfer event
mobile/modules/selfadb/android/src/test/…/   JUnit: FileFrameVectorTest, FileInboxTest, FileSinkTest, FolderWalkerTest, FileHistoryTest

mobile/native-src/clipboard-agent/
  ClipboardAgent.java       the privileged daemon source
  build-dex.sh              javac → d8 → dex

mobile/src/
  app/                      Expo Router screens: index (Home), files, settings, notifications, notification-apps, clipboard-history,
                            server-config, pair-mac, qr-scan, adb-setup, logs, daemon-logs, about
  features/selfadb/         use-clip-boot (capture state machine), use-permission-settings, use-daemon-heartbeat, client (module re-export)
  features/files/           use-file-history (the Files screen's data)
  features/pairing/         pairing-store (SecureStore + QR parse), pairing-context
  features/connection/      server-config (SecureStore relay endpoint), use-relay-status, use-connection-status
  features/telemetry/       use-mac-battery, use-mac-distance, use-mac-stat
  features/clip-history/    use-clip-history
  features/updates/         GitHub-release update check (native) + OTA
  components/               the shared M3 vocabulary (rows, groups, sheets, icons)
```
