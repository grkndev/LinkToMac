package expo.modules.selfadb

import android.content.Context
import android.os.Build
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Date

/**
 * ============================ SPIKE / VERIFY ============================
 * This wraps `libadb-android`. Its exact API is the #1 thing this spike must
 * confirm. Validate every call below against the upstream README + sources:
 *   https://github.com/MuntashirAkon/libadb-android
 *
 * Assumptions made here (fix if they don't compile/work):
 *   - AbsAdbConnectionManager is abstract with overrides:
 *       getPrivateKey(): PrivateKey, getCertificate(): Certificate, getDeviceName(): String
 *   - It exposes:  pair(host,port,code): Boolean,  connect(host,port): Boolean,
 *                  openStream(service: String): AdbStream,  close()
 *   - A settable `api` (Build.VERSION.SDK_INT) is required for TLS path.
 *   - AdbStream exposes openInputStream()/openOutputStream()/close().
 *   - sun.security.x509.* comes from the `sun-security-android` dependency.
 * If openStream signature differs (e.g. takes a LocalServices enum), adapt
 * exec()/pushAsset() accordingly.
 * =======================================================================
 */
class AdbManager(private val context: Context) {

  private val manager: AbsAdbConnectionManager by lazy { Manager(context) }

  fun isPaired(): Boolean =
    File(context.filesDir, KEY_FILE).exists() && File(context.filesDir, PUB_FILE).exists()

  fun pair(host: String, port: Int, code: String): Boolean =
    manager.pair(host, port, code)

  /**
   * Connect, but never block the caller forever. libadb's `manager.connect` does a TLS
   * handshake with **no internal deadline** — if adbd stalls (common right after wireless
   * debugging is toggled on, when mDNS has advertised but adbd isn't ready to handshake yet)
   * it hangs indefinitely, freezing whatever AsyncFunction called it. So run it on a worker
   * thread and join with a deadline; on timeout, drop the half-open session and throw a
   * distinct [AdbConnectTimeoutException] so the caller can surface "try again" instead of
   * spinning. Returns libadb's Boolean (false = a session was already live — reused, not a
   * failure) on success; rethrows a real connect error unchanged.
   */
  fun connect(host: String, port: Int, timeoutMs: Long = CONNECT_TIMEOUT_MS): Boolean {
    val outcome = AtomicReference<Any?>(null) // Boolean on success, Throwable on failure
    val worker = Thread({
      outcome.set(
        try {
          manager.connect(host, port)
        } catch (t: Throwable) {
          t
        },
      )
    }, "adb-connect")
    worker.isDaemon = true
    worker.start()
    worker.join(timeoutMs)
    return when (val r = outcome.get()) {
      is Boolean -> r
      is Throwable -> throw r
      else -> {
        // Still blocked in native connect. disconnect() best-effort unblocks the worker; the
        // caller gets a bounded, actionable failure instead of an endless spinner.
        disconnect()
        throw AdbConnectTimeoutException("adb connect to $host:$port did not complete in $timeoutMs ms")
      }
    }
  }

  /**
   * True while a TLS adb session is live in the shared manager. NOTE: this reads
   * libadb's local connection flag, not the live socket — a session can still
   * report connected after wireless debugging was toggled off (the stale socket
   * isn't noticed until next use). Callers that need a guaranteed-fresh session
   * should [disconnect] first. See SelfAdbModule.autoStart.
   */
  fun isConnected(): Boolean = manager.isConnected()

  /** Drop the current adb session so the next [connect] does a fresh handshake. */
  fun disconnect() {
    try {
      manager.disconnect()
    } catch (_: Exception) {
    }
  }

  /**
   * Block until adbd advertises [serviceType] over mDNS, or [timeoutMs] passes.
   * Uses libadb's NsdManager-backed [AdbMdns]. The pairing service
   * (SERVICE_TYPE_TLS_PAIRING) is only advertised while the system "Pair device
   * with pairing code" dialog is open; the connect service
   * (SERVICE_TYPE_TLS_CONNECT) whenever wireless debugging is on. Returns the
   * first valid host:port, or null on timeout.
   */
  fun discover(serviceType: String, timeoutMs: Long): Pair<InetAddress, Int>? {
    val latch = CountDownLatch(1)
    val result = AtomicReference<Pair<InetAddress, Int>?>(null)
    val mdns = AdbMdns(context, serviceType) { host: InetAddress?, port: Int ->
      if (host != null && port > 0 && result.compareAndSet(null, host to port)) {
        latch.countDown()
      }
    }
    mdns.start()
    return try {
      latch.await(timeoutMs, TimeUnit.MILLISECONDS)
      result.get()
    } finally {
      try {
        mdns.stop()
      } catch (_: Exception) {
      }
    }
  }

  /**
   * Grant ourselves WRITE_SECURE_SETTINGS over the live adb session. Only works
   * because that permission carries the `development` protection flag. Persists
   * across reboot, letting the app self-toggle wireless debugging later with no
   * adb and no pairing code. No-op if already granted.
   */
  fun grantSecureSettings(pkg: String): String =
    runShort("pm grant $pkg android.permission.WRITE_SECURE_SETTINGS; echo GRANT_DONE")

  /**
   * Run a short-lived command over an exec stream and return its stdout. The
   * command executes server-side as soon as the stream opens, so the read is
   * best-effort: a backgrounded (`&`) command can close the stream before we
   * read the ack ("Stream closed") — that's expected, not a failure.
   */
  fun runShort(command: String): String {
    val stream = manager.openStream("exec:$command")
    return try {
      stream.openInputStream().bufferedReader().readText().trim()
    } catch (e: Exception) {
      "(no output: ${e.message})"
    } finally {
      try {
        stream.close()
      } catch (_: Exception) {
      }
    }
  }

  /**
   * Launch the clipboard agent as a DETACHED daemon (Shizuku-style). `setsid` puts it in a
   * new session so adbd's process-group kill can't reach it; `nohup` ignores
   * SIGHUP; stdio is redirected to a log file and /dev/null so it no longer
   * depends on the adb stream. Result: it survives adb disconnect, wireless
   * debugging being turned off, and the app being killed. Only a reboot, a
   * crash, or killDaemon() stops it.
   *
   * CRITICAL: this command must NOT return until the daemon has bound its socket.
   * We launch over libadb's `exec:` service, and adbd kills that service's process
   * group when the stream closes — `nohup setsid` does NOT save a daemon that is
   * still cold-starting (ART/dex load takes ~1-2s). If we returned right after
   * `echo LAUNCHED`, libadb closes the stream mid-startup and the daemon is killed
   * before it ever binds (empty clip.log, nothing on :PORT) -> DaemonNotStarted ->
   * reconnect loop (issue #5). So the foreground here BLOCKS, polling clip.log for
   * the daemon's flushed `listening` line, and only then closes the stream — by
   * which point the daemon is fully detached + bound and survives the close.
   * (Verified: same launch dies via `exec:` when it returns immediately, survives
   * when it waits for `listening`.) `rm` first so a stale log can't false-match.
   */
  fun launchDaemon(clipPort: Int, secret: String? = null): String {
    // The optional second arg is the bridge-auth secret (base64, shell-safe inside the single
    // quotes): the daemon serves nothing on its localhost socket until a client presents it.
    // Other apps can't read our /proc/<pid>/cmdline on modern Android, so it doesn't leak.
    val inner = "CLASSPATH=$DEX_PATH app_process /system/bin " +
      "--nice-name=$NICE_NAME $MAIN_CLASS $clipPort" +
      (secret?.let { " $it" } ?: "")
    val cmd = "rm -f $LOG_PATH; nohup setsid sh -c '$inner' >$LOG_PATH 2>&1 </dev/null & " +
      "i=0; while [ \$i -lt 40 ]; do grep -q listening $LOG_PATH 2>/dev/null && { echo LAUNCHED; exit 0; }; " +
      "sleep 0.2; i=\$((i+1)); done; echo LAUNCH_TIMEOUT"
    return runShort(cmd)
  }

  /** Kill the detached daemon (requires adb connected). */
  fun killDaemon(): String = runShort("pkill -f $NICE_NAME; echo KILLED")

  /**
   * Stream a bundled asset to a device path. Logs each step so a stall is
   * visible. Does NOT read the `cat` stream (reading+writing the same exec
   * stream deadlocks); EOF is signalled by closing it, verification happens
   * on a separate short-lived stream.
   */
  fun pushAsset(assetName: String, devicePath: String, log: (String) -> Unit) {
    val bytes = context.assets.open(assetName).use { it.readBytes() }
    log("asset $assetName = ${bytes.size} bytes")

    val push = manager.openStream("exec:cat > $devicePath")
    log("exec stream opened, writing...")
    try {
      val os = push.openOutputStream()
      os.write(bytes)
      os.flush()
    } finally {
      // Happy path: adb CLSE -> remote `cat` sees EOF and writes the file.
      // Failure path: without this the exec stream leaks on a write error.
      try {
        push.close()
      } catch (_: Exception) {
      }
    }
    log("write done, EOF sent")

    // verify + fix perms on a separate stream that completes quickly
    val verify = manager.openStream("exec:chmod 644 $devicePath; ls -l $devicePath")
    val info = try {
      verify.openInputStream().bufferedReader().readText().trim()
    } catch (e: Exception) {
      "verify failed: ${e.message}"
    } finally {
      try {
        verify.close()
      } catch (_: Exception) {
      }
    }
    log("on device: $info")

    // Byte-count check: a session drop mid-write leaves a truncated file that would otherwise
    // only surface 3 s later as a generic DaemonNotStartedException. `ls -l` above is
    // human-readable metadata; this is the machine check.
    val sizeStream = manager.openStream("exec:wc -c < $devicePath")
    val onDevice = try {
      sizeStream.openInputStream().bufferedReader().readText().trim().toLongOrNull()
    } finally {
      try {
        sizeStream.close()
      } catch (_: Exception) {
      }
    }
    if (onDevice != bytes.size.toLong()) {
      throw AssetTruncatedException(
        "$devicePath is ${onDevice ?: "unreadable"} bytes on device, expected ${bytes.size} - push truncated, retry"
      )
    }
    log("size verified: $onDevice bytes")
  }

  /** The pushed asset didn't land intact (connection drop mid-write). Distinct from a generic
   *  daemon-start failure so callers/logs can say exactly what went wrong. */
  class AssetTruncatedException(message: String) : Exception(message)

  fun close() {
    try {
      manager.close()
    } catch (_: Exception) {
    }
  }

  // -------------------------------------------------------------------------
  private class Manager(context: Context) : AbsAdbConnectionManager() {
    private val keyPair: KeyPair = loadOrCreateKeyPair(context)
    private val cert: Certificate = loadOrCreateCertificate(context, keyPair)

    init {
      // required so the lib uses the Android 11+ TLS path (per upstream README)
      setApi(Build.VERSION.SDK_INT)
    }

    override fun getPrivateKey(): PrivateKey = keyPair.private
    override fun getCertificate(): Certificate = cert
    override fun getDeviceName(): String = "LinkToMac"
  }

  companion object {
    private const val DEX_PATH = "/data/local/tmp/clipboard-agent.dex"
    private const val LOG_PATH = "/data/local/tmp/clip.log"
    /** Deadline for a single libadb `connect` handshake (which has no internal timeout). */
    private const val CONNECT_TIMEOUT_MS = 12_000L
    /** `app_process --nice-name` of the detached daemon; also used to pgrep/kill it. */
    const val NICE_NAME = "linktomac_clip"
    private const val MAIN_CLASS = "com.grkndev.clipboard.ClipboardAgent"

    private const val KEY_FILE = "adbkey"
    private const val PUB_FILE = "adbkey.pub"
    private const val CERT_FILE = "adbcert.pem"

    private fun loadOrCreateKeyPair(context: Context): KeyPair {
      val priv = File(context.filesDir, KEY_FILE)
      val pub = File(context.filesDir, PUB_FILE)
      val cert = File(context.filesDir, CERT_FILE)
      if (priv.exists() && pub.exists()) {
        try {
          val kf = KeyFactory.getInstance("RSA")
          return KeyPair(
            kf.generatePublic(X509EncodedKeySpec(pub.readBytes())),
            kf.generatePrivate(PKCS8EncodedKeySpec(priv.readBytes()))
          )
        } catch (e: Exception) {
          // corrupt key material -> regenerate the whole identity below
        }
      }
      // Key + cert are ONE identity unit: a fresh key invalidates any existing cert (it was
      // signed for the old public key, and adbd would present a mismatched identity while
      // isPaired() still says "paired"). Drop all three, then regenerate key + (lazily) cert.
      priv.delete()
      pub.delete()
      cert.delete()
      val gen = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
      val kp = gen.generateKeyPair()
      priv.writeBytes(kp.private.encoded)
      pub.writeBytes(kp.public.encoded)
      return kp
    }

    private fun loadOrCreateCertificate(context: Context, kp: KeyPair): Certificate {
      val certFile = File(context.filesDir, CERT_FILE)
      if (certFile.exists()) {
        try {
          return certFile.inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it)
          }
        } catch (e: Exception) {
          certFile.delete() // corrupt -> rebuild below for the current key
        }
      }
      val cert = generateSelfSigned(kp)
      certFile.writeBytes(cert.encoded)
      return cert
    }

    /** Self-signed X.509 cert via BouncyCastle (portable; no sun.security.* internals). */
    private fun generateSelfSigned(kp: KeyPair): Certificate {
      val now = System.currentTimeMillis()
      val notBefore = Date(now - 86_400_000L)
      val notAfter = Date(now + 10L * 365 * 86_400_000L)
      val subject = X500Name("CN=LinkToMac, OU=LinkToMac, O=LinkToMac, C=US")
      val serial = BigInteger(64, SecureRandom())

      val builder = JcaX509v3CertificateBuilder(subject, serial, notBefore, notAfter, subject, kp.public)
      val signer = JcaContentSignerBuilder("SHA256withRSA").build(kp.private)
      return JcaX509CertificateConverter().getCertificate(builder.build(signer))
    }
  }
}

/** libadb's `connect` handshake exceeded its deadline (adbd stalled). Distinct from a real
 *  connect failure so callers can prompt a retry instead of a hard error. */
class AdbConnectTimeoutException(message: String) : Exception(message)
