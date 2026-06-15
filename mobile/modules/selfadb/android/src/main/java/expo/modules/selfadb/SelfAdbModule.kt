package expo.modules.selfadb

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
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

  override fun definition() = ModuleDefinition {
    Name("SelfAdb")

    Events("onClip", "onLog", "onStatus", "onRelay")

    // Attach UI callbacks to the (possibly already-running) service.
    OnCreate {
      ClipBus.onClip = { text, ts -> sendEvent("onClip", mapOf("text" to text, "ts" to ts)) }
      ClipBus.onLog = { msg -> sendEvent("onLog", mapOf("message" to msg)) }
      ClipBus.onRelay = { payload -> sendEvent("onRelay", payload) }
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
      val ok = adb.connect(host, port)
      status(if (ok) "connected" else "failed", "idle")
      if (!ok) throw Exception("connect failed (not paired / wrong port)")
      "connected"
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
      // 1. Daemon still alive from a previous run? Attach, touch no adb.
      if (probe(clipPort)) {
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
      try {
        val canToggle = hasSecureSettings()
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
        if (canToggle) setWifiDebug(false) // detached daemon survives; minimise surface
        status("connected", "running")
        "ready"
      } catch (e: AdbPairingRequiredException) {
        // adbd no longer trusts our stored key (common on Samsung/One UI after a
        // wireless-debugging toggle or reboot, which wipes the paired-keys list).
        // isPaired() only checks the local key file, so it lied. Route to the
        // pairing screen for a fresh code instead of dying in an error loop.
        log("adbd requires re-pairing -> need-pair (${e.message})")
        status("failed", "idle")
        "need-pair"
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
      if (!adb.connect(connHost, connEp.second)) {
        status("failed", "idle")
        throw Exception("connect failed after pairing")
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

    // ---- Relay (native WS to the Mac, runs in the foreground service) --------

    /** Persist relay config (url/token/room/peer name) and (re)connect the WS if the service is up. */
    AsyncFunction("setRelay") { url: String, token: String, room: String, peerName: String? ->
      val svc = ClipForegroundService.instance
      if (svc != null) {
        svc.applyRelayConfig(url, token, room, peerName)
      } else {
        ClipForegroundService.saveConfig(appCtx, url, token, room, peerName)
      }
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

    /**
     * Fetch the privileged daemon's own on-device log (`/data/local/tmp/clip.log`: its
     * selftest, "listening", "client connected", "captured -> emit" lines) plus a liveness
     * probe. This is the ground truth for "is the clipboard agent actually running and is
     * the system clip-changed listener firing?". Needs adb, so we (re)connect over mDNS,
     * self-enabling wireless debugging if we hold WRITE_SECURE_SETTINGS, then turn it back
     * off. The detached daemon survives that toggle.
     */
    AsyncFunction("readDaemonLog") {
      val socketUp = probe(ClipForegroundService.DEFAULT_PORT)
      val toggled = if (hasSecureSettings()) setWifiDebug(true) else false
      try {
        val ep = adb.discover(AdbMdns.SERVICE_TYPE_TLS_CONNECT, 8000L)
          ?: return@AsyncFunction "bridge socket: ${if (socketUp) "açık" else "KAPALI"}\n\n" +
            "Cihaz logu okunamadı: kablosuz hata ayıklama yayında değil.\n" +
            "Geliştirici Seçenekleri > Kablosuz hata ayıklama'yı açıp tekrar dene."
        val host = ep.first.hostAddress ?: "127.0.0.1"
        if (!adb.connect(host, ep.second)) {
          return@AsyncFunction "adb bağlanılamadı ($host:${ep.second}) — eşleştirme düşmüş olabilir."
        }
        val alive = adb.runShort("pgrep -f ${AdbManager.NICE_NAME} >/dev/null 2>&1 && echo ÇALIŞIYOR || echo ÖLÜ")
        val log = adb.runShort("cat /data/local/tmp/clip.log 2>/dev/null || echo '(clip.log yok — daemon hiç başlamamış olabilir)'")
        "daemon süreci: $alive\nbridge socket: ${if (socketUp) "açık" else "KAPALI"}\n\n$log"
      } finally {
        if (toggled) setWifiDebug(false)
      }
    }

    AsyncFunction("killDaemon") {
      val r = adb.killDaemon()
      ClipForegroundService.stop(appCtx)
      status("connected", "stopped")
      r
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
      ClipBus.onLog = null
      ClipBus.onRelay = null
      adb.close()
    }
  }

  /** Push (if needed) + launch the detached daemon, then own the bridge in the FGS. */
  private fun deploy(clipPort: Int) {
    if (probe(clipPort)) {
      log("daemon already alive on :$clipPort")
    } else {
      log("pushing clipboard-agent.dex -> /data/local/tmp")
      adb.pushAsset("clipboard-agent.dex", "/data/local/tmp/clipboard-agent.dex") { log(it) }
      log("launching detached daemon...")
      log("launch: " + adb.launchDaemon(clipPort))
    }
    // Bridge + (future) relay run in a foreground service -> survives app swipe.
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

  private fun log(message: String) = ClipBus.log(message)
  private fun status(adbState: String, clipState: String) =
    sendEvent("onStatus", mapOf("adb" to adbState, "clip" to clipState))
}
