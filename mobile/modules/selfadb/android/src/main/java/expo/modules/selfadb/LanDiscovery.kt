package expo.modules.selfadb

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Base64
import java.security.MessageDigest
import java.util.ArrayDeque

/**
 * Finds the paired Mac's [LanServer] on the local network via mDNS (`_linktomac._tcp`). The Mac
 * advertises a TXT `rid` derived from the pairing room; we recompute the same `rid` and only report
 * a service whose `rid` matches — so on a multi-Mac LAN we connect to the *right* Mac.
 *
 * This is the "auto-heal" half of the hybrid discovery: a QR/manual host seeds the first connect,
 * and this keeps the address correct after the Mac's DHCP lease changes. Resolves are serialized
 * because [NsdManager] rejects overlapping `resolveService` calls with one listener.
 */
class LanDiscovery(
  context: Context,
  room: String,
  private val onFound: (host: String, port: Int) -> Unit,
  private val log: (String) -> Unit,
) {
  private val appCtx = context.applicationContext
  private val nsd = appCtx.getSystemService(Context.NSD_SERVICE) as NsdManager
  private val expectedRid = serviceId(room)

  private val multicastLock = (appCtx.getSystemService(Context.WIFI_SERVICE) as WifiManager)
    .createMulticastLock("linktomac-mdns")
    .apply { setReferenceCounted(false) }

  @Volatile private var running = false
  private val pending = ArrayDeque<NsdServiceInfo>()
  private var resolving = false

  fun start() {
    if (running) return
    running = true
    try {
      multicastLock.acquire()
      nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    } catch (e: Exception) {
      log("mdns start failed: ${e.message}")
      // Leave no residue: a held multicast lock drains the battery for the whole Wi-Fi
      // session, and running=true would make every later start() a no-op (LAN auto-heal dead).
      releaseFailedStart()
    }
  }

  /** Roll back a failed start so a later [start] can retry cleanly. */
  private fun releaseFailedStart() {
    running = false
    if (multicastLock.isHeld) try { multicastLock.release() } catch (e: Exception) {}
  }

  fun stop() {
    if (!running) return
    running = false
    try {
      nsd.stopServiceDiscovery(discoveryListener)
    } catch (e: Exception) {
      // not registered / already stopped
    }
    if (multicastLock.isHeld) try { multicastLock.release() } catch (e: Exception) {}
  }

  private val discoveryListener = object : NsdManager.DiscoveryListener {
    override fun onDiscoveryStarted(serviceType: String) {}
    override fun onDiscoveryStopped(serviceType: String) {}
    override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
      log("mdns discovery start failed: $errorCode")
      releaseFailedStart()
    }
    override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
    override fun onServiceFound(serviceInfo: NsdServiceInfo) {
      if (serviceInfo.serviceType.trimEnd('.').endsWith(SERVICE_TYPE.trimEnd('.'))) enqueue(serviceInfo)
    }
    override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
  }

  @Synchronized
  private fun enqueue(info: NsdServiceInfo) {
    pending.add(info)
    resolveNext()
  }

  @Synchronized
  private fun resolveNext() {
    if (resolving || pending.isEmpty() || !running) return
    resolving = true
    val info = pending.poll()
    try {
      nsd.resolveService(info, resolveListener)
    } catch (e: Exception) {
      resolving = false
      resolveNext()
    }
  }

  private val resolveListener = object : NsdManager.ResolveListener {
    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
      synchronized(this@LanDiscovery) { resolving = false; resolveNext() }
    }
    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
      synchronized(this@LanDiscovery) { resolving = false; resolveNext() }
      val rid = serviceInfo.attributes["rid"]?.let { String(it, Charsets.UTF_8) }
      if (rid != expectedRid) return // a different Mac on the LAN
      val host = serviceInfo.host?.hostAddress ?: return
      if (running) {
        log("mdns: found Mac at $host:${serviceInfo.port}")
        onFound(host, serviceInfo.port)
      }
    }
  }

  companion object {
    const val SERVICE_TYPE = "_linktomac._tcp."

    /** Stable per-pairing id = base64url(SHA256(room))[:16]; must match the Mac's LanServer.serviceId. */
    fun serviceId(room: String): String {
      val digest = MessageDigest.getInstance("SHA-256").digest(room.toByteArray(Charsets.UTF_8))
      val b64 = Base64.encodeToString(digest, Base64.NO_WRAP)
      val urlSafe = b64.replace('+', '-').replace('/', '_').replace("=", "")
      return urlSafe.take(16)
    }
  }
}
