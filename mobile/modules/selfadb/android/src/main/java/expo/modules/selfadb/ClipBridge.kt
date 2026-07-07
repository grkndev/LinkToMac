package expo.modules.selfadb

import android.util.Base64
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets

/**
 * On-device localhost client to the privileged ClipboardAgent process.
 *
 *   app -> jar : {"cmd":"auth","secret":"..."}   (first line; daemon serves nothing until it matches)
 *   jar -> app : {"type":"clip","text":"...","ts":1234}
 *   jar -> app : {"type":"image","mime":"image/png","data":"<base64>","ts":1234}
 *   app -> jar : {"cmd":"write","text":"..."}
 *
 * Retries until the jar's ServerSocket is up (it binds shortly after launch).
 */
class ClipBridge(
  private val port: Int,
  private val secret: String?,
  private val onClip: (text: String, ts: Double) -> Unit,
  /** A captured clipboard image from the daemon (Mac-bound). Bytes are the raw file, pre-fit. */
  private val onImage: (mime: String, bytes: ByteArray, ts: Double) -> Unit,
  private val onLog: (String) -> Unit,
) {
  @Volatile private var running = false
  @Volatile private var out: OutputStream? = null
  @Volatile private var sock: Socket? = null
  /** Set by the reader thread when a {"type":"log"} reply arrives; [requestLog] waits on it. */
  private val logLock = Object()
  @Volatile private var pendingLog: String? = null
  /** Consecutive connections the daemon dropped young (< SHORT_LIVED_MS). A streak means the
   *  daemon is closing us on purpose — auth reject (wrong secret) or newest-wins eviction, i.e.
   *  the daemon is owned by another install. Reset by one connection that survives. */
  @Volatile private var shortStreak = 0
  private var thread: Thread? = null

  fun start() {
    running = true
    thread = Thread({ loop() }, "clip-bridge").also { it.start() }
  }

  private fun loop() {
    var attempt = 0
    while (running) {
      val s = Socket()
      var connectedAt = 0L
      try {
        s.connect(InetSocketAddress("127.0.0.1", port), 2000)
        connectedAt = System.currentTimeMillis()
        sock = s // published so stop() can close it out from under a blocked readLine()
        val o = s.getOutputStream()
        // Authenticate FIRST: the daemon serves nothing (not even the initial clip sync)
        // until it sees the launch secret. A pre-auth daemon ignores the unknown cmd.
        secret?.let { sec ->
          val auth = JSONObject().put("cmd", "auth").put("secret", sec)
          o.write((auth.toString() + "\n").toByteArray(StandardCharsets.UTF_8))
          o.flush()
        }
        out = o
        onLog("bridge connected :$port")
        val r = BufferedReader(InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))
        var line: String? = r.readLine()
        while (running && line != null) {
          handle(line)
          line = r.readLine()
        }
      } catch (e: Exception) {
        if (running && connectedAt == 0L) onLog("bridge retry (${e.message})")
      } finally {
        // Every exit path (clean EOF, IOException, stop()) drops the fd — the old code
        // leaked the socket on an abnormal read error.
        out = null
        sock = null
        try { s.close() } catch (_: Exception) {}
      }
      if (!running) break
      // Score the connection that just ended. Only a connection that SURVIVED resets the
      // backoff — a bare TCP connect must not (a daemon that accepts then instantly drops us
      // used to reset `attempt` every cycle, spamming "bridge connected" every 500 ms forever).
      if (connectedAt > 0L) {
        val lived = System.currentTimeMillis() - connectedAt
        if (lived >= SHORT_LIVED_MS) {
          attempt = 0
          shortStreak = 0
        } else {
          shortStreak++
          if (running) onLog("bridge dropped by daemon after ${lived}ms (auth reject or eviction)")
          if (shortStreak == FLAP_THRESHOLD && running) {
            onLog(
              "bridge: daemon keeps dropping us — it was likely launched by another install " +
                "(dev/prod both use :$port). Backing off; next autoStart will redeploy it."
            )
          }
        }
      }
      attempt++
      try {
        // A confirmed drop-streak backs WAY off: the daemon is actively refusing us, so a
        // tight retry only burns battery and floods clip.log until a redeploy fixes ownership.
        val delay = if (shortStreak >= FLAP_THRESHOLD) FLAP_BACKOFF_MS else minOf(500L * attempt, 3000L)
        Thread.sleep(delay)
      } catch (e: InterruptedException) {
        break
      }
    }
  }

  private fun handle(line: String) {
    try {
      val o = JSONObject(line)
      when (o.optString("type")) {
        "clip" -> onClip(o.optString("text"), o.optLong("ts").toDouble())
        "image" -> {
          val bytes = Base64.decode(o.optString("data"), Base64.NO_WRAP)
          onImage(o.optString("mime", "image/png"), bytes, o.optLong("ts").toDouble())
        }
        "log" -> synchronized(logLock) { pendingLog = o.optString("text"); logLock.notifyAll() }
      }
    } catch (e: Exception) {
      onLog("bridge parse err: ${e.message}")
    }
  }

  fun write(text: String) {
    val o = JSONObject().put("cmd", "write").put("text", text)
    val o2 = out ?: return
    try {
      synchronized(o2) {
        o2.write((o.toString() + "\n").toByteArray(StandardCharsets.UTF_8))
        o2.flush()
      }
    } catch (e: Exception) {
      // Callers run on the WS receive thread / a JS promise — an IOException here must not
      // propagate. Drop the stream; the reader loop notices the dead socket and reconnects.
      out = null
      onLog("bridge write failed (${e.message})")
    }
  }

  /** Ask the daemon for its in-memory log (its own diagnostics) over the bridge — no adb, so it
   *  can't hit libadb's `BufferOverflowException`. Sends `{"cmd":"log"}` and blocks (off the main
   *  thread) for the `{"type":"log"}` reply. Returns null if the bridge isn't connected or the
   *  daemon doesn't answer in time. */
  fun requestLog(timeoutMs: Long = 3000): String? {
    val o = out ?: return null
    synchronized(logLock) { pendingLog = null }
    try {
      synchronized(o) {
        o.write((JSONObject().put("cmd", "log").toString() + "\n").toByteArray(StandardCharsets.UTF_8))
        o.flush()
      }
    } catch (e: Exception) {
      onLog("bridge log request failed (${e.message})")
      return null
    }
    synchronized(logLock) {
      val deadline = System.currentTimeMillis() + timeoutMs
      while (pendingLog == null) {
        val wait = deadline - System.currentTimeMillis()
        if (wait <= 0) break
        try { logLock.wait(wait) } catch (e: InterruptedException) { break }
      }
      return pendingLog
    }
  }

  /** Whether we currently hold a live connection to the daemon (vs. retrying). */
  fun isConnected(): Boolean = running && out != null

  /** The daemon keeps accepting then dropping us — wrong secret or another install's client is
   *  evicting ours. autoStart uses this to redeploy the daemon instead of trusting it. */
  fun isFlapping(): Boolean = running && shortStreak >= FLAP_THRESHOLD

  fun stop() {
    running = false
    // close() is what actually unblocks a readLine() parked on the socket — interrupt() alone
    // can't, and a bridge stuck here holds the daemon's single (backlog 1) connection slot,
    // so a restarted bridge could never be accept()ed again.
    try { sock?.close() } catch (_: Exception) {}
    thread?.interrupt()
  }

  private companion object {
    /** A connection that dies younger than this was dropped on purpose (auth reject is
     *  instant; duel evictions cycle sub-second). Genuine idle connections live forever. */
    const val SHORT_LIVED_MS = 3_000L
    /** Consecutive short-lived drops before we call it a flap and back off. */
    const val FLAP_THRESHOLD = 3
    /** Retry interval once flapping is confirmed (vs. the normal 3 s cap). */
    const val FLAP_BACKOFF_MS = 15_000L
  }
}
