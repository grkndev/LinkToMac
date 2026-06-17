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
 *   jar -> app : {"type":"clip","text":"...","ts":1234}
 *   app -> jar : {"cmd":"write","text":"..."}
 *
 * Retries until the jar's ServerSocket is up (it binds shortly after launch).
 */
class ClipBridge(
  private val port: Int,
  private val onClip: (text: String, ts: Double) -> Unit,
  private val onLog: (String) -> Unit,
) {
  @Volatile private var running = false
  @Volatile private var out: OutputStream? = null
  private var thread: Thread? = null

  fun start() {
    running = true
    thread = Thread({ loop() }, "clip-bridge").also { it.start() }
  }

  private fun loop() {
    var attempt = 0
    while (running) {
      try {
        val s = Socket()
        s.connect(InetSocketAddress("127.0.0.1", port), 2000)
        out = s.getOutputStream()
        attempt = 0
        onLog("bridge connected :$port")
        val r = BufferedReader(InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8))
        var line: String? = r.readLine()
        while (running && line != null) {
          handle(line)
          line = r.readLine()
        }
        out = null
        s.close()
      } catch (e: Exception) {
        out = null
        onLog("bridge retry (${e.message})")
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
    synchronized(o2) {
      o2.write((o.toString() + "\n").toByteArray(StandardCharsets.UTF_8))
      o2.flush()
    }
  }

  /** Whether we currently hold a live connection to the daemon (vs. retrying). */
  fun isConnected(): Boolean = running && out != null

  fun stop() {
    running = false
    thread?.interrupt()
  }
}
