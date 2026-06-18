package expo.modules.selfadb

import android.content.Context
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Picks the active transport to the Mac and keeps exactly **one** live at a time, so the Mac
 * never receives a clip twice:
 *
 *   - **LAN preferred.** While the Mac is reachable on the local network (found via mDNS, or a
 *     manual seed host), a [LanClient] is the active link.
 *   - **Relay fallback.** If LAN isn't up within a short grace window — or it drops — a
 *     [RelayClient] takes over (when a relay is configured). When LAN comes back the relay is
 *     dropped again.
 *   - **LAN-only.** With no relay URL configured, the app simply waits for / uses LAN.
 *
 * All decisions run on a single-thread executor; the child clients' callbacks hop onto it so the
 * `lanUp`/active-link state is never raced. Mirrors the lifecycle contract the old single
 * `RelayClient` had, so [ClipForegroundService] just owns one of these.
 */
class ConnectionManager(
  context: Context,
  private val relayUrl: String,
  private val token: String,
  private val room: String,
  private val key: String,
  private val lanEnabled: Boolean,
  private val lanPort: Int,
  private val lanHost: String?,
  private val onClipReceived: (String) -> Unit,
  /** transport is "lan" or "relay"; status/peerOnline/error/attempt mirror the child client. */
  private val onStatus: (transport: String, status: String, peerOnline: Boolean, error: String?, attempt: Int) -> Unit,
  private val log: (String) -> Unit,
) {
  private val appCtx = context.applicationContext
  private val exec: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

  private var lan: LanClient? = null
  private var relay: RelayClient? = null
  private var discovery: LanDiscovery? = null

  @Volatile private var running = false
  private var lanUp = false
  private var lastLanHost: String? = null
  private var fallbackFuture: ScheduledFuture<*>? = null

  private companion object {
    // Wait this long for LAN to authenticate before falling back to the relay.
    const val RELAY_FALLBACK_GRACE_S = 4L
  }

  fun start() {
    if (running) return
    running = true
    post {
      val canLan = lanEnabled && lanPort > 0 && room.isNotEmpty() && key.isNotEmpty()
      if (canLan) {
        startDiscovery()
        lanHost?.takeIf { it.isNotEmpty() }?.let { tryLan(it, lanPort) }
        scheduleRelayFallback()
      } else {
        ensureRelay()
      }
    }
  }

  fun shutdown() {
    running = false
    post {
      cancelFallback()
      discovery?.stop(); discovery = null
      lan?.shutdown(); lan = null
      relay?.shutdown(); relay = null
      lanUp = false
    }
    exec.shutdown()
  }

  fun sendClip(text: String) = post { activeLink()?.let { if (it === lan) lan?.sendClip(text) else relay?.sendClip(text) } }

  fun sendCmd(action: String) = post { if (lanUp) lan?.sendCmd(action) else relay?.sendCmd(action) }

  // ---- internals -----------------------------------------------------------

  private fun activeLink(): Any? = if (lanUp) lan else relay

  private fun startDiscovery() {
    if (discovery != null) return
    discovery = LanDiscovery(
      appCtx,
      room,
      onFound = { host, port -> post { if (running) tryLan(host, port) } },
      log = log,
    ).also { it.start() }
  }

  private fun tryLan(host: String, port: Int) {
    if (!running) return
    if (lan != null && host == lastLanHost) return // already targeting this Mac
    lan?.shutdown()
    lastLanHost = host
    lan = LanClient(
      host = host,
      port = port,
      key = key,
      onClipReceived = onClipReceived,
      onStatus = { status, peerOnline, error, attempt -> post { onLanStatus(status, peerOnline, error, attempt) } },
      log = log,
    ).also { it.start() }
  }

  private fun onLanStatus(status: String, peerOnline: Boolean, error: String?, attempt: Int) {
    if (status == "joined") {
      lanUp = true
      cancelFallback()
      stopRelay() // LAN wins -> ensure a single active link
      onStatus("lan", "joined", true, null, 0)
      return
    }
    // Any non-joined status. A dropped LAN link surfaces as "connecting" (LanClient is already
    // retrying with backoff), NOT "disconnected" — so we key off the lanUp transition, not the
    // status string. If we *had* been up (Wi-Fi off, Mac asleep, network change), the LAN link
    // just died -> fail over to the relay now. LanClient keeps retrying; when it re-auths we
    // switch back (the "joined" branch stops the relay again). During the initial bring-up
    // (lanUp already false) the grace timer governs the first fallback, so don't pre-empt it here.
    if (lanUp) {
      lanUp = false
      log("lan link lost ($status) -> relay fallback")
      ensureRelay()
    }
    if (!relayActive()) onStatus("lan", status, false, error, attempt)
  }

  private fun relayActive(): Boolean = !lanUp && relay != null

  private fun ensureRelay() {
    if (lanUp) return
    if (relayUrl.isEmpty()) return // LAN-only: nothing to fall back to
    if (relay != null) return
    log("relay fallback -> $relayUrl")
    relay = RelayClient(
      url = relayUrl,
      token = token,
      room = room,
      key = key,
      onClipReceived = onClipReceived,
      onStatus = { status, peerOnline, error, attempt -> post { onRelayStatus(status, peerOnline, error, attempt) } },
      log = log,
    ).also { it.start() }
  }

  private fun onRelayStatus(status: String, peerOnline: Boolean, error: String?, attempt: Int) {
    if (lanUp) return // ignore relay chatter while LAN is the active link
    onStatus("relay", status, peerOnline, error, attempt)
  }

  private fun stopRelay() {
    relay?.shutdown()
    relay = null
  }

  private fun scheduleRelayFallback() {
    cancelFallback()
    if (relayUrl.isEmpty()) return
    fallbackFuture = try {
      exec.schedule({ if (running && !lanUp) ensureRelay() }, RELAY_FALLBACK_GRACE_S, TimeUnit.SECONDS)
    } catch (e: RejectedExecutionException) {
      null
    }
  }

  private fun cancelFallback() {
    fallbackFuture?.cancel(false)
    fallbackFuture = null
  }

  private fun post(task: Runnable) {
    try {
      exec.execute(task)
    } catch (e: RejectedExecutionException) {
      // shut down; late callback intentionally dropped
    }
  }
}
