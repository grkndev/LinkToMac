package expo.modules.selfadb

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import expo.modules.interfaces.permissions.PermissionsStatus
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import io.github.muntashirakon.adb.AdbPairingRequiredException
import io.github.muntashirakon.adb.android.AdbMdns
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Control plane for the self-ADB clipboard pipeline.
 *
 *   adb (libadb) ── launches ──► ClipboardAgent daemon (shell UID, detached)
 *                                      │ localhost:53123
 *   ClipForegroundService ◄───────────┘  (survives app swipe; owns the bridge)
 *        │ ClipBus
 *   this module (UI/control, only while JS alive)
 *
 * adb is used only to launch/relaunch/kill the daemon. The clipboard data path
 * runs in the foreground service, independent of this module's lifetime.
 */
class SelfAdbModule : Module() {

  private val appCtx: Context get() = appContext.reactContext!!.applicationContext
  private val adb by lazy { AdbManager(appCtx) }

  private companion object {
    // Cap the daemon-log read so a single adb transfer never exceeds libadb's
    // maxdata-sized read buffer (which would throw BufferOverflowException). 64 KB still
    // overflowed on One UI (observed 2026-07-06 on a spam-bloated clip.log) — 32 KB holds.
    const val LOG_TAIL_BYTES = 32768

    // How long deploy() waits for the freshly launched daemon to bind its socket before
    // declaring the launch a failure (-> need-connect, instead of a false "ready"). launchDaemon
    // already BLOCKS until the daemon logs `listening` (it must, or adbd's exec: teardown kills
    // the cold-starting daemon — see AdbManager.launchDaemon), so this is just a fast bridge/probe
    // confirmation and is effectively instant on success. Keep it short to bound the failure path.
    const val DAEMON_START_TIMEOUT_MS = 3000L

    // autoStart's fast-path grace window (issue #29): how long + how often to re-poll
    // daemonAlive() before falling through to the ADB path, so a cold-start race with the
    // FGS's own bridge reconnect doesn't wrongly land on the (possibly unrecoverable, e.g.
    // Mobile Hotspot) reconnect screen. ~8 polls over 2.4s — cheap, and short next to the
    // 20s JS-side autoStart timeout.
    const val FAST_PATH_GRACE_MS = 2400L
    const val FAST_PATH_POLL_MS = 300L

    // App-picker icon raster size: 40dp row icons at ~2.5x density. PNGs live in
    // cacheDir/appicons and are served to the UI as file:// URIs.
    const val APP_ICON_PX = 96
  }

  override fun definition() = ModuleDefinition {
    Name("SelfAdb")

    Events("onClip", "onMacClip", "onMacStat", "onLog", "onStatus", "onRelay")

    // Attach UI callbacks to the (possibly already-running) service.
    // Each callback runs on ClipForegroundService's thread, not JS's — a sendEvent() that
    // throws (e.g. the JS bridge mid-teardown on some SDK 56 build) would otherwise propagate
    // out of ClipBus's dispatch and could kill the service thread. Never let one bad event tear
    // down the pipe; just drop it (best-effort UI plumbing, not the data path).
    OnCreate {
      ClipBus.onClip = { text, ts -> safeSendEvent("onClip", mapOf("text" to text, "ts" to ts)) }
      ClipBus.onMacClip = { text, ts -> safeSendEvent("onMacClip", mapOf("text" to text, "ts" to ts)) }
      ClipBus.onMacStat = { json -> parseStat(json)?.let { safeSendEvent("onMacStat", it) } }
      ClipBus.onLog = { msg -> safeSendEvent("onLog", mapOf("message" to msg)) }
      ClipBus.onRelay = { payload -> safeSendEvent("onRelay", payload) }
    }

    AsyncFunction("isPaired") {
      adb.isPaired()
    }

    AsyncFunction("pair") { host: String, port: Int, code: String ->
      log("pairing $host:$port")
      val ok = adb.pair(host, port, code)
      if (!ok) throw Exception("pair failed (wrong code / port / not in pairing mode)")
      "paired"
    }

    AsyncFunction("connect") { host: String, port: Int ->
      status("connecting", "idle")
      log("connecting $host:$port")
      // connect() returns false ONLY when a session is already live (libadb's
      // isConnected() guard) — that's success, not failure. A real failure throws
      // (AdbPairingRequiredException / IOException).
      val fresh = adb.connect(host, port)
      status("connected", "idle")
      if (fresh) "connected" else "already connected"
    }

    AsyncFunction("deployAndRun") { clipPort: Int ->
      deploy(clipPort)
      status("connected", "running")
      "running"
    }

    // ---- Auto-start orchestration (no manual host/port, no taps) ------------

    /**
     * One call drives the whole boot. Returns a state string the JS gate maps
     * to a screen:
     *   "ready"        -> running, show the app
     *   "need-pair"    -> never paired, show PairScreen (collect 6-digit code)
     *   "need-connect" -> paired but wireless debugging unreachable and we can't
     *                     self-enable it yet -> PairScreen reconnect mode
     */
    AsyncFunction("autoStart") { clipPort: Int ->
      // 1. Daemon still alive from a previous run? Attach, touch no adb. Only when we
      //    still hold the secret it was launched with — alive + no persisted secret means
      //    our data was cleared since its launch, the bridge could never authenticate, so
      //    fall through to the ADB path where deploy() restarts it under a fresh secret.
      //    A flapping bridge fails this gate too: holding *a* secret proves nothing when the
      //    daemon keeps dropping us (it was launched by another install with a different
      //    secret — dev/prod fighting over one port). Fall through so deploy() reclaims it.
      //    Give this a FAIR CHANCE on cold start (issue #29): a cold app launch races the
      //    FGS's own START_STICKY restart + bridge reconnect, so a single instant snapshot
      //    can lose that race even though the daemon is already up — e.g. on Mobile Hotspot,
      //    where losing the race means falling into the ADB path, which can NEVER succeed
      //    there (Wireless Debugging needs a Wi-Fi *client* connection). Poll for a short
      //    bounded window instead of sampling once.
      var fastPathReady = false
      val fastPathDeadline = System.currentTimeMillis() + FAST_PATH_GRACE_MS
      while (true) {
        if (
          daemonAlive(clipPort) &&
          ClipForegroundService.getDaemonSecret(appCtx) != null &&
          !bridgeFlapping()
        ) {
          fastPathReady = true
          break
        }
        if (System.currentTimeMillis() >= fastPathDeadline) break
        Thread.sleep(FAST_PATH_POLL_MS)
      }
      if (fastPathReady) {
        log("daemon already alive on :$clipPort")
        ClipForegroundService.start(appCtx, clipPort)
        status("connected", "running")
        return@AsyncFunction "ready"
      }
      // 2. Never paired -> the code can only come from the user.
      if (!adb.isPaired()) {
        log("not paired -> need-pair")
        return@AsyncFunction "need-pair"
      }
      // 3. Paired but daemon dead (typical after reboot). Bring wireless
      //    debugging up ourselves if we hold the permission, then mDNS-connect.
      val canToggle = hasSecureSettings()
      try {
        if (canToggle) {
          log("self-enabling wireless debugging")
          setWifiDebug(true)
        }
        val endpoint = adb.discover(AdbMdns.SERVICE_TYPE_TLS_CONNECT, 8000L)
        if (endpoint == null) {
          log("connect service not advertised -> need-connect")
          return@AsyncFunction "need-connect"
        }
        val host = endpoint.first.hostAddress ?: "127.0.0.1"
        status("connecting", "idle")
        // The libadb Manager is a single instance for the JS-runtime lifetime, so a
        // connection from an earlier pairAuto/autoStart in this session may still be
        // live here — and stale if wireless debugging was toggled since. We only
        // reach this branch with a DEAD daemon that we must redeploy, so force a
        // fresh session: drop any existing link, then connect. (Without this,
        // connect() short-circuits to false on the already-live link — libadb's
        // isConnected() guard, not a failure — which used to throw "connect failed
        // despite mDNS endpoint" and skip the redeploy, looping the reconnect
        // screen. See issue #5.) A genuine failure throws; need-pair is handled below.
        if (adb.isConnected()) {
          log("dropping stale adb session before reconnect")
          adb.disconnect()
        }
        log("connecting $host:${endpoint.second} (mDNS)")
        if (!adb.connect(host, endpoint.second)) {
          status("failed", "idle")
          throw Exception("connect failed despite mDNS endpoint $host:${endpoint.second}")
        }
        status("connected", "idle")
        // If we couldn't self-toggle, the user just enabled it manually -> grab
        // the permission now so every future reboot is silent.
        if (!canToggle) {
          log("grant for future silent reconnects: " + adb.grantSecureSettings(appCtx.packageName))
        }
        deploy(clipPort)
        status("connected", "running")
        "ready"
      } catch (e: DaemonNotStartedException) {
        // Connected over adb but the daemon never bound its socket (flaky first session
        // after a reboot). Surface the reconnect screen instead of a false "ready".
        log("daemon did not start -> need-connect (${e.message})")
        status("failed", "idle")
        "need-connect"
      } catch (e: AdbPairingRequiredException) {
        // adbd no longer trusts our stored key (common on Samsung/One UI after a
        // wireless-debugging toggle or reboot, which wipes the paired-keys list).
        // isPaired() only checks the local key file, so it lied. Route to the
        // pairing screen for a fresh code instead of dying in an error loop.
        log("adbd requires re-pairing -> need-pair (${e.message})")
        status("failed", "idle")
        "need-pair"
      } finally {
        // Every exit — happy, need-connect, throw — turns Wireless Debugging back off if we
        // turned it on (the detached daemon survives; leaving adbd listening after an error
        // path was a needless open surface). Mirrors readDaemonLog's try/finally.
        if (canToggle) setWifiDebug(false)
      }
    }

    /**
     * First-time pairing, fully discovered. The system "Pair device with pairing
     * code" dialog must be open (advertises _adb-tls-pairing). We find it, pair
     * with [code], self-grant WRITE_SECURE_SETTINGS over the fresh adb session,
     * then connect + deploy. After this, reboots never ask for a code again.
     */
    AsyncFunction("pairAuto") { code: String, clipPort: Int ->
      log("discovering pairing service (open the pairing dialog)...")
      val pairEp = adb.discover(AdbMdns.SERVICE_TYPE_TLS_PAIRING, 30000L)
        ?: throw Exception("pairing service not found (open 'Pair device with pairing code')")
      val pairHost = pairEp.first.hostAddress ?: "127.0.0.1"
      log("pairing $pairHost:${pairEp.second}")
      if (!adb.pair(pairHost, pairEp.second, code)) {
        throw Exception("pair failed (wrong code / dialog closed)")
      }
      status("connecting", "idle")
      val connEp = adb.discover(AdbMdns.SERVICE_TYPE_TLS_CONNECT, 8000)
        ?: throw Exception("connect service not found after pairing")
      val connHost = connEp.first.hostAddress ?: "127.0.0.1"
      log("connecting $connHost:${connEp.second} (mDNS)")
      // false = a session is already live (libadb's isConnected() guard), not a
      // failure; real failures throw. Don't mistake the reused link for an error.
      if (!adb.connect(connHost, connEp.second)) {
        log("adb session already live, reusing")
      }
      status("connected", "idle")
      log("grant WRITE_SECURE_SETTINGS: " + adb.grantSecureSettings(appCtx.packageName))
      deploy(clipPort)
      status("connected", "running")
      "ready"
    }

    AsyncFunction("hasSecureSettings") {
      hasSecureSettings()
    }

    // Deep-link to Developer options so the user can reach the pairing dialog.
    AsyncFunction("openWirelessDebuggingSettings") {
      appCtx.startActivity(
        Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      )
    }

    AsyncFunction("writeClipboard") { text: String ->
      val svc = ClipForegroundService.instance ?: throw Exception("service not running")
      svc.write(text)
    }

    /**
     * Liveness of the on-device clipboard daemon, polled by the JS boot hook while "ready".
     * Uses [daemonAlive] (bridge-first), NOT a raw probe: the daemon's ServerSocket has
     * backlog 1 and only serves the bridge, so a competing probe would wrongly fail while the
     * daemon is healthy (and pile up in the accept queue).
     *
     * "Alive" means alive FOR US: a daemon that keeps dropping our bridge (owned by another
     * install) reports false, so the JS heartbeat's miss counter trips a refresh -> autoStart
     * falls past its fast path -> deploy() kills + relaunches the daemon under our secret.
     * Without this the heartbeat sees an open port and the flap never self-heals.
     */
    AsyncFunction("isDaemonAlive") {
      daemonAlive(ClipForegroundService.getClipPort(appCtx)) && !bridgeFlapping()
    }

    // ---- Relay (native WS to the Mac, runs in the foreground service) --------

    /**
     * Persist connection config and (re)connect if the service is up. Carries both the relay
     * endpoint (`url` may be empty for LAN-only) and the LAN-direct params: `lanEnabled` +
     * `lanPort` (0 = LAN off) and an optional `lanHost` manual seed (mDNS is used otherwise).
     */
    AsyncFunction("setRelay") {
      url: String, token: String, room: String, key: String, peerName: String?,
      lanEnabled: Boolean, lanPort: Int, lanHost: String? ->
      val svc = ClipForegroundService.instance
      if (svc != null) {
        svc.applyRelayConfig(url, token, room, key, peerName, lanEnabled, lanPort, lanHost)
      } else {
        ClipForegroundService.saveConfig(appCtx, url, token, room, key, peerName, lanEnabled, lanPort, lanHost)
      }
    }

    /** Send a remote action to the Mac over the relay (e.g. "lock"). Needs the service running. */
    AsyncFunction("sendCommand") { action: String ->
      val svc = ClipForegroundService.instance ?: throw Exception("service not running")
      svc.sendCmd(action)
    }

    /** Unpair: forget the persisted relay config and drop the WS connection. */
    AsyncFunction("clearRelay") {
      val svc = ClipForegroundService.instance
      if (svc != null) {
        svc.clearRelayConfig()
      } else {
        ClipForegroundService.clearConfig(appCtx)
      }
    }

    /** Current relay state, retained across the service/app lifecycle gap. */
    AsyncFunction("relayGetStatus") {
      ClipBus.lastRelay ?: mapOf("status" to "disconnected", "peerOnline" to false, "lastError" to null)
    }

    /** Live pause/resume of outbound (Mac-bound) forwarding; stays connected to receive. */
    AsyncFunction("relaySetPaused") { paused: Boolean ->
      val svc = ClipForegroundService.instance
      if (svc != null) {
        svc.setPaused(paused)
      } else {
        ClipForegroundService.setClipSendPaused(appCtx, paused)
      }
    }

    /** Whether outbound forwarding to the Mac is currently paused (persisted). */
    AsyncFunction("relayIsSendPaused") {
      ClipForegroundService.getClipSendPaused(appCtx)
    }

    // ---- Proximity auto-lock (BLE presence beacon) ---------------------------

    /** Enable/disable advertising the BLE presence beacon (Mac locks when this phone leaves). */
    AsyncFunction("setProximityAdvertise") { enabled: Boolean ->
      val svc = ClipForegroundService.instance
      if (svc != null) {
        svc.setProximityAdvertise(enabled)
      } else {
        ClipForegroundService.setProximityAdvertiseEnabled(appCtx, enabled)
      }
    }

    /** Whether the presence beacon is enabled (persisted, default false). */
    AsyncFunction("getProximityAdvertise") {
      ClipForegroundService.getProximityAdvertise(appCtx)
    }

    /** Whether we hold the Nearby Devices (BLUETOOTH_ADVERTISE) permission. */
    AsyncFunction("hasNearbyDevicesPermission") {
      Build.VERSION.SDK_INT < 31 ||
        appCtx.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
    }

    /** Request the Nearby Devices permission (Android 12+); resolves whether it was granted. */
    AsyncFunction("requestNearbyDevicesPermission") { promise: Promise ->
      if (Build.VERSION.SDK_INT < 31) {
        promise.resolve(true)
        return@AsyncFunction
      }
      val manager = appContext.permissions
      if (manager == null) {
        promise.resolve(false)
        return@AsyncFunction
      }
      manager.askForPermissions({ result ->
        val granted = result[Manifest.permission.BLUETOOTH_ADVERTISE]?.status == PermissionsStatus.GRANTED
        promise.resolve(granted)
      }, Manifest.permission.BLUETOOTH_ADVERTISE)
    }

    /** Whether the FGS notification can be shown (POST_NOTIFICATIONS, Android 13+). */
    AsyncFunction("hasPostNotifications") {
      Build.VERSION.SDK_INT < 33 ||
        appCtx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * Ask for POST_NOTIFICATIONS (Android 13+). Without it the foreground service runs
     * but its sticky notification is silently hidden. Re-posts the notification once
     * granted, since the grant is not retroactive for an already-started service.
     */
    AsyncFunction("requestPostNotifications") { promise: Promise ->
      if (Build.VERSION.SDK_INT < 33) {
        promise.resolve(true)
        return@AsyncFunction
      }
      val manager = appContext.permissions
      if (manager == null) {
        promise.resolve(false)
        return@AsyncFunction
      }
      manager.askForPermissions({ result ->
        val granted = result[Manifest.permission.POST_NOTIFICATIONS]?.status == PermissionsStatus.GRANTED
        if (granted) ClipForegroundService.instance?.refreshNotification()
        promise.resolve(granted)
      }, Manifest.permission.POST_NOTIFICATIONS)
    }

    /** Hide/show the FGS notification's status-bar icon (re-posts on a MIN/LOW channel). */
    AsyncFunction("setStatusNotificationVisible") { visible: Boolean ->
      ClipForegroundService.setStatusNotificationVisible(appCtx, visible)
      ClipForegroundService.instance?.applyStatusNotificationVisibility()
    }

    AsyncFunction("getStatusNotificationVisible") {
      ClipForegroundService.getStatusNotificationVisible(appCtx)
    }

    // ---- Notification mirroring (NotificationListenerService -> Mac) ---------

    /** Whether the user has granted this app "Notification access" (the special access that lets
     *  [NotificationListener] read notifications). Parsed from Settings.Secure to avoid a dep. */
    AsyncFunction("hasNotificationAccess") {
      val cn = ComponentName(appCtx, NotificationListener::class.java)
      val flat = Settings.Secure.getString(appCtx.contentResolver, "enabled_notification_listeners") ?: ""
      flat.split(":").any {
        val c = ComponentName.unflattenFromString(it)
        c != null && c.packageName == cn.packageName && c.className == cn.className
      }
    }

    /** Open the system "Notification access" screen so the user can grant the listener. */
    AsyncFunction("openNotificationAccessSettings") {
      appCtx.startActivity(
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      )
    }

    /** Whether captured notifications are forwarded to the Mac (persisted, default true). Lets the
     *  user pause mirroring without revoking the system access grant. */
    AsyncFunction("getNotificationForwarding") {
      ClipForegroundService.getNotificationForwarding(appCtx)
    }

    AsyncFunction("setNotificationForwarding") { enabled: Boolean ->
      ClipForegroundService.setNotificationForwarding(appCtx, enabled)
    }

    /**
     * Launcher apps for the per-app mirroring picker: [{pkg, label, icon}] sorted by label.
     * Icons are rasterized once to cacheDir/appicons/<pkg>.png and returned as file:// URIs
     * (the @expo/ui Icon loader reads file bitmaps but not data: URIs); re-rasterized when
     * the app updates. Runs on the module's background dispatcher — ~100 icons is real work.
     */
    AsyncFunction("getInstalledApps") {
      val pm = appCtx.packageManager
      val launchables = pm.queryIntentActivities(
        Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0
      )
      val iconDir = File(appCtx.cacheDir, "appicons").apply { mkdirs() }
      launchables
        .distinctBy { it.activityInfo.packageName }
        .filter { it.activityInfo.packageName != appCtx.packageName } // we never mirror our own
        .map { ri ->
          val pkg = ri.activityInfo.packageName
          val iconFile = File(iconDir, "$pkg.png")
          val stale = try {
            iconFile.lastModified() < pm.getPackageInfo(pkg, 0).lastUpdateTime
          } catch (e: Exception) {
            false
          }
          if (!iconFile.exists() || stale) {
            try {
              val bmp = drawableToBitmap(ri.loadIcon(pm), APP_ICON_PX)
              FileOutputStream(iconFile).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            } catch (e: Exception) {
              iconFile.delete() // half-written icon is worse than none
            }
          }
          mapOf(
            "pkg" to pkg,
            "label" to ri.loadLabel(pm).toString(),
            "icon" to if (iconFile.exists()) "file://${iconFile.absolutePath}" else null,
          )
        }
        .sortedBy { (it["label"] as String).lowercase() }
    }

    /** The per-app mirroring filter: mode + both package sets (each mode keeps its own set so
     *  flipping modes doesn't lose the other's selection). */
    AsyncFunction("getNotifAppFilter") {
      mapOf(
        "mode" to ClipForegroundService.getNotifFilterMode(appCtx),
        "include" to ClipForegroundService.getNotifIncludePkgs(appCtx).toList(),
        "exclude" to ClipForegroundService.getNotifExcludePkgs(appCtx).toList(),
      )
    }

    AsyncFunction("setNotifAppFilter") { mode: String, include: List<String>, exclude: List<String> ->
      ClipForegroundService.setNotifAppFilter(appCtx, mode, include, exclude)
    }

    // ---- Image sending (phone clipboard image -> Mac) ------------------------

    AsyncFunction("getSendImages") {
      ClipForegroundService.getSendImages(appCtx)
    }

    AsyncFunction("setSendImages") { enabled: Boolean ->
      ClipForegroundService.setSendImages(appCtx, enabled)
    }

    // ---- Messages mirroring (SMS store -> Mac) -------------------------------

    /** Whether we hold BOTH READ_SMS and READ_CONTACTS (needed to read texts + resolve names). */
    AsyncFunction("hasSmsAccess") {
      appCtx.checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED &&
        appCtx.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
    }

    /** Request READ_SMS + READ_CONTACTS at runtime; resolves whether SMS reading is now possible
     *  (READ_SMS granted — contacts only affect name resolution). On grant, kick an immediate sync. */
    AsyncFunction("requestSmsAccess") { promise: Promise ->
      val manager = appContext.permissions
      if (manager == null) {
        promise.resolve(false)
        return@AsyncFunction
      }
      manager.askForPermissions({ result ->
        val granted = result[Manifest.permission.READ_SMS]?.status == PermissionsStatus.GRANTED
        if (granted) ClipForegroundService.instance?.startSmsMirroring()
        promise.resolve(granted)
      }, Manifest.permission.READ_SMS, Manifest.permission.READ_CONTACTS)
    }

    /** Whether SMS messages are forwarded to the Mac (persisted, default true). Soft pause that
     *  doesn't revoke the OS permission. */
    AsyncFunction("getSmsForwarding") {
      ClipForegroundService.getSmsForwarding(appCtx)
    }

    AsyncFunction("setSmsForwarding") { enabled: Boolean ->
      val svc = ClipForegroundService.instance
      if (svc != null) {
        svc.applySmsForwarding(enabled)
      } else {
        ClipForegroundService.setSmsForwarding(appCtx, enabled)
      }
    }

    /** Force an immediate SMS (re)sync to the Mac — used right after the access grant. */
    AsyncFunction("syncSms") {
      ClipForegroundService.instance?.startSmsMirroring()
    }

    AsyncFunction("hasIgnoreBatteryOptimizations") {
      val pm = appCtx.getSystemService(Context.POWER_SERVICE) as PowerManager
      pm.isIgnoringBatteryOptimizations(appCtx.packageName)
    }

    AsyncFunction("requestIgnoreBatteryOptimizations") {
      appCtx.startActivity(
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
          .setData(Uri.parse("package:" + appCtx.packageName))
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      )
    }

    // ---- Diagnostics / logs --------------------------------------------------

    /** Snapshot of the in-app log ring buffer (oldest first), retained natively across
     *  the JS-runtime gap so the Logs screen shows events from before it attached. */
    AsyncFunction("getLogs") {
      ClipBus.snapshot()
    }

    AsyncFunction("clearLogs") {
      ClipBus.clearBuffer()
    }

    /** Last telemetry received FROM the Mac (e.g. battery `{level,charging}`), or null. Retained
     *  natively across the JS-runtime gap so the UI can seed before the next push. */
    AsyncFunction("getMacStat") {
      ClipBus.lastStat?.let { parseStat(it) }
    }

    /** Retained history of clips received FROM the Mac (newest-first), across the JS-runtime gap. */
    AsyncFunction("getClipHistory") {
      ClipBus.clipHistory()
    }

    AsyncFunction("clearClipHistory") {
      ClipBus.clearClipHistory()
    }

    /**
     * Fetch the privileged daemon's own on-device log (`/data/local/tmp/clip.log`: its
     * selftest, "listening", "client connected", "captured -> emit" lines) plus a liveness
     * probe. This is the ground truth for "is the clipboard agent actually running and is
     * the system clip-changed listener firing?". Needs adb, so we (re)connect over mDNS,
     * self-enabling wireless debugging if we hold WRITE_SECURE_SETTINGS, then turn it back
     * off. The detached daemon survives that toggle.
     */
    AsyncFunction("readDaemonLog") {
      val port = ClipForegroundService.getClipPort(appCtx)
      val socketUp = daemonAlive(port)
      // Preferred path: ask the daemon for its log over the already-open bridge. No adb → no
      // libadb `BufferOverflowException` (which the `tail clip.log` fallback below can hit when a
      // WRTE payload exceeds the device's negotiated maxdata). Only fall back to adb when the
      // bridge isn't connected (daemon reachable but our client isn't attached).
      ClipForegroundService.instance?.requestDaemonLog()?.let { bridgeLog ->
        return@AsyncFunction "bridge socket: open (read via bridge)\n\n$bridgeLog"
      }
      // The bridge wasn't connected -> fall to adb.
      val toggled = if (hasSecureSettings()) setWifiDebug(true) else false
      try {
        val ep = adb.discover(AdbMdns.SERVICE_TYPE_TLS_CONNECT, 8000L)
          ?: return@AsyncFunction "bridge socket: ${if (socketUp) "open" else "CLOSED"}\n\n" +
            "Couldn't read the device log: wireless debugging isn't broadcasting.\n" +
            "Enable Developer Options > Wireless debugging and try again."
        val host = ep.first.hostAddress ?: "127.0.0.1"
        // false = a session is already live (libadb's isConnected() guard), not a
        // failure — reuse it. A real connect failure throws and is caught below.
        adb.connect(host, ep.second)
        // -xf: exact-cmdline match isolates the daemon — plain -f would also match the
        // supervisor's cmdline (it embeds the nice-name) and report RUNNING while only
        // the supervisor is alive mid-backoff. The supervisor gets its own status token.
        val alive = adb.runShort(
          "s=DEAD; pgrep -xf '${AdbManager.NICE_PATTERN}' >/dev/null 2>&1 && s=RUNNING; " +
            "pgrep -f '${AdbManager.supPattern(port)}' >/dev/null 2>&1 && s=\"\$s +supervisor\"; echo \$s"
        )
        // Only the tail: clip.log grows unbounded over a long session, and a single
        // adb WRTE payload larger than the negotiated maxdata buffer throws
        // BufferOverflowException in libadb. 64 KB is the most-recent (most useful)
        // slice and stays well under the buffer on every API level.
        val log = adb.runShort("tail -c $LOG_TAIL_BYTES /data/local/tmp/clip.log 2>/dev/null || echo '(no clip.log - the daemon may never have started)'")
        "daemon process: $alive\nbridge socket: ${if (socketUp) "open" else "CLOSED"}\n" +
          "(last ${LOG_TAIL_BYTES / 1024} KB of clip.log)\n\n$log"
      } catch (e: Exception) {
        "Couldn't read the device log: ${e.message ?: e.javaClass.simpleName}\n" +
          "bridge socket: ${if (socketUp) "open" else "CLOSED"}"
      } finally {
        if (toggled) setWifiDebug(false)
      }
    }

    AsyncFunction("killDaemon") {
      val r = adb.killDaemon(ClipForegroundService.getClipPort(appCtx))
      ClipForegroundService.stop(appCtx)
      status("connected", "stopped")
      r
    }

    /**
     * Kill the running daemon and redeploy the bundled dex. The whole point is to load a **rebuilt**
     * `clipboard-agent.dex` after `bun run android`: a live daemon survives app reinstall, and
     * `autoStart` just attaches to it, so new daemon code never runs until it's force-restarted.
     * Needs adb (to push + relaunch), so it (re)connects over mDNS, self-enabling wireless debugging
     * if we hold WRITE_SECURE_SETTINGS, then turns it back off — same dance as `readDaemonLog`.
     */
    AsyncFunction("restartDaemon") { clipPort: Int ->
      val toggled = if (hasSecureSettings()) setWifiDebug(true) else false
      try {
        val ep = adb.discover(AdbMdns.SERVICE_TYPE_TLS_CONNECT, 8000L)
          ?: return@AsyncFunction "Restart failed: wireless debugging isn't broadcasting. " +
            "Enable Developer Options > Wireless debugging and try again."
        adb.connect(ep.first.hostAddress ?: "127.0.0.1", ep.second)
        ClipForegroundService.stop(appCtx)  // drop our bridge so it reconnects to the fresh daemon
        deploy(clipPort, force = true)      // kill the old daemon + push/launch the rebuilt dex
        status("connected", "restarted")
        "Daemon restarted - the new dex is live."
      } catch (e: Exception) {
        "Restart failed: ${e.message ?: e.javaClass.simpleName}"
      } finally {
        if (toggled) setWifiDebug(false)
      }
    }

    // Stop the foreground service (ends clipboard sync). The daemon keeps running.
    AsyncFunction("stop") {
      ClipForegroundService.stop(appCtx)
      adb.close()
      status("idle", "stopped")
    }

    OnDestroy {
      // App going away: detach UI callbacks but LEAVE the service (and relay) running.
      ClipBus.onClip = null
      ClipBus.onMacClip = null
      ClipBus.onMacStat = null
      ClipBus.onLog = null
      ClipBus.onRelay = null
      adb.close()
    }
  }

  /** Parse the Mac's telemetry JSON into an event/result map, or null if it can't be parsed. Keeps
   *  the JS side free of raw-string parsing. The Mac merges battery + BLE proximity into one `stat`
   *  (`{"level":85,"charging":true,"prox":"near","rssi":-67}`) and omits whichever it lacks — a
   *  desktop Mac sends no battery, proximity-off sends no `prox` — so every field is optional and
   *  only present ones are forwarded; the JS hooks each pick out their own and ignore the rest. */
  private fun parseStat(json: String): Map<String, Any?>? = try {
    val o = JSONObject(json)
    val m = HashMap<String, Any?>()
    if (o.has("level")) m["level"] = o.getInt("level")
    if (o.has("charging")) m["charging"] = o.optBoolean("charging", false)
    if (o.has("prox")) m["prox"] = o.optString("prox")           // "near"|"away"|"unseen"|"off"
    if (o.has("rssi")) m["rssi"] = o.getInt("rssi")              // Mac-measured dBm of this phone
    if (m.isEmpty()) null else m
  } catch (e: Exception) {
    null
  }

  /** Push (if needed) + launch the detached daemon, then own the bridge in the FGS.
   *  `force` skips the "already alive" fast path — used by `restartDaemon` to guarantee a rebuilt
   *  dex is actually reloaded (a live daemon survives app reinstall and would otherwise be reused). */
  private fun deploy(clipPort: Int, force: Boolean = false) {
    // The daemon requires its launch secret as the bridge's first line. Reuse the persisted
    // one (a running daemon's expectation can't change); mint one only when absent.
    val hadSecret = ClipForegroundService.getDaemonSecret(appCtx) != null
    val secret = ClipForegroundService.getOrCreateDaemonSecret(appCtx)
    if (!force && daemonAlive(clipPort) && hadSecret && !bridgeFlapping()) {
      log("daemon already alive on :$clipPort")
    } else {
      if (daemonAlive(clipPort)) {
        // Alive but not OURS: launched under a secret we don't hold (fresh install / cleared
        // data), or it keeps dropping our bridge (another install owns it). Either way it
        // would never serve us — restart it under our secret.
        log("daemon alive but not serving us -> restarting it")
        // Partly redundant with launchDaemon's own self-clean kill, but kept: it frees the
        // port BEFORE the dex push, shrinking the window where an old supervisor could
        // respawn against a half-written dex.
        log("kill: " + adb.killDaemon(clipPort))
      }
      log("pushing clipboard-agent.dex -> /data/local/tmp")
      adb.pushAsset("clipboard-agent.dex", "/data/local/tmp/clipboard-agent.dex") { log(it) }
      log("launching detached daemon...")
      log("launch: " + adb.launchDaemon(clipPort, secret))
      // launchDaemon only echoes LAUNCHED; confirm the daemon actually bound its socket.
      // On the half-trusted first adb session after a reboot the launch can silently fail,
      // and without this check autoStart would report a false "ready" while the bridge loops
      // ECONNREFUSED with no signal to the user.
      if (!waitForDaemon(clipPort, DAEMON_START_TIMEOUT_MS)) {
        throw DaemonNotStartedException("daemon launched but never bound :$clipPort")
      }
    }
    // Bridge + relay run in a foreground service -> survives app swipe.
    ClipForegroundService.start(appCtx, clipPort)
  }

  private fun hasSecureSettings(): Boolean =
    appCtx.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) ==
      PackageManager.PERMISSION_GRANTED

  /** Flip wireless debugging (Settings.Global "adb_wifi_enabled"). Needs WRITE_SECURE_SETTINGS. */
  private fun setWifiDebug(enabled: Boolean): Boolean = try {
    Settings.Global.putInt(appCtx.contentResolver, "adb_wifi_enabled", if (enabled) 1 else 0)
  } catch (e: Exception) {
    log("setWifiDebug(${enabled}) failed: ${e.message}")
    false
  }

  /** adb-free liveness check: can we open the daemon's localhost socket? */
  private fun probe(port: Int): Boolean = try {
    Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 400) }
    true
  } catch (e: Exception) {
    false
  }

  /**
   * Daemon liveness WITHOUT opening a competing socket when possible. The daemon's
   * ServerSocket has backlog 1 and only ever serves the bridge's one connection, so a second
   * probe connection piles up in the accept queue and starts failing even while the daemon is
   * healthy. So: trust the bridge when it's connected; only probe directly when it isn't (then
   * the daemon is back at accept() and a probe is reliable). Bridge is checked first so we
   * never probe in the steady, working state.
   */
  private fun daemonAlive(port: Int): Boolean =
    ClipForegroundService.instance?.isBridgeConnected() == true || probe(port)

  /** The FGS bridge reports the daemon repeatedly accepts-then-drops it — the daemon is owned
   *  by another install (wrong secret or eviction) and must be redeployed, not trusted. */
  private fun bridgeFlapping(): Boolean =
    ClipForegroundService.instance?.isBridgeFlapping() == true

  /** Poll until the daemon binds its socket (or the bridge reconnects) or [timeoutMs] elapses. */
  private fun waitForDaemon(port: Int, timeoutMs: Long): Boolean {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) {
      if (daemonAlive(port)) return true
      try {
        Thread.sleep(300)
      } catch (e: InterruptedException) {
        return daemonAlive(port)
      }
    }
    return daemonAlive(port)
  }

  private fun log(message: String) = ClipBus.log(message)
  private fun status(adbState: String, clipState: String) =
    sendEvent("onStatus", mapOf("adb" to adbState, "clip" to clipState))

  /** `sendEvent` on the service thread, best-effort: a JS-bridge throw here must never take
   *  down the caller (see the `OnCreate` `ClipBus.onFoo` wiring). */
  private fun safeSendEvent(name: String, body: Map<String, Any?>) {
    try {
      sendEvent(name, body)
    } catch (_: Throwable) {
    }
  }
}

/** Thrown by deploy() when the daemon was launched but never bound its socket. */
private class DaemonNotStartedException(message: String) : Exception(message)
