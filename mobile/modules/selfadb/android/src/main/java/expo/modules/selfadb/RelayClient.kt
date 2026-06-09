package expo.modules.selfadb

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Native relay WebSocket client (OkHttp). Lives in [ClipForegroundService] so it keeps
 * running when the app is backgrounded or swiped away. Connects, joins as "android", and
 * reconnects with exponential backoff. Mirrors the (removed) JS relay-client.ts.
 *
 * OkHttp's `pingInterval` keeps the socket alive and detects a dead peer (it fails the
 * connection if a pong doesn't come back) — so we don't run an app-level ping and don't
 * trip the default read timeout. All state runs on a single-thread executor; OkHttp
 * listener callbacks hop onto it. `sendClip` is safe from any thread.
 */
class RelayClient(
  private val url: String,
  private val token: String,
  private val room: String,
  private val onClipReceived: (String) -> Unit,
  private val onStatus: (status: String, peerOnline: Boolean, error: String?) -> Unit,
  private val log: (String) -> Unit,
) {
  private val http = OkHttpClient.Builder()
    .pingInterval(20, TimeUnit.SECONDS)
    .build()
  private val exec: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

  @Volatile private var ws: WebSocket? = null
  @Volatile private var running = false
  private var peerOnline = false
  private var attempt = 0
  private var reconnectFuture: ScheduledFuture<*>? = null

  fun start() {
    if (running) return
    running = true
    exec.execute { open() }
  }

  fun stop() {
    running = false
    exec.execute {
      cancelReconnect()
      ws?.close(1000, "client stop")
      ws = null
      peerOnline = false
      onStatus("disconnected", false, null)
    }
  }

  fun shutdown() {
    stop()
    exec.shutdown()
  }

  fun sendClip(text: String) {
    if (text.isEmpty()) return
    val (nonce, ct) = ClipCodec.encode(text)
    val msg = JSONObject().put("t", "clip").put("nonce", nonce).put("ct", ct)
    ws?.send(msg.toString())
  }

  private fun open() {
    cancelReconnect()
    onStatus("connecting", peerOnline, null)
    val request = Request.Builder()
      .url(url)
      .addHeader("Authorization", "Bearer $token")
      .build()
    ws = http.newWebSocket(request, listener)
  }

  private val listener = object : WebSocketListener() {
    override fun onOpen(webSocket: WebSocket, response: Response) {
      exec.execute {
        if (!running) return@execute
        val join = JSONObject().put("t", "join").put("room", room).put("device", "android")
        webSocket.send(join.toString())
        onStatus("connected", peerOnline, null)
      }
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
      exec.execute { handle(text) }
    }

    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
      webSocket.close(1000, null)
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
      exec.execute { fail("closed $code") }
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
      exec.execute { fail("error ${t.message}") }
    }
  }

  private fun handle(text: String) {
    val o = try {
      JSONObject(text)
    } catch (e: Exception) {
      return
    }
    when (o.optString("t")) {
      "joined" -> {
        attempt = 0
        peerOnline = false
        val peers = o.optJSONArray("peers")
        if (peers != null) {
          for (i in 0 until peers.length()) if (peers.optString(i) == "mac") peerOnline = true
        }
        onStatus("joined", peerOnline, null)
      }
      "peer" -> {
        if (o.optString("device") == "mac") peerOnline = o.optString("state") == "online"
        onStatus("joined", peerOnline, null)
      }
      "error" -> onStatus("error", peerOnline, o.optString("code") + ": " + o.optString("message"))
      "clip" -> {
        val decoded = ClipCodec.decode(o.optString("ct"))
        if (decoded != null) onClipReceived(decoded)
      }
      "pong" -> {}
    }
  }

  private fun fail(reason: String) {
    log("relay $reason")
    ws = null
    if (!running) return
    val pending = reconnectFuture
    if (pending != null && !pending.isDone) return
    val delay = minOf(1L shl minOf(attempt, 5), 30L) // 1,2,4,8,16,32 -> cap 30s
    attempt++
    onStatus("connecting", peerOnline, reason)
    reconnectFuture = exec.schedule({ if (running) open() }, delay, TimeUnit.SECONDS)
  }

  private fun cancelReconnect() {
    reconnectFuture?.cancel(false)
    reconnectFuture = null
  }
}
