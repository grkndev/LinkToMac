package expo.modules.selfadb

import android.util.Base64
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Relay-less **LAN-direct** transport: a WebSocket client straight to the Mac's [LanServer] over
 * the local network (plain `ws://`, no relay, no TLS). Mirrors [RelayClient] (OkHttp, single-thread
 * executor, exponential backoff) but instead of a relay `join` it runs the Mac's challenge-response
 * handshake:
 *
 *   Mac  -> { t:"hello", nonce }
 *   us   -> { t:"auth",  proof = base64(HMAC-SHA256(key, nonce)) }
 *   Mac  -> { t:"ready" }
 *
 * Content frames (`clip`/`cmd`) are still E2E-encrypted with the pairing key via [ClipCodec], so a
 * LAN sniffer learns nothing even without TLS. Once `ready` arrives the Mac peer is considered
 * online (it is the server, so presence == connected).
 */
class LanClient(
  host: String,
  port: Int,
  /** 32-byte pairing secret (base64): proves identity in the handshake AND keys the E2E ClipCodec. */
  private val key: String,
  private val onClipReceived: (String) -> Unit,
  /** Decrypted telemetry JSON received from the Mac (e.g. battery `{"level":85,"charging":true}`). */
  private val onStatReceived: (String) -> Unit,
  private val onStatus: (status: String, peerOnline: Boolean, error: String?, attempt: Int) -> Unit,
  private val log: (String) -> Unit,
) {
  private val url = "ws://$host:$port/ws"
  // 60s keepalive (vs the old 20s): on the LAN there's no NAT/proxy idle timeout to beat and the
  // Mac only auto-replies (never initiates pings), so this is the sole wake source for the link.
  // A dead LAN link (Wi-Fi dropped, Mac asleep) is detected within 60s, then we fall back to relay.
  private val http = OkHttpClient.Builder()
    .pingInterval(60, TimeUnit.SECONDS)
    .build()
  private val exec: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

  @Volatile private var ws: WebSocket? = null
  @Volatile private var running = false
  private var authed = false
  private var attempt = 0
  private var reconnectFuture: ScheduledFuture<*>? = null
  /** Deadline for the hello/auth/ready handshake — a TCP-connected but silent Mac must not
   *  wedge us in "connected" forever (it blocks the LAN/relay arbiter from falling back). */
  private var authDeadline: ScheduledFuture<*>? = null

  fun start() {
    if (running) return
    running = true
    post { open() }
  }

  fun stop() {
    running = false
    post {
      cancelReconnect()
      ws?.close(1000, "client stop")
      ws = null
      authed = false
      onStatus("disconnected", false, null, 0)
    }
  }

  /** Post to the state thread, dropping the task if the executor was shut down (see RelayClient). */
  private fun post(task: Runnable) {
    try {
      exec.execute(task)
    } catch (e: RejectedExecutionException) {
      // shut down; late callback intentionally dropped
    }
  }

  fun shutdown() {
    stop()
    // Full OkHttp teardown (mirrors RelayClient): dispatcher + connection pool would
    // otherwise linger after every Wi-Fi/host cycle.
    post {
      http.dispatcher.executorService.shutdown()
      http.connectionPool.evictAll()
    }
    exec.shutdown()
  }

  fun sendClip(text: String) {
    if (text.isEmpty()) return
    val enc = ClipCodec.encode(text, key)
    if (enc == null) {
      log("lan encrypt failed (bad pairing key); not sending")
      return
    }
    val msg = JSONObject().put("t", "clip").put("nonce", enc.first).put("ct", enc.second)
    ws?.send(msg.toString())
  }

  /** Send a remote action to the Mac (e.g. "lock"), E2E-encrypted like a clip. */
  fun sendCmd(action: String) {
    if (action.isEmpty()) return
    val enc = ClipCodec.encode(action, key)
    if (enc == null) {
      log("lan encrypt failed (bad pairing key); not sending cmd")
      return
    }
    val msg = JSONObject().put("t", "cmd").put("nonce", enc.first).put("ct", enc.second)
    ws?.send(msg.toString())
  }

  /** Send telemetry (this phone's battery + name) to the Mac, E2E-encrypted like a clip. */
  fun sendStat(payload: String) {
    if (payload.isEmpty()) return
    val enc = ClipCodec.encode(payload, key)
    if (enc == null) {
      log("lan encrypt failed (bad pairing key); not sending stat")
      return
    }
    val msg = JSONObject().put("t", "stat").put("nonce", enc.first).put("ct", enc.second)
    ws?.send(msg.toString())
  }

  /** Send a mirrored device notification to the Mac, E2E-encrypted like a clip. */
  fun sendNote(payload: String) {
    if (payload.isEmpty()) return
    val enc = ClipCodec.encode(payload, key)
    if (enc == null) {
      log("lan encrypt failed (bad pairing key); not sending note")
      return
    }
    val msg = JSONObject().put("t", "note").put("nonce", enc.first).put("ct", enc.second)
    ws?.send(msg.toString())
  }

  /** Send a batch/delta of mirrored SMS messages to the Mac, E2E-encrypted like a clip. */
  fun sendSms(payload: String) {
    if (payload.isEmpty()) return
    val enc = ClipCodec.encode(payload, key)
    if (enc == null) {
      log("lan encrypt failed (bad pairing key); not sending sms")
      return
    }
    val msg = JSONObject().put("t", "sms").put("nonce", enc.first).put("ct", enc.second)
    ws?.send(msg.toString())
  }

  private fun open() {
    cancelReconnect()
    authed = false
    onStatus("connecting", false, null, attempt)
    val request = Request.Builder().url(url).build()
    ws = http.newWebSocket(request, listener)
    armAuthDeadline()
  }

  private fun armAuthDeadline() {
    authDeadline?.cancel(false)
    authDeadline = try {
      exec.schedule({
        if (running && !authed) {
          ws?.cancel() // hard-close; the late onFailure callback no-ops against the pending reconnect
          fail("auth timeout (no ready within 7s)")
        }
      }, 7, TimeUnit.SECONDS)
    } catch (e: RejectedExecutionException) {
      null
    }
  }

  private val listener = object : WebSocketListener() {
    override fun onOpen(webSocket: WebSocket, response: Response) {
      post { if (running) onStatus("connected", false, null, attempt) } // awaiting hello/auth
    }

    override fun onMessage(webSocket: WebSocket, text: String) {
      post { handle(webSocket, text) }
    }

    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
      webSocket.close(1000, null)
    }

    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
      post { fail("closed $code") }
    }

    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
      post { fail("error ${t.message}") }
    }
  }

  private fun handle(webSocket: WebSocket, text: String) {
    val o = try {
      JSONObject(text)
    } catch (e: Exception) {
      return
    }
    when (o.optString("t")) {
      "hello" -> {
        val proof = authProof(o.optString("nonce"))
        if (proof == null) {
          fail("auth: bad pairing key")
          return
        }
        webSocket.send(JSONObject().put("t", "auth").put("proof", proof).toString())
      }
      "ready" -> {
        attempt = 0
        authed = true
        authDeadline?.cancel(false)
        authDeadline = null
        onStatus("joined", true, null, 0)
        log("lan authenticated")
      }
      "clip" -> {
        val decoded = ClipCodec.decode(o.optString("nonce"), o.optString("ct"), key)
        if (decoded != null) onClipReceived(decoded) else log("lan clip decrypt failed")
      }
      "stat" -> {
        val decoded = ClipCodec.decode(o.optString("nonce"), o.optString("ct"), key)
        if (decoded != null) onStatReceived(decoded) else log("lan stat decrypt failed")
      }
      "pong" -> {}
    }
  }

  /** base64(HMAC-SHA256(key, nonce)) — proves we hold the pairing secret without sending it. */
  private fun authProof(nonceB64: String): String? = try {
    val keyBytes = Base64.decode(key, Base64.DEFAULT)
    if (keyBytes.size != 32) null else {
      val nonce = Base64.decode(nonceB64, Base64.DEFAULT)
      val mac = Mac.getInstance("HmacSHA256")
      mac.init(SecretKeySpec(keyBytes, "HmacSHA256"))
      Base64.encodeToString(mac.doFinal(nonce), Base64.NO_WRAP)
    }
  } catch (e: Exception) {
    null
  }

  private fun fail(reason: String) {
    log("lan $reason")
    ws = null
    authed = false
    authDeadline?.cancel(false)
    authDeadline = null
    if (!running) return
    val pending = reconnectFuture
    if (pending != null && !pending.isDone) return
    val delay = minOf(1L shl minOf(attempt, 5), 30L) // 1,2,4,8,16,32 -> cap 30s
    attempt++
    onStatus("connecting", false, reason, attempt)
    reconnectFuture = try {
      exec.schedule({ if (running) open() }, delay, TimeUnit.SECONDS)
    } catch (e: RejectedExecutionException) {
      null
    }
  }

  private fun cancelReconnect() {
    reconnectFuture?.cancel(false)
    reconnectFuture = null
  }
}
