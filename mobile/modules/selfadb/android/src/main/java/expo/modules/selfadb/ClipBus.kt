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
  @Volatile var onMacClip: ((String, Double) -> Unit)? = null
  @Volatile var onMacStat: ((String) -> Unit)? = null
  @Volatile var onLog: ((String) -> Unit)? = null
  @Volatile var onRelay: ((Map<String, Any?>) -> Unit)? = null

  /** Last relay state, retained so a late-attaching UI can query it (the service may
   *  have connected long before the app/JS came up). */
  @Volatile var lastRelay: Map<String, Any?>? = null

  /** Last telemetry JSON received from the Mac (e.g. battery), retained so a late-attaching UI can
   *  query it — the service may have received it before the app/JS came up. */
  @Volatile var lastStat: String? = null

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

  /**
   * In-process ring buffer of clips received FROM the Mac (text + capture ts). Retained for the
   * lifetime of the process so the clipboard-history UI can show items that arrived before the
   * JS runtime attached its onMacClip callback (the FGS receives Mac clips even while the app is
   * swiped away). Bounded; lost on a process restart, by design.
   */
  private const val MAX_CLIPS = 100
  private val clipBuffer = ArrayDeque<Map<String, Any?>>(MAX_CLIPS)

  fun clip(text: String, ts: Double) {
    onClip?.invoke(text, ts)
  }

  /** Record + emit a clip received from the Mac. Skips blanks and immediate duplicates. */
  fun macClip(text: String, ts: Double) {
    if (text.isEmpty()) return
    synchronized(clipBuffer) {
      if (clipBuffer.peekLast()?.get("text") == text) return // dedupe immediate repeat
      if (clipBuffer.size >= MAX_CLIPS) clipBuffer.pollFirst()
      clipBuffer.addLast(mapOf("text" to text, "ts" to ts))
    }
    onMacClip?.invoke(text, ts)
  }

  /** Record + emit telemetry JSON received from the Mac (e.g. battery). Retained for late-attaching UI. */
  fun macStat(json: String) {
    if (json.isEmpty()) return
    lastStat = json
    onMacStat?.invoke(json)
  }

  /** Snapshot of received clips, newest-first (matches the UI list order). */
  fun clipHistory(): List<Map<String, Any?>> =
    synchronized(clipBuffer) { clipBuffer.toList().asReversed() }

  fun clearClipHistory() = synchronized(clipBuffer) { clipBuffer.clear() }

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

  fun relay(status: String, peerOnline: Boolean, error: String?, transport: String? = null, attempt: Int = 0) {
    val payload = mapOf(
      "status" to status,
      "peerOnline" to peerOnline,
      "lastError" to error,
      "transport" to transport, // "lan" | "relay" | null (disconnected)
      "attempt" to attempt,     // consecutive reconnect attempts on the active link (0 once joined)
    )
    lastRelay = payload
    onRelay?.invoke(payload)
  }
}
