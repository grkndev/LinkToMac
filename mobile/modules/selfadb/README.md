# selfadb — the Android native module

The native half of the Link to macOS phone app: an Expo module (Android only) that owns
everything which must keep working **without the JS runtime** — the foreground service, the
relay/LAN link, the E2E codec, clipboard capture, notification/SMS mirroring and file transfer.
`src/SelfAdb.ts` / `src/SelfAdb.types.ts` are the typed JS surface; the Kotlin lives in
`android/src/main/java/expo/modules/selfadb/`.

Fine-grained notes: [`../../CLAUDE.md`](../../CLAUDE.md) (file roles, gotchas, the capture state
machine). Internals and the wire protocol: [`../../../TECHNICAL.md`](../../../TECHNICAL.md) §3
(Android), §5 (protocol, incl. §5.4 files).

## What "selfadb" means

The module can pair with the device's **own** `adbd` (Wireless Debugging, TLS + SPAKE2 via
`libadb-android`), push a dex and launch it through `app_process` as **shell UID**. That
privileged daemon (`ClipboardAgent`) is the only way to read the clipboard in the background
(AOSP focus-gates reads for normal apps). It is a **capability, not a precondition**: without
it the app still does the relay/LAN link, remote lock, telemetry, notification + SMS mirroring,
file transfer and Mac→phone clipboard; capture degrades to the manual paths (the
text-selection toolbar entry and the notification's "Send clipboard").

## Pieces

| File | Role |
|---|---|
| `SelfAdbModule.kt` | The Expo module: JS↔native control plane (all `AsyncFunction`s + `Events`). Only alive while JS is. |
| `ClipForegroundService.kt` | `START_STICKY` foreground service. Owns the bridge, connection, BLE, telemetry, and the **file send pipeline**; restarts and reconnects with no JS (config lives in `SharedPreferences`). |
| `AdbManager.kt` | `libadb-android` wrapper: pair / connect / mDNS discovery / push / launch (supervisor-wrapped) / kill. Key + cert in `filesDir`. |
| `ClipBridge.kt` | Localhost NDJSON client to the daemon (`127.0.0.1:<per-variant port>`), authenticated with a per-install secret. |
| `ClipBus.kt` | Process-wide service↔module bridge: ring buffers (logs, Mac clips), last relay/stat. |
| `ClipCodec.kt` | ChaCha20-Poly1305 **v2 envelope** (AAD = frame type, timestamp, replay cache). Byte-compatible with the Mac's `ClipCodec.swift`. |
| `ConnectionManager.kt` | LAN-preferred / relay-fallback arbiter; exactly one live link; short outbound queue while none is joined. |
| `RelayClient.kt` / `LanClient.kt` | OkHttp WebSocket to the relay / straight to the Mac (HMAC handshake). |
| `LanDiscovery.kt` | `NsdManager` mDNS discovery of the Mac. |
| `BleAdvertiser.kt` | BLE presence beacon (the Mac scans and measures distance). |
| `ProcessTextActivity.kt` / `ClipboardReadActivity.kt` | Manual capture paths (selection toolbar; notification action). |
| `NotificationListener.kt` | Mirrors notifications to the Mac (skips both Link to Mac variants' own notifications). |
| `SmsMirror.kt` | Reads the SMS store, resolves contacts, forwards `sms` frames; sends replies via `SmsManager`. |
| `FileFrame.kt` | The `file` frame plaintext (`u16 header-len ‖ header JSON ‖ bytes`), mirror of the Mac's `FileFrame`. |
| `FileInbox.kt` | Reassembles inbound chunked transfers into a temp file; `FileSink` writes the result to `Downloads/Link to Mac` via `MediaStore`. |
| `SendItem.kt` | One outgoing file (staged `File` or content `Uri`) and the deterministic transfer id used for resume. |
| `FolderWalker.kt` | Walks a picked folder tree (`DocumentsContract`) into `SendItem`s with relative `dir`s. |
| `FileHistory.kt` | Bounded JSON history of transfers (`filesDir/file-history.json`) behind the Files screen. |
| `ShareActivity.kt` | The system share-sheet entries ("Send to Clipboard", "Send as a File"). |
| `PickActivity.kt` | Invisible picker host for "Send files" / "Send folder" (persistable read grants). |
| `assets/clipboard-agent.dex` | The prebuilt privileged daemon (built from `../../native-src/clipboard-agent/`). |

Data path: **adb only launches the daemon.** Clipboard data flows over the localhost socket,
never over adb.

## Building

```bash
# From mobile/: the dev client with native code (installs the .dev variant)
bun run android                              # = APP_VARIANT=development expo run:android

# Rebuild the daemon dex ONLY when ClipboardAgent.java changes (output is committed)
cd native-src/clipboard-agent && ./build-dex.sh
```

## Tests

Plain JVM unit tests (no device) cover the file frame, the inbox/sink, the history store
and the folder walker. The file-frame and folder-path vectors in
[`../../../protocol-vectors/`](../../../protocol-vectors) are shared with the Mac's Swift tests,
so the two hand-mirrored implementations can't drift.

```bash
cd mobile/android && ./gradlew :selfadb:testDebugUnitTest
```

## Daemon behaviour

`deployAndRun` launches `ClipboardAgent` **detached** (`setsid` + `nohup`) and **wrapped in a
shell-UID supervisor loop**, so it keeps running after:

- the adb connection drops,
- Wireless debugging is turned off,
- the app is killed,
- lmkd/One UI kills it under memory pressure — the supervisor respawns it in ~3 s with the
  same port and secret (no ADB, no Wi-Fi; exponential back-off on fast deaths, gives up after
  10 in a row).

Only a **reboot or `killDaemon()`** stops it for good (`killDaemon` is two-stage: supervisor
first, then the daemon by exact command line). A reboot also turns Wireless Debugging off and
Samsung may drop adbd's key trust, so re-arming means pairing again.

`deployAndRun` is idempotent: if the daemon is already alive it skips push + launch and just
reattaches the bridge. `stop()` detaches the bridge but leaves the daemon running.

Each app variant (`.dev` and release) runs its daemon on its own port so both can be installed
side by side.

## Module API groups

Boot/ADB (`autoStart`, `pairAuto`, `connect`, `deployAndRun`, `killDaemon`, `restartDaemon`,
`readDaemonLog`, `cancelAdb`, …), relay (`setRelay`, `clearRelay`, `sendCommand`,
`relayGetStatus`, `writeClipboard`), proximity, notification and SMS mirroring (with
`granted | denied | blocked` permission results), diagnostics (`getLogs`, `getMacStat`,
`getClipHistory`), and files (`getFileHistory`, `clearFileHistory`, `openFile`, `pickFiles`,
`pickFolder`, `retryFileSend`, `cancelFileSend`, `openAppSettings`). Events: `onClip`,
`onMacClip`, `onMacStat`, `onLog`, `onStatus`, `onRelay`, `onFileTransfer`. The authoritative
typed list is `src/SelfAdb.ts`.
