package expo.modules.selfadb

import android.content.Context
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Control plane for the self-ADB clipboard pipeline.
 *
 *   adb (libadb) ── launches ──► ClipTest daemon (shell UID, detached)
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

    Events("onClip", "onLog", "onStatus")

    // Attach UI callbacks to the (possibly already-running) service.
    OnCreate {
      ClipBus.onClip = { text, ts -> sendEvent("onClip", mapOf("text" to text, "ts" to ts)) }
      ClipBus.onLog = { msg -> sendEvent("onLog", mapOf("message" to msg)) }
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
      if (probe(clipPort)) {
        log("daemon already alive on :$clipPort")
      } else {
        log("pushing cliptest.dex -> /data/local/tmp")
        adb.pushAsset("cliptest.dex", "/data/local/tmp/cliptest.dex") { log(it) }
        log("launching detached daemon...")
        log("launch: " + adb.launchDaemon(clipPort))
      }
      // Bridge + (future) relay run in a foreground service -> survives app swipe.
      ClipForegroundService.start(appCtx, clipPort)
      status("connected", "running")
      "running"
    }

    AsyncFunction("writeClipboard") { text: String ->
      val svc = ClipForegroundService.instance ?: throw Exception("service not running")
      svc.write(text)
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
      // App going away: detach UI callbacks but LEAVE the service running.
      ClipBus.onClip = null
      ClipBus.onLog = null
      adb.close()
    }
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
