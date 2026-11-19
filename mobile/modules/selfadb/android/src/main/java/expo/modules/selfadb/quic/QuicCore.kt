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
}
