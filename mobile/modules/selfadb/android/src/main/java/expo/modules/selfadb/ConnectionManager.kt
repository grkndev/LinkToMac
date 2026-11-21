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
  /** Decrypted `file` plaintext (clipboard image) from the Mac, from whichever link is active. */
  private val onFileReceived: (ByteArray) -> Unit,
  /** Decrypted `sms` JSON from the Mac (an `{"op":"send",…}` reply request), from whichever link
   *  is active. */
  private val onSmsReceived: (String) -> Unit,
  /** Decrypted `cmd` action from the Mac (plain string or `q.*` JSON), from whichever link is active. */
  private val onCmdReceived: (String) -> Unit,
  /** transport is "lan" or "relay"; status/peerOnline/error/attempt mirror the child client. */
  private val onStatus: (transport: String, status: String, peerOnline: Boolean, error: String?, attempt: Int) -> Unit,
  /**
   * The LAN-direct link went away (it was up, now it is not): Wi-Fi lost, the LAN client dropped, or the Mac's address changed. A QUIC session
   * needs that link and ends here (stage 1.8). Called on this manager's thread; do not block.
   */
  private val onLanLost: () -> Unit = {},
  /** The last Mac address that joined ("host:port", remembered from an earlier session): tried as soon as Wi-Fi is up, before mDNS answers. */
  private val rememberedLan: String? = null,
  /** Called on this manager's thread when a LAN link authenticates, so the address can be persisted. Never log what it receives. */
  private val onLanRemember: (host: String, port: Int) -> Unit = { _, _ -> },
  /** Debug builds only: false switches mDNS off so the other ways of finding the Mac can be tested on their own. */
  private val discoveryEnabled: Boolean = true,
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
  /** Relay counterpart of [lanUp]: the relay socket has actually joined its room. A constructed
   *  [RelayClient] is not enough — its `ws?.send` silently no-ops until the socket is up. */
  private var relayJoined = false
  private var lastLanHost: String? = null
  private var lastLanPort = 0

  /** Every address worth trying for the Mac, from mDNS, the Mac's own `stat.lan` hint, the manual seed and the last one that joined. */
  private val book = LanHostBook()

  /**
   * The Mac's LAN address while the LAN link is up, else null: where a QUIC session connects (stage 1.7). Kept in memory only and never
   * logged. A volatile mirror of [lanUp]/[lastLanHost], which are touched on this manager's own thread, so other threads can read it.
   */
  @Volatile private var lanHostInUse: String? = null

  fun activeLanHost(): String? = lanHostInUse
  private var fallbackFuture: ScheduledFuture<*>? = null

  /** Outbound frames produced while no link is joined (service just started, the relay grace
   *  window, a socket still connecting). Replayed FIFO on the next joined edge instead of being
   *  silently lost — a copy made in the first seconds after service start used to vanish. */
  private val pending = ArrayDeque<Pending>()

  /** One outbound frame held in [pending] until a link joins. */
  private sealed class Pending(val ts: Long = System.currentTimeMillis()) {
    class Clip(val text: String) : Pending()
    class File(val payload: ByteArray) : Pending()
    class Cmd(val action: String) : Pending()
  }

  /** Computed once in [start]: whether LAN-direct is even a possibility for this config. */
  private var canLan = false
  /** Live set of Wi-Fi networks (from [netCallback]); non-empty == the Mac could be on the LAN. */
  private val wifiNets = HashSet<Network>()
  private var netCallback: ConnectivityManager.NetworkCallback? = null

  private companion object {
    // Wait this long for LAN to authenticate before falling back to the relay.
    const val RELAY_FALLBACK_GRACE_S = 4L

    // Outbound queue bounds: keep at most this many frames, each for at most this long. The TTL
    // also caps how late a queued `cmd` (e.g. "lock") can fire after the link comes back.
    const val PENDING_MAX = 8
    const val PENDING_TTL_MS = 30_000L
  }

  fun start() {
    if (running) return
    running = true
    post {
      canLan = lanEnabled && lanPort > 0 && room.isNotEmpty() && key.isNotEmpty()
      lanHost?.takeIf { it.isNotEmpty() }?.let { book.add(it, lanPort, LanHostBook.Source.SEED) }
      rememberedLan?.let { raw ->
        val colon = raw.lastIndexOf(':')
        val remPort = if (colon > 0) raw.substring(colon + 1).toIntOrNull() else null
        if (remPort != null) book.add(raw.substring(0, colon), remPort, LanHostBook.Source.REMEMBERED)
      }
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
      lanHostInUse = null
      relayJoined = false
      pending.clear()
      wifiNets.clear()
    }
    exec.shutdown()
  }

  // clip/file/cmd queue while no link is joined and replay on the joined edge (see [pending]).
  // stat/note/sms deliberately don't: they have their own peer-online re-push semantics
  // (ClipForegroundService's pushBatteryStat(force=true) / sms?.backfill() on that edge).

  fun sendClip(text: String) = post { sendOrQueue(Pending.Clip(text)) }

  fun sendFile(payload: ByteArray) = post { sendOrQueue(Pending.File(payload)) }

  fun sendCmd(action: String) = post { sendOrQueue(Pending.Cmd(action)) }

  fun sendStat(payload: String) = post { if (lanUp) lan?.sendStat(payload) else relay?.sendStat(payload) }

  fun sendNote(payload: String) = post { if (lanUp) lan?.sendNote(payload) else relay?.sendNote(payload) }

  fun sendSms(payload: String) = post { if (lanUp) lan?.sendSms(payload) else relay?.sendSms(payload) }

  // ---- internals -----------------------------------------------------------

  private fun linkReady(): Boolean = lanUp || relayJoined

  /** Runs on [exec]. Send now when a link is joined, else hold in [pending] for the next join. */
  private fun sendOrQueue(p: Pending) {
    if (linkReady()) { dispatch(p); return }
    prunePending()
    if (pending.size >= PENDING_MAX) {
      pending.removeFirst()
      log("outbound queue full -> dropped oldest frame")
    }
    pending.addLast(p)
    log("no link joined -> queued outbound ${kind(p)} (${pending.size} pending)")
  }

  /** Routes to whichever link is active — LAN wins, exactly like the pre-queue behavior. */
  private fun dispatch(p: Pending) {
    when (p) {
      is Pending.Clip -> if (lanUp) lan?.sendClip(p.text) else relay?.sendClip(p.text)
      is Pending.File -> if (lanUp) lan?.sendFile(p.payload) else relay?.sendFile(p.payload)
      is Pending.Cmd -> if (lanUp) lan?.sendCmd(p.action) else relay?.sendCmd(p.action)
    }
  }

  /** Runs on [exec], on every joined edge (LAN auth'd or relay room-joined). */
  private fun flushPending() {
    prunePending()
    if (pending.isEmpty()) return
    log("link joined -> flushing ${pending.size} queued frame(s)")
    while (pending.isNotEmpty()) dispatch(pending.removeFirst())
  }

  /** FIFO + monotonic timestamps, so expired frames are only ever at the front. */
  private fun prunePending() {
    val cutoff = System.currentTimeMillis() - PENDING_TTL_MS
    while (pending.isNotEmpty() && pending.first().ts < cutoff) {
      val stale = pending.removeFirst()
      log("queued ${kind(stale)} expired (>${PENDING_TTL_MS / 1000}s unsent) -> dropped")
    }
  }

  private fun kind(p: Pending): String = when (p) {
    is Pending.Clip -> "clip"
    is Pending.File -> "image"
    is Pending.Cmd -> "cmd:${p.action}"
  }

  // ---- Wi-Fi gating ---------------------------------------------------------
  // LAN discovery (mDNS) holds a Wi-Fi multicast lock, which is a real battery cost. The Mac can
  // only be on the LAN when we're on Wi-Fi, so we run discovery *only* while a Wi-Fi network is
  // present (and not already LAN-joined). Off Wi-Fi we drop the lock and lean on the relay.

  private fun registerWifiCallback() {
    if (netCallback != null) return
    if (cm == null) {
      // No ConnectivityManager (shouldn't happen on a real device): degrade to always-on discovery.
      startDiscovery()
      tryBest()
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
      tryBest()
    }
  }

  private fun unregisterWifiCallback() {
    val cb = netCallback ?: return
    netCallback = null
    try { cm?.unregisterNetworkCallback(cb) } catch (e: Exception) {}
  }

  private fun onWifiUp(network: Network) {
    wifiNets.add(network)
    log("wifi up (${wifiNets.size} network(s), lan ${if (lanUp) "joined" else "not joined"})")
    if (!running || !canLan || lanUp) return
    book.resetFailures() // a (re)joined network: an address that failed on the last one may work here
    tryBest()
    startDiscovery()
    // No new grace timer needed: at startup start() already armed one; on a later Wi-Fi reconnect
    // the relay is already serving, and a LAN "joined" will stop it.
  }

  private fun onWifiDown(network: Network) {
    wifiNets.remove(network)
    log("wifi down (${wifiNets.size} network(s) left)")
    if (!running || wifiNets.isNotEmpty()) return // another Wi-Fi still up
    // No Wi-Fi -> LAN is impossible. Release discovery's multicast lock, drop any LAN link, relay.
    stopDiscovery()
    lan?.shutdown(); lan = null; lastLanHost = null
    if (lanUp) {
      lanUp = false
      lanHostInUse = null
      log("wifi lost -> relay fallback")
      onLanLost()
    }
    ensureRelay()
  }

  private fun startDiscovery() {
    if (!discoveryEnabled) {
      log("lan: mDNS discovery is switched off (debug)")
      return
    }
    // An existing instance may have had its start() fail (NsdManager error released its state):
    // start() is a no-op while healthy and a retry after a failure, so call it either way —
    // otherwise a failed discovery stays dead until Wi-Fi cycles.
    discovery?.let { log("lan: discovery already running"); it.start(); return }
    log("lan: starting discovery")
    discovery = LanDiscovery(
      appCtx,
      room,
      onFound = { host, port -> post { if (running) { book.add(host, port, LanHostBook.Source.DISCOVERED); tryLan(host, port) } } },
      log = log,
    ).also { it.start() }
  }

  private fun stopDiscovery() {
    discovery?.stop()
    discovery = null
  }

  /** Try the most preferred address in the book that has not failed; no-op when there is none or it is already the target. */
  private fun tryBest() {
    book.best()?.let { tryLan(it.host, it.port) }
  }

  /** The Mac told us (over any link) where it listens on the LAN. Used right away when we are on Wi-Fi without a LAN link. */
  fun offerLanHints(hints: List<StatLan.Hint>) = post {
    if (!running || !canLan) return@post
    book.offerHints(hints)
    if (!lanUp && wifiNets.isNotEmpty()) {
      log("lan: the Mac announced ${hints.size} address(es)")
      tryBest()
    }
  }

  private fun tryLan(host: String, port: Int) {
    if (!running) return
    if (lan != null && host == lastLanHost && port == lastLanPort) return // already targeting this Mac
    lan?.shutdown()
    lastLanHost = host
    lastLanPort = port
    if (lanHostInUse != null) {
      // The Mac's address changed under a live link: the address a QUIC session was opened to is stale (stage 1.8).
      lanHostInUse = null
      onLanLost()
    }
    lan = LanClient(
      host = host,
      port = port,
      key = key,
      onClipReceived = onClipReceived,
      onStatReceived = onStatReceived,
      onFileReceived = onFileReceived,
      onSmsReceived = onSmsReceived,
      onCmdReceived = onCmdReceived,
      onStatus = { status, peerOnline, error, attempt -> post { onLanStatus(status, peerOnline, error, attempt) } },
      log = log,
    ).also { it.start() }
  }

  private fun onLanStatus(status: String, peerOnline: Boolean, error: String?, attempt: Int) {
    if (status == "joined") {
      lanUp = true
      lanHostInUse = lastLanHost
      lastLanHost?.let { book.markJoined(it, lastLanPort); onLanRemember(it, lastLanPort) }
      cancelFallback()
      stopDiscovery() // found & connected -> stop scanning and release the multicast lock
      stopRelay() // LAN wins -> ensure a single active link
      flushPending() // frames queued while nothing was joined go out over the fresh LAN link
      onStatus("lan", "joined", true, null, 0)
      return
    }
    // Any non-joined status. A dropped LAN link surfaces as "connecting" (LanClient is already
    // retrying with backoff), NOT "disconnected" — so we key off the lanUp transition, not the
    // status string. If we *had* been up (Wi-Fi off, Mac asleep, network change), the LAN link
    // just died -> fail over to the relay now. LanClient keeps retrying; when it re-auths we
    // switch back (the "joined" branch stops the relay again). During the initial bring-up
    // (lanUp already false) the grace timer governs the first fallback, so don't pre-empt it here.
    if (!lanUp && status == "connecting" && attempt >= 1) {
      // The target did not answer (LanClient counts a failed attempt): after two failures the book offers the next address, if any.
      lastLanHost?.let { book.markFailed(it, lastLanPort) }
      tryBest()
    }
    if (lanUp) {
      lanUp = false
      lanHostInUse = null
      log("lan link lost ($status) -> relay fallback")
      onLanLost()
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
    log("falling back to the relay")
    relay = RelayClient(
      url = relayUrl,
      token = token,
      room = room,
      key = key,
      onClipReceived = onClipReceived,
      onStatReceived = onStatReceived,
      onFileReceived = onFileReceived,
      onSmsReceived = onSmsReceived,
      onCmdReceived = onCmdReceived,
      onStatus = { status, peerOnline, error, attempt -> post { onRelayStatus(status, peerOnline, error, attempt) } },
      log = log,
    ).also { it.start() }
  }

  private fun onRelayStatus(status: String, peerOnline: Boolean, error: String?, attempt: Int) {
    // Track the room-joined edge: only then do the relay's `ws?.send` calls actually deliver,
    // so this is the moment queued frames stop being droppable.
    relayJoined = relay != null && status == "joined"
    if (relayJoined && !lanUp) flushPending()
    if (lanUp) return // ignore relay chatter while LAN is the active link
    onStatus("relay", status, peerOnline, error, attempt)
  }

  private fun stopRelay() {
    relay?.shutdown()
    relay = null
    relayJoined = false
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
