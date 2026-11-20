package expo.modules.selfadb.quic

/**
 * Loader and thin JNI facade for the Rust QUIC core (`mobile/native-src/quic-core`, built into
 * `libquic_core.so` by `build-so.sh`).
 *
 * **Loading is guarded on purpose.** The `.so` only exists for arm64-v8a and is not committed, so an
 * x86_64 emulator, or a build made without running `build-so.sh`, has no library. That must degrade to
 * "QUIC unavailable" ([isAvailable] == false), never to an `UnsatisfiedLinkError` that kills the app.
 *
 * Deliberately pure (no `ClipBus`, no Android types) so it can be unit-tested on the JVM, where the
 * library is never present. It never carries user data: only static strings and an exception class name.
 */
/**
 * The error codes of the Rust client (`error.rs`). The numbers cross the JNI boundary and the names go to logs: both are pinned by
 * `QuicErrorTest` and by `tests/params.rs` on the Rust side. A code never carries data.
 */
enum class QuicError(val code: Int) {
  FpMismatch(1), TokenRejected(2), Timeout(3), LinkLost(4), Protocol(5), Internal(6);

  companion object {
    fun fromCode(code: Int): QuicError? = entries.firstOrNull { it.code == code }
  }
}

/**
 * What the Rust client reports, called on the client's own thread in order. An implementation must hand the work to its own executor
 * and return at once. The method names and signatures are looked up by name from Rust (`jni_api.rs`): rename them in both places.
 */
interface QuicEvents {
  fun onConnected()

  /** [code] is a [QuicError] number. Nothing but `onClosed` can follow. */
  fun onFailed(code: Int)
  fun onSessionLine(line: String)
  fun onPeerEnded()
  fun onDatagram(bytes: ByteArray)

  /** [channel] is a [QuicChannel] type id. */
  fun onUniStream(id: Long, channel: Int)
  fun onStreamData(id: Long, bytes: ByteArray, fin: Boolean)
  fun onStats(rttMs: Long, cwnd: Long, lostPackets: Long, congestionEvents: Long)

  /** 0 = ended cleanly (by us or the peer), otherwise a [QuicError] number (a lost connection is `LinkLost`). */
  fun onClosed(code: Int)
}

/** Why [QuicCore.connect] did not start a client (the Rust side validated what Kotlin handed over). */
enum class ConnectRefusal { Host, Port, Fingerprint, Token, Internal, Unavailable }

sealed class ConnectResult {
  data class Started(val handle: Long) : ConnectResult()
  data class Refused(val reason: ConnectRefusal) : ConnectResult()
}

object QuicCore {
  /** Simple class name of the failure that made the library unavailable (e.g. `UnsatisfiedLinkError`), else null. */
  @Volatile
  var loadFailure: String? = null
    private set

  private val loaded: Boolean by lazy {
    try {
      System.loadLibrary("quic_core")
      true
    } catch (e: UnsatisfiedLinkError) {
      loadFailure = e.javaClass.simpleName
      false
    } catch (e: SecurityException) {
      loadFailure = e.javaClass.simpleName
      false
    }
  }

  /** True when `libquic_core.so` is present for this device's ABI and loaded. */
  fun isAvailable(): Boolean = loaded

  /** `"pong quic-core <version> quinn <version>"`, or null when the library is unavailable. */
  fun ping(): String? = callNative { nativePing() }

  /** `"probe ok"` or `"error: <static reason>"`, or null when the library is unavailable. */
  fun probe(): String? = callNative { nativeProbe() }

  /**
   * Starts a client toward `host:port` (an IP literal; the Mac's LAN address, held in memory only) pinned to the certificate fingerprint
   * [fpHex] and presenting [tokB64]. Returns at once; the outcome arrives as [QuicEvents.onConnected] or [QuicEvents.onFailed].
   */
  fun connect(host: String, port: Int, fpHex: String, tokB64: String, events: QuicEvents): ConnectResult {
    if (!isAvailable()) return ConnectResult.Refused(ConnectRefusal.Unavailable)
    val handle = guarded(-5L) { nativeConnect(host, port, fpHex, tokB64, events) }
    return if (handle > 0) {
      ConnectResult.Started(handle)
    } else {
      ConnectResult.Refused(
        when (handle) {
          -1L -> ConnectRefusal.Host
          -2L -> ConnectRefusal.Port
          -3L -> ConnectRefusal.Fingerprint
          -4L -> ConnectRefusal.Token
          else -> ConnectRefusal.Internal
        },
      )
    }
  }

  /** A line on the session stream (the newline is added). False when it could not be queued. */
  fun sessionWrite(handle: Long, line: String): Boolean = guarded(false) { nativeSessionWrite(handle, line) }

  fun sendDatagram(handle: Long, bytes: ByteArray): Boolean = guarded(false) { nativeSendDatagram(handle, bytes) }

  /** Opens a unidirectional stream of [channel]: its id (> 0), or null. May wait up to 2 s (the peer can be out of stream credit). */
  fun openUni(handle: Long, channel: QuicChannel): Long? = guarded(-1L) { nativeOpenUni(handle, channel.typeId.toInt()) }.takeIf { it > 0 }

  fun streamWrite(handle: Long, id: Long, bytes: ByteArray): Boolean = guarded(false) { nativeStreamWrite(handle, id, bytes) }

  fun streamFinish(handle: Long, id: Long): Boolean = guarded(false) { nativeStreamFinish(handle, id) }

  /** Closes and forgets [handle]. Waits (a few seconds at most) for the close to leave the socket, so call it off the main thread. */
  fun close(handle: Long, code: Int = 0) {
    guarded(Unit) { nativeClose(handle, code) }
  }

  private fun <T> guarded(fallback: T, block: () -> T): T {
    if (!isAvailable()) return fallback
    return try {
      block()
    } catch (e: UnsatisfiedLinkError) {
      loadFailure = e.javaClass.simpleName
      fallback
    }
  }

  private fun callNative(block: () -> String): String? {
    if (!isAvailable()) return null
    return try {
      block()
    } catch (e: UnsatisfiedLinkError) {
      // Loaded, but the entry point is missing: a stale .so built from older sources.
      loadFailure = e.javaClass.simpleName
      null
    }
  }

  @JvmStatic private external fun nativePing(): String

  @JvmStatic private external fun nativeProbe(): String

  @JvmStatic private external fun nativeConnect(host: String, port: Int, fpHex: String, tokB64: String, events: QuicEvents): Long

  @JvmStatic private external fun nativeSessionWrite(handle: Long, line: String): Boolean

  @JvmStatic private external fun nativeSendDatagram(handle: Long, bytes: ByteArray): Boolean

  @JvmStatic private external fun nativeOpenUni(handle: Long, channel: Int): Long

  @JvmStatic private external fun nativeStreamWrite(handle: Long, id: Long, bytes: ByteArray): Boolean

  @JvmStatic private external fun nativeStreamFinish(handle: Long, id: Long): Boolean

  @JvmStatic private external fun nativeClose(handle: Long, code: Int)
}
