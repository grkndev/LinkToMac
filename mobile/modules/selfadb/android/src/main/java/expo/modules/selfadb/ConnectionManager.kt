package expo.modules.selfadb

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
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
  /** Decrypted telemetry JSON received from the Mac (e.g. battery), from whichever link is active. */
  private val onStatReceived: (String) -> Unit,
  /** transport is "lan" or "relay"; status/peerOnline/error/attempt mirror the child client. */
  private val onStatus: (transport: String, status: String, peerOnline: Boolean, error: String?, attempt: Int) -> Unit,
  private val log: (String) -> Unit,
) {
  private val appCtx = context.applicationContext
  private val cm = appCtx.getSystemService(ConnectivityManager::class.java)
  private val exec: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

  private var lan: LanClient? = null
  private var relay: RelayClient? = null
  private var discovery: LanDiscovery? = null

  @Volatile private var running = false
  private var lanUp = false
  private var lastLanHost: String? = null
  private var fallbackFuture: ScheduledFuture<*>? = null

  /** Computed once in [start]: whether LAN-direct is even a possibility for this config. */
  private var canLan = false
  /** Live set of Wi-Fi networks (from [netCallback]); non-empty == the Mac could be on the LAN. */
  private val wifiNets = HashSet<Network>()
  private var netCallback: ConnectivityManager.NetworkCallback? = null

  private companion object {
    // Wait this long for LAN to authenticate before falling back to the relay.
    const val RELAY_FALLBACK_GRACE_S = 4L
  }

  fun start() {
    if (running) return
    running = true
    post {
      canLan = lanEnabled && lanPort > 0 && room.isNotEmpty() && key.isNotEmpty()
      if (canLan) {
        // Drive LAN off Wi-Fi presence: onAvailable fires immediately for an already-connected
        // Wi-Fi and kicks off discovery + the seed-host connect. The grace timer then falls back
        // to the relay if LAN doesn't join in time — which also covers the no-Wi-Fi (cellular)
        // case, where onAvailable never fires and we go straight to relay after the grace.
        registerWifiCallback()
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
      unregisterWifiCallback()
      stopDiscovery()
      lan?.shutdown(); lan = null
      relay?.shutdown(); relay = null
      lanUp = false
      wifiNets.clear()
    }
    exec.shutdown()
  }

  fun sendClip(text: String) = post { activeLink()?.let { if (it === lan) lan?.sendClip(text) else relay?.sendClip(text) } }

  fun sendCmd(action: String) = post { if (lanUp) lan?.sendCmd(action) else relay?.sendCmd(action) }

  fun sendStat(payload: String) = post { if (lanUp) lan?.sendStat(payload) else relay?.sendStat(payload) }

  fun sendNote(payload: String) = post { if (lanUp) lan?.sendNote(payload) else relay?.sendNote(payload) }

  fun sendSms(payload: String) = post { if (lanUp) lan?.sendSms(payload) else relay?.sendSms(payload) }

  // ---- internals -----------------------------------------------------------

  private fun activeLink(): Any? = if (lanUp) lan else relay

  // ---- Wi-Fi gating ---------------------------------------------------------
  // LAN discovery (mDNS) holds a Wi-Fi multicast lock, which is a real battery cost. The Mac can
  // only be on the LAN when we're on Wi-Fi, so we run discovery *only* while a Wi-Fi network is
  // present (and not already LAN-joined). Off Wi-Fi we drop the lock and lean on the relay.

  private fun registerWifiCallback() {
    if (netCallback != null) return
    if (cm == null) {
      // No ConnectivityManager (shouldn't happen on a real device): degrade to always-on discovery.
      startDiscovery()
      lanHost?.takeIf { it.isNotEmpty() }?.let { tryLan(it, lanPort) }
      return
    }
    val req = NetworkRequest.Builder()
      .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
      .build()
    val cb = object : ConnectivityManager.NetworkCallback() {
      override fun onAvailable(network: Network) { post { onWifiUp(network) } }
      override fun onLost(network: Network) { post { onWifiDown(network) } }
    }
    netCallback = cb
    try {
      cm.registerNetworkCallback(req, cb)
    } catch (e: Exception) {
      log("wifi callback register failed: ${e.message}")
      netCallback = null
      // Degrade gracefully: behave like the old always-on discovery so LAN still works.
      startDiscovery()
      lanHost?.takeIf { it.isNotEmpty() }?.let { tryLan(it, lanPort) }
    }
  }

  private fun unregisterWifiCallback() {
    val cb = netCallback ?: return
    netCallback = null
    try { cm?.unregisterNetworkCallback(cb) } catch (e: Exception) {}
  }

  private fun onWifiUp(network: Network) {
    wifiNets.add(network)
    if (!running || !canLan || lanUp) return
    startDiscovery()
    lanHost?.takeIf { it.isNotEmpty() }?.let { tryLan(it, lanPort) }
    // No new grace timer needed: at startup start() already armed one; on a later Wi-Fi reconnect
    // the relay is already serving, and a LAN "joined" will stop it.
  }

  private fun onWifiDown(network: Network) {
    wifiNets.remove(network)
    if (!running || wifiNets.isNotEmpty()) return // another Wi-Fi still up
    // No Wi-Fi -> LAN is impossible. Release discovery's multicast lock, drop any LAN link, relay.
    stopDiscovery()
    lan?.shutdown(); lan = null; lastLanHost = null
    if (lanUp) {
      lanUp = false
      log("wifi lost -> relay fallback")
    }
    ensureRelay()
  }

  private fun startDiscovery() {
    // An existing instance may have had its start() fail (NsdManager error released its state):
    // start() is a no-op while healthy and a retry after a failure, so call it either way —
    // otherwise a failed discovery stays dead until Wi-Fi cycles.
    discovery?.let { it.start(); return }
    discovery = LanDiscovery(
      appCtx,
      room,
      onFound = { host, port -> post { if (running) tryLan(host, port) } },
      log = log,
    ).also { it.start() }
  }

  private fun stopDiscovery() {
    discovery?.stop()
    discovery = null
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
      onStatReceived = onStatReceived,
      onStatus = { status, peerOnline, error, attempt -> post { onLanStatus(status, peerOnline, error, attempt) } },
      log = log,
    ).also { it.start() }
  }

  private fun onLanStatus(status: String, peerOnline: Boolean, error: String?, attempt: Int) {
    if (status == "joined") {
      lanUp = true
      cancelFallback()
      stopDiscovery() // found & connected -> stop scanning and release the multicast lock
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
      // Re-scan to re-find the Mac (e.g. its DHCP lease changed) while we're still on Wi-Fi.
      if (wifiNets.isNotEmpty()) startDiscovery()
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
      onStatReceived = onStatReceived,
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
