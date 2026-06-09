package expo.modules.selfadb

import android.content.Context
import android.os.Build
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
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

  fun isPaired(): Boolean = File(context.filesDir, KEY_FILE).exists()

  fun pair(host: String, port: Int, code: String): Boolean =
    manager.pair(host, port, code)

  fun connect(host: String, port: Int): Boolean =
    manager.connect(host, port)

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
   */
  fun launchDaemon(clipPort: Int): String {
    val inner = "CLASSPATH=$DEX_PATH app_process /system/bin " +
      "--nice-name=$NICE_NAME $MAIN_CLASS $clipPort"
    val cmd = "nohup setsid sh -c '$inner' >$LOG_PATH 2>&1 </dev/null & echo LAUNCHED"
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
    val os = push.openOutputStream()
    os.write(bytes)
    os.flush()
    push.close() // adb CLSE -> remote `cat` sees EOF and writes the file
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
  }

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
    private const val NICE_NAME = "linktomac_clip"
    private const val MAIN_CLASS = "com.grkndev.clipboard.ClipboardAgent"

    private const val KEY_FILE = "adbkey"
    private const val PUB_FILE = "adbkey.pub"
    private const val CERT_FILE = "adbcert.pem"

    private fun loadOrCreateKeyPair(context: Context): KeyPair {
      val priv = File(context.filesDir, KEY_FILE)
      val pub = File(context.filesDir, PUB_FILE)
      if (priv.exists() && pub.exists()) {
        val kf = KeyFactory.getInstance("RSA")
        return KeyPair(
          kf.generatePublic(X509EncodedKeySpec(pub.readBytes())),
          kf.generatePrivate(PKCS8EncodedKeySpec(priv.readBytes()))
        )
      }
      val gen = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
      val kp = gen.generateKeyPair()
      priv.writeBytes(kp.private.encoded)
      pub.writeBytes(kp.public.encoded)
      return kp
    }

    private fun loadOrCreateCertificate(context: Context, kp: KeyPair): Certificate {
      val certFile = File(context.filesDir, CERT_FILE)
      if (certFile.exists()) {
        return certFile.inputStream().use {
          CertificateFactory.getInstance("X.509").generateCertificate(it)
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
