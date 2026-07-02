package expo.modules.selfadb

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
 *   app -> jar : {"cmd":"write","text":"..."}
 *
 * Retries until the jar's ServerSocket is up (it binds shortly after launch).
 */
class ClipBridge(
  private val port: Int,
  private val secret: String?,
  private val onClip: (text: String, ts: Double) -> Unit,
  private val onLog: (String) -> Unit,
) {
  @Volatile private var running = false
  @Volatile private var out: OutputStream? = null
  @Volatile private var sock: Socket? = null
  private var thread: Thread? = null

  fun start() {
    running = true
    thread = Thread({ loop() }, "clip-bridge").also { it.start() }
  }

  private fun loop() {
    var attempt = 0
    while (running) {
      val s = Socket()
      try {
        s.connect(InetSocketAddress("127.0.0.1", port), 2000)
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
        attempt = 0
        onLog("bridge connected :$port")
        val r = BufferedReader(InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))
        var line: String? = r.readLine()
        while (running && line != null) {
          handle(line)
          line = r.readLine()
        }
      } catch (e: Exception) {
        if (running) onLog("bridge retry (${e.message})")
      } finally {
        // Every exit path (clean EOF, IOException, stop()) drops the fd — the old code
        // leaked the socket on an abnormal read error.
        out = null
        sock = null
        try { s.close() } catch (_: Exception) {}
      }
      if (!running) break
      attempt++
      try {
        Thread.sleep(minOf(500L * attempt, 3000L))
      } catch (e: InterruptedException) {
        break
      }
    }
  }

  private fun handle(line: String) {
    try {
      val o = JSONObject(line)
      if (o.optString("type") == "clip") {
        onClip(o.optString("text"), o.optLong("ts").toDouble())
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

  /** Whether we currently hold a live connection to the daemon (vs. retrying). */
  fun isConnected(): Boolean = running && out != null

  fun stop() {
    running = false
    // close() is what actually unblocks a readLine() parked on the socket — interrupt() alone
    // can't, and a bridge stuck here holds the daemon's single (backlog 1) connection slot,
    // so a restarted bridge could never be accept()ed again.
    try { sock?.close() } catch (_: Exception) {}
    thread?.interrupt()
  }
}
