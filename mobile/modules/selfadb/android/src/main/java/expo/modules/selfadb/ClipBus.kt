package expo.modules.selfadb

import android.util.Log
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale

/**
 * Process-wide bridge between the foreground service (which survives the app
 * being swiped away) and the Expo module (which only exists while the JS
 * runtime is alive). The service always posts here; the module attaches/detaches
 * its callbacks in OnCreate/OnDestroy. When the app is gone the callbacks are
 * null and the service simply carries on (logging + future relay forwarding).
 */
object ClipBus {
  @Volatile var onClip: ((String, Double) -> Unit)? = null
  @Volatile var onLog: ((String) -> Unit)? = null
  @Volatile var onRelay: ((Map<String, Any?>) -> Unit)? = null

  /** Last relay state, retained so a late-attaching UI can query it (the service may
   *  have connected long before the app/JS came up). */
  @Volatile var lastRelay: Map<String, Any?>? = null

  /**
   * In-process ring buffer of timestamped log lines. Retained for the lifetime of the
   * process so the Logs screen can show what happened *before* the JS runtime attached
   * its onLog callback (e.g. an FGS reconnect after the app was swiped away). Bounded so
   * it never grows without limit. Lost on a process restart — logcat + the daemon's own
   * on-device log are the durable stores.
   */
  private const val MAX_LINES = 400
  private val buffer = ArrayDeque<String>(MAX_LINES)
  private val tsFormat = SimpleDateFormat("HH:mm:ss", Locale.US)

  fun clip(text: String, ts: Double) {
    onClip?.invoke(text, ts)
  }

  fun log(msg: String) {
    Log.i("LinkToMac", msg) // always in logcat, even when the app is closed
    // SimpleDateFormat isn't thread-safe and log() is called from several threads
    // (relay executor, bridge thread, JS) — keep the format + append under one lock.
    synchronized(buffer) {
      if (buffer.size >= MAX_LINES) buffer.pollFirst()
      buffer.addLast("${tsFormat.format(Date())}  $msg")
    }
    onLog?.invoke(msg)
  }

  /** Snapshot of the retained log lines, oldest first. */
  fun snapshot(): List<String> = synchronized(buffer) { buffer.toList() }

  fun clearBuffer() = synchronized(buffer) { buffer.clear() }

  fun relay(status: String, peerOnline: Boolean, error: String?) {
    val payload = mapOf("status" to status, "peerOnline" to peerOnline, "lastError" to error)
    lastRelay = payload
    onRelay?.invoke(payload)
  }
}
