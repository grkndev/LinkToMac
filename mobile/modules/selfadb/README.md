# selfadb — Step 3 spike

Prove **app-internal self-ADB on Android 14**: from inside the app, spake2-pair
with the device's own `adbd`, TLS-connect, push a dex, launch it via
`app_process` as **shell UID**, and receive **one clipboard event** back over an
on-device localhost socket.

If this works, the whole Link-to-macOS architecture stands. If `libadb-android`
can't do A14 TLS+pairing, fall back to bundling a real `adb` binary (LADB style).

## Pieces

| File | Role |
|------|------|
| `../../native-src/clipboard-agent/ClipboardAgent.java` | Privileged runnable: clipboard read/write + localhost NDJSON socket server |
| `../../native-src/clipboard-agent/build-dex.sh` | `javac` → `d8` → drops `clipboard-agent.dex` into this module's assets |
| `android/.../AdbManager.kt` | **libadb-android wrapper** — pair / connect / exec / pushAsset (⚠️ main VERIFY surface) |
| `android/.../ClipBridge.kt` | On-device localhost client to the jar; emits clip events |
| `android/.../SelfAdbModule.kt` | Expo module: `pair / connect / deployAndRun / writeClipboard / stop` + events |
| `../../src/app/spike.tsx` | Test screen at route `/spike` to drive the flow by hand |

Data path: **adb only launches the jar**. Clipboard data flows over the
localhost socket (127.0.0.1:clipPort), not over adb.

## Build & run

```bash
# 1) build the dex (needs a local Android SDK with build-tools + a platform)
cd mobile
bash native-src/clipboard-agent/build-dex.sh # -> modules/selfadb/android/src/main/assets/clipboard-agent.dex

# 2) verify libadb-android coordinates in modules/selfadb/android/build.gradle
#    (see VERIFY list below) then prebuild + build the dev client
npx expo prebuild -p android
npx expo run:android                         # installs the dev client with native code
```

On the phone:
1. Settings → Developer options → **Wireless debugging → ON**
2. **Pair device with pairing code** → enter the shown `IP:PORT` + 6-digit code on `/spike` → **Pair**
3. Wireless debugging main screen → enter the shown `IP:PORT` (different port) → **Connect**
4. **Deploy & Run** → copy any text on the phone → it appears under **Last clip**
5. Type text + **Write** → it lands in the phone clipboard (paste anywhere to confirm)

## VERIFY against libadb-android (status)

Confirmed against <https://github.com/MuntashirAkon/libadb-android> (v3.1.1 README):

- [x] Coordinates: **JitPack** `com.github.MuntashirAkon:libadb-android:3.1.1`
      + `com.github.MuntashirAkon:sun-security-android:1.1`
      + `org.conscrypt:conscrypt-android:2.5.3` (Maven Central).
- [x] `AbsAdbConnectionManager` overrides: `getPrivateKey / getCertificate / getDeviceName`.
- [x] `setApi(Build.VERSION.SDK_INT)` in the constructor (TLS path).
- [x] Signatures: `pair(host,port,code)`, `connect(host,port)`, `openStream(String)`.
- [x] `AdbStream`: `openInputStream()` / `openOutputStream()`.

Still to confirm at runtime (the actual spike):

- [ ] `openStream("exec:cat > file")` streams **raw binary** cleanly. If `exec:`
      isn't supported, fall back to `shell:` + base64 (`base64 -d > file`).
- [ ] Optional but recommended dep for hidden-API headroom:
      `org.lsposed.hiddenapibypass:hiddenapibypass:6.1`.
- [x] Self-signed cert: **BouncyCastle** (`bcpkix-jdk18on`/`bcprov-jdk18on`) —
      Kotlin can't see `sun.security.x509.*`, so we generate the cert with BC.
- [ ] Whether the device actually accepts the in-app pairing + TLS connect on A14.

## Daemon behaviour (confirmed)

`deployAndRun` launches ClipboardAgent **detached** (`setsid` + `nohup`), so it keeps
running after:

- the adb connection drops,
- **Wireless debugging is turned off**,
- the app is killed.

Only a **reboot, crash, or `killDaemon()`** stops it. The clipboard data flows
over the localhost socket (`127.0.0.1:53123`) — adb is needed **only** to launch
(or relaunch) the daemon, not during steady-state sync.

`deployAndRun` is idempotent: if the daemon is already alive (socket open) it
skips push+launch and just reconnects the bridge — so **no adb is needed** when
the app restarts and the daemon is still up. `stop()` detaches the bridge but
leaves the daemon running; `killDaemon()` (needs adb) terminates it.

> Reboot wipes the daemon **and** turns Wireless debugging off → re-arm needed
> (re-enable wireless debugging, connect, deployAndRun). Same limit as Shizuku.

## Foreground service (done)

`ClipForegroundService` (specialUse, START_STICKY) owns the `ClipBridge`, so the
clipboard pipeline keeps running when the app is **swiped away** — the system
restarts it and it reconnects to the still-running daemon on `:53123`. Captured
clips go to `ClipBus` → UI (when alive) + logcat (`adb logcat -s LinkToMac`).

The **relay client + E2E** is the next thing to add — it goes in this service
(`onClip` TODO), so clips are forwarded to the Mac even with the app fully closed.

> Android 13+: grant the notification permission to see the ongoing notification.
> The service runs either way; verify survival via `adb logcat -s LinkToMac`.

## Known follow-ups

- mDNS (`NsdManager`) auto-discovery of `_adb-tls-pairing._tcp` / `_adb-tls-connect._tcp`
  so the user doesn't type IP:PORT, and to survive port changes on reboot.
- **Relay leg in the service:** WS client + secretbox E2E (Parts 3–5 of `workflow.md`).
- Local socket auth token (stop other apps writing to the jar port).
- POST_NOTIFICATIONS runtime request + battery-optimization exemption prompt.
