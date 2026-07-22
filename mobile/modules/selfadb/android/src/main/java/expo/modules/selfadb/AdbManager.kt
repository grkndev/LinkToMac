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
import java.net.InetSocketAddress
import java.net.Socket
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
   * Connect, bounded — WITHOUT repeating the reverted 0.8.0 worker-thread hazard (issue #30).
   *
   * `manager.connect()` has two phases and, inspecting the AAR, only one of them was ever
   * bounded:
   *  1. The raw TCP connect (`libadb`'s `AdbConnection` opens a plain two-arg `Socket(host,
   *     port)`). This constructor blocks the CALLING thread with **no timeout at all** — a
   *     half-up adbd that never completes the TCP handshake (Mobile Hotspot, Samsung right
   *     after a Wireless-Debugging toggle) stalls here forever.
   *  2. The ADB protocol handshake, which `AbsAdbConnectionManager.setTimeout()` DOES bound —
   *     but safely: libadb runs the handshake on its OWN persistent thread
   *     (`AdbConnection.mConnectionThread`, started fresh inside `connect()`), and the calling
   *     thread only `Object.wait()`s on a deadline before throwing. We are never the thread the
   *     connection is tied to, so this can't reproduce the "worker exits, kills the connection"
   *     regression that `d21e16e` reverted (that bug came from wrapping the WHOLE call,
   *     including phase 1, in a throwaway Kotlin thread we then abandoned).
   *
   * So: bound phase 1 ourselves with a genuine JDK-bounded preflight on a disposable plain
   * `Socket` (same pattern as `SelfAdbModule.probe()` — closing/abandoning THIS socket can't
   * touch libadb's connection object or its thread, because it isn't libadb's socket), then let
   * `setTimeout()` bound phase 2 before handing off to the library for the real handshake. Both
   * phases throw plain `IOException` on timeout, same as any other real connect failure — no new
   * exception type needed, existing catch sites already treat a thrown `connect()` as failure.
   * `false` = a session was already live (libadb's `isConnected()` guard), not a failure.
   */
  fun connect(host: String, port: Int, timeoutMs: Long = CONNECT_TIMEOUT_MS): Boolean {
    Socket().use { it.connect(InetSocketAddress(host, port), timeoutMs.toInt()) }
    manager.setTimeout(timeoutMs, TimeUnit.MILLISECONDS)
    return manager.connect(host, port)
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
   * Launch the clipboard agent as a DETACHED daemon (Shizuku-style), wrapped in a tiny
   * shell-UID SUPERVISOR loop (issue #31). `setsid` puts the supervisor in a
   * new session so adbd's process-group kill can't reach it; `nohup` ignores
   * SIGHUP; stdio is redirected to a log file and /dev/null so it no longer
   * depends on the adb stream. Result: it survives adb disconnect, wireless
   * debugging being turned off, and the app being killed — and because One UI/lmkd
   * kills the ~50 MB Java daemon under memory pressure even with no reboot (seen
   * in the field), the 1-2 MB supervisor (a far less attractive lmkd target)
   * respawns it with the same port + secret: no ADB, no Wi-Fi, no user. Healthy
   * runs (>=30 s) respawn in 3 s; fast deaths back off 6->12->...->120 s and give
   * up after 10 in a row (bad dex / stolen port — deploy()'s self-heal owns that
   * case, and any later deploy re-arms the supervisor). Only a reboot or
   * killDaemon() stops the pair for good.
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
   * when it waits for `listening`.) `rm` first so a stale log can't false-match;
   * the supervisor's own lines are prefixed `supervisor:` and never contain
   * `listening`, so they can't false-fire the gate either.
   */
  fun launchDaemon(clipPort: Int, secret: String? = null): String {
    // Self-cleaning, and in a SEPARATE exec on purpose: deploy() launches without
    // killing when the daemon is dead, and a leftover supervisor mid-backoff would
    // resurrect the OLD daemon to duel the new one over the port bind. The kill can't
    // ride inside the launch cmd below — the supervisor script (raw marker included)
    // is part of that shell's own cmdline, so an inline pkill would match and kill
    // the launching shell itself before rm/launch ever ran.
    killDaemon(clipPort)
    // The optional second arg is the bridge-auth secret (base64, shell-safe inside the single
    // quotes): the daemon serves nothing on its localhost socket until a client presents it.
    // Other apps can't read our /proc/<pid>/cmdline on modern Android, so it doesn't leak.
    val agent = "CLASSPATH=$DEX_PATH app_process /system/bin " +
      "--nice-name=$NICE_NAME $MAIN_CLASS $clipPort" +
      (secret?.let { " $it" } ?: "")
    // Supervisor script constraints: rides inside sh -c '…' so it must contain NO single
    // quotes; every mksh-side $ is Kotlin-escaped \$; POSIX $(( )) arithmetic + toybox
    // `date +%s` only (no mksh-only $SECONDS). The leading `: marker;` no-op stamps the
    // port-scoped marker into the supervisor's cmdline for supPattern() targeting.
    val inner = ": ${SUP_MARKER}_$clipPort; d=3; f=0; while :; do t=\$(date +%s); $agent; r=\$?; " +
      "u=\$((\$(date +%s)-t)); if [ \$u -ge 30 ]; then d=3; f=0; else f=\$((f+1)); " +
      "[ \$f -ge 10 ] && { echo supervisor: giving up after \$f fast exits; exit 0; }; " +
      "d=\$((d*2)); [ \$d -gt 120 ] && d=120; fi; " +
      "echo supervisor: agent exit rc=\$r after \${u}s, respawn in \${d}s; sleep \$d; done"
    val cmd = "rm -f $LOG_PATH; nohup setsid sh -c '$inner' >$LOG_PATH 2>&1 </dev/null & " +
      "i=0; while [ \$i -lt 40 ]; do grep -q listening $LOG_PATH 2>/dev/null && { echo LAUNCHED; exit 0; }; " +
      "sleep 0.2; i=\$((i+1)); done; echo LAUNCH_TIMEOUT"
    return runShort(cmd)
  }

  /**
   * Kill the daemon AND its supervisor (requires adb connected). Two-stage, supervisor
   * FIRST — a dead supervisor can't resurrect the daemon it just lost. The daemon is
   * then killed by exact-cmdline match (`--nice-name` replaces argv with the bare
   * `linktomac_clip`; comm stays `main` on One UI, so `-x` alone won't find it —
   * verified on-device). `-xf` spares the OTHER variant's supervisor (its cmdline
   * *contains* the nice-name inside the script text but never *equals* it); that
   * variant's daemon is still collateral (identical cmdline — same as before the
   * supervisor existed) and its surviving supervisor respawns it in ~3 s. Backward
   * compatible: a pre-supervisor daemon has the same cmdline, and the supervisor
   * pkill just no-ops.
   */
  fun killDaemon(clipPort: Int): String =
    runShort("pkill -f '${supPattern(clipPort)}'; pkill -xf '$NICE_PATTERN'; echo KILLED")

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
    /** Deadline for EACH bounded phase of [connect] (raw TCP preflight, then the ADB
     *  handshake wait) — not their sum. Matches the original 0.8.0 bound (issue #26). */
    private const val CONNECT_TIMEOUT_MS = 12_000L
    /** `app_process --nice-name` of the detached daemon (= its whole post-nice-name cmdline;
     *  its comm stays `main` on One UI, so match by cmdline, never `pgrep -x`). */
    const val NICE_NAME = "linktomac_clip"
    /** `pgrep/pkill -xf` pattern for the daemon: the [] regex trick means a shell whose own
     *  cmdline contains this pattern text can never match itself, while the daemon's bare
     *  `linktomac_clip` cmdline still exact-matches. */
    const val NICE_PATTERN = "linktomac_cli[p]"
    /** No-op marker (`: linktomac_sup_<port>;`) stamped into the supervisor shell's cmdline
     *  so it can be pgrep/pkill-targeted per port (dev :53125 / prod :53123 supervisors must
     *  not kill each other — both cmdlines contain the shared nice-name). */
    const val SUP_MARKER = "linktomac_sup"
    /** `pgrep/pkill -f` pattern for THIS port's supervisor; same [] self-match-proofing. */
    fun supPattern(port: Int) = "linktomac_su[p]_$port"
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
