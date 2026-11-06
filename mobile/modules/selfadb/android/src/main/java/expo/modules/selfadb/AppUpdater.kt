package expo.modules.selfadb

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Finds a newer native release on GitHub and downloads its APK in the background, so that "update
 * available" is one tap on the system installer instead of a browser download. It NEVER installs:
 * [InstallActivity] hands the verified file to the system installer, which asks the user.
 *
 * Lives with the foreground service, not JS — the periodic check ([schedule]) and the download run
 * with the app swiped away. State is persisted ([UpdateRecord]) so JS, the service and the
 * notification agree across restarts; changes are pushed to JS through [ClipBus.onAppUpdate].
 *
 * One single-thread executor runs everything (check, download, the timer), so the steps of an
 * update never interleave. The platform-free pieces (version compare, release parsing, resume,
 * the record) are in `AppUpdate.kt` and unit tested.
 */
class AppUpdater private constructor(private val ctx: Context) {
  private val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
  private val exec = ScheduledThreadPoolExecutor(1) { r -> Thread(r, "app-updater").apply { isDaemon = true } }
  private val client = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .build()
  private val downloading = AtomicBoolean(false)
  private var timer: ScheduledFuture<*>? = null

  @Volatile private var rec: UpdateRecord = loadRecord()

  /** The persisted record. A download the previous process died in the middle of is not "downloading" any more. */
  private fun loadRecord(): UpdateRecord {
    val r = UpdateRecord.fromJson(prefs.getString(KEY_RECORD, null))
    return if (r.state == UpdateState.DOWNLOADING) r.copy(state = UpdateState.IDLE, progress = 0) else r
  }

  fun record(): UpdateRecord = rec

  fun autoUpdate(): Boolean = prefs.getBoolean(KEY_AUTO, true)

  fun setAutoUpdate(enabled: Boolean) {
    prefs.edit().putBoolean(KEY_AUTO, enabled).apply()
    if (!enabled) ClipBus.log("update: automatic download off")
  }

  /** The verified APK when one is ready to install, else null. */
  fun readyFile(): File? {
    val r = rec
    if (r.state != UpdateState.READY) return null
    return r.path?.let(::File)?.takeIf { it.isFile }
  }

  // --- scheduling -----------------------------------------------------------------------------

  /**
   * Start the periodic check (idempotent — the service calls it on every start). The first one runs
   * shortly after the service comes up so a freshly opened phone doesn't wait hours; a failed one
   * (offline) retries once soon rather than waiting out the whole interval.
   */
  @Synchronized fun schedule() {
    if (timer != null) return
    timer = exec.scheduleWithFixedDelay({ tick(retry = true) }, FIRST_CHECK_S, CHECK_INTERVAL_S, TimeUnit.SECONDS)
  }

  @Synchronized fun cancelSchedule() {
    timer?.cancel(false)
    timer = null
  }

  private fun tick(retry: Boolean) {
    if (!autoUpdate()) return
    val ok = try {
      doCheck(autoDownload = true)
    } catch (e: Exception) {
      ClipBus.log("update: check crashed (${e.message})")
      false
    }
    if (!ok && retry) exec.schedule({ tick(retry = false) }, RETRY_AFTER_MIN, TimeUnit.MINUTES)
  }

  // --- check ----------------------------------------------------------------------------------

  /** Look for a newer release now. [done] gets the record and whether the probe itself worked. */
  fun check(autoDownload: Boolean, done: (UpdateRecord, Boolean) -> Unit) {
    exec.execute {
      val ok = try {
        doCheck(autoDownload)
      } catch (e: Exception) {
        ClipBus.log("update: check failed (${e.message})")
        false
      }
      done(rec, ok)
    }
  }

  /** @return false only when the probe failed (offline / API error) — "no update" is still true. */
  private fun doCheck(autoDownload: Boolean): Boolean {
    val latest = fetchLatest() ?: return false
    val installed = installedVersion()
    if (UpdateLogic.compareVersions(latest.version, installed) <= 0) {
      // Up to date (or we just installed it): nothing pending any more.
      if (rec.release != null) reset()
      return true
    }
    val cur = rec
    val sameVersion = cur.release?.version == latest.version
    if (sameVersion && cur.state == UpdateState.READY && readyFile() != null) {
      publish(cur.copy(release = latest)) // notes may have been edited; the file is already good
      return true
    }
    if (!sameVersion) deleteDownloads()
    // A failed attempt at the same version is retried (the partial file, if any, resumes).
    publish(UpdateRecord(latest))
    ClipBus.log("update: ${latest.version} available (installed $installed)")
    if (autoDownload && latest.apkUrl != null) downloadNow()
    return true
  }

  private fun fetchLatest(): ReleaseInfo? {
    val req = Request.Builder().url(feedUrl()).header("Accept", "application/vnd.github+json").build()
    return try {
      client.newCall(req).execute().use { resp ->
        if (!resp.isSuccessful) return null
        UpdateLogic.parseRelease(resp.body?.string().orEmpty())
      }
    } catch (e: IOException) {
      null
    }
  }

  /** The release feed. A debuggable build may point it elsewhere to rehearse an update end to end. */
  private fun feedUrl(): String {
    val debuggable = ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
    return (if (debuggable) prefs.getString(KEY_FEED_OVERRIDE, null) else null) ?: FEED_URL
  }

  /** Test hook: only honoured by a debuggable build (see [feedUrl]). Pass null to clear. */
  fun setFeedOverride(url: String?) {
    prefs.edit().apply { if (url.isNullOrBlank()) remove(KEY_FEED_OVERRIDE) else putString(KEY_FEED_OVERRIDE, url) }.apply()
  }

  private fun installedVersion(): String =
    ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "0.0.0"

  // --- download -------------------------------------------------------------------------------

  /** Download (or resume) the pending release's APK. [done] gets the record when it settles. */
  fun download(done: (UpdateRecord) -> Unit) {
    exec.execute {
      try {
        downloadNow()
      } catch (e: Exception) {
        ClipBus.log("update: download crashed (${e.message})")
      }
      done(rec)
    }
  }

  private fun downloadNow() {
    val release = rec.release ?: return
    val url = release.apkUrl ?: return
    if (!downloading.compareAndSet(false, true)) return
    try {
      val dir = updatesDir().apply { mkdirs() }
      val finalFile = File(dir, "${release.version}.apk")
      val part = File(dir, "${release.version}.apk.part")

      // Already downloaded (a previous run, or the receiver cleared our record but not the file).
      if (finalFile.isFile) {
        if (verify(finalFile, release) == null) return markReady(finalFile)
        finalFile.delete()
      }

      publish(rec.copy(state = UpdateState.DOWNLOADING, progress = 0, error = null))
      val startAt = UpdateLogic.resumeOffset(part, release.apkSize)
      if (startAt > 0) ClipBus.log("update: resuming ${release.version} at $startAt bytes")
      if (!streamTo(part, release, url, startAt)) {
        // The server refused the range (the leftover isn't a prefix of this file) — start over.
        part.delete()
        streamTo(part, release, url, 0)
      }
      if (release.apkSize > 0 && part.length() != release.apkSize) {
        // Keep the partial file: the next attempt resumes it.
        throw IOException("incomplete download (${part.length()} of ${release.apkSize} bytes)")
      }
      finalFile.delete()
      if (!part.renameTo(finalFile)) throw IOException("couldn't move the download into place")
      val problem = verify(finalFile, release)
      if (problem != null) {
        finalFile.delete()
        part.delete()
        fail(problem)
        return
      }
      markReady(finalFile)
    } catch (e: Exception) {
      fail(e.message ?: "Download failed")
    } finally {
      downloading.set(false)
    }
  }

  /** @return false when the server rejected the Range request (416) and the caller should restart from 0. */
  private fun streamTo(part: File, release: ReleaseInfo, url: String, startAt: Long): Boolean {
    val req = Request.Builder().url(url).apply { if (startAt > 0) header("Range", "bytes=$startAt-") }.build()
    client.newCall(req).execute().use { resp ->
      if (resp.code == 416) return false
      if (!resp.isSuccessful) throw IOException("HTTP ${resp.code}")
      val body = resp.body ?: throw IOException("empty response")
      // 206 = the server honoured the range → append. A plain 200 means it ignored it: rewrite.
      val append = resp.code == 206 && startAt > 0
      var written = if (append) startAt else 0L
      val total = when {
        release.apkSize > 0 -> release.apkSize
        body.contentLength() > 0 -> body.contentLength() + written
        else -> 0L
      }
      FileOutputStream(part, append).use { out ->
        body.byteStream().use { input ->
          val buf = ByteArray(64 * 1024)
          var lastPct = -1
          while (true) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
            written += n
            if (total > 0) {
              // 99 max: 100 is "verified and ready", which only markReady() may claim.
              val pct = (written * 100 / total).toInt().coerceIn(0, 99)
              if (pct != lastPct) {
                lastPct = pct
                publish(rec.copy(progress = pct), persist = false)
              }
            }
          }
        }
      }
    }
    return true
  }

  /**
   * Is this file really the update? Android would refuse a wrongly-signed APK at install time
   * anyway, but checking up front means "ready" is never announced for a file that can't install —
   * and it is what keeps a dev build (different package) from being offered the release APK.
   *
   * @return null when fine, else a short reason.
   */
  @Suppress("DEPRECATION")
  private fun verify(file: File, release: ReleaseInfo): String? {
    release.sha256?.let { expected ->
      if (!UpdateLogic.sha256Hex(file).equals(expected, ignoreCase = true)) return "Checksum mismatch"
    }
    val pm = ctx.packageManager
    val flags = PackageManager.GET_SIGNING_CERTIFICATES
    val archive = pm.getPackageArchiveInfo(file.absolutePath, flags) ?: return "Not a valid APK"
    if (archive.packageName != ctx.packageName) return "Built for a different app (${archive.packageName})"
    val installed = pm.getPackageInfo(ctx.packageName, flags)
    if (archive.longVersionCode <= installed.longVersionCode) return "Not newer than the installed version"
    val theirs = signerHashes(archive)
    if (theirs.isEmpty()) return "Unsigned APK"
    if (theirs.intersect(signerHashes(installed)).isEmpty()) return "Signed with a different key"
    return null
  }

  /** SHA-256 of every certificate the package is (or was, after a key rotation) signed with. */
  private fun signerHashes(info: PackageInfo): Set<String> {
    val signing = info.signingInfo ?: return emptySet()
    val certs = (if (signing.hasMultipleSigners()) signing.apkContentsSigners else signing.signingCertificateHistory)
      ?: return emptySet()
    return certs.map { sig ->
      MessageDigest.getInstance("SHA-256").digest(sig.toByteArray()).joinToString("") { "%02x".format(it) }
    }.toSet()
  }

  private fun markReady(file: File) {
    publish(rec.copy(state = UpdateState.READY, progress = 100, path = file.absolutePath, error = null))
    ClipBus.log("update: ${rec.release?.version} downloaded and verified")
  }

  private fun fail(reason: String) {
    ClipBus.log("update: failed ($reason)")
    publish(rec.copy(state = UpdateState.FAILED, error = reason))
  }

  // --- state ----------------------------------------------------------------------------------

  /** Forget the pending update and its files (after installing it, or when it is no longer newer). */
  fun reset() {
    deleteDownloads()
    publish(UpdateRecord(null))
  }

  private fun updatesDir() = File(ctx.cacheDir, "updates")

  private fun deleteDownloads() {
    updatesDir().listFiles()?.forEach { it.delete() }
  }

  @Synchronized private fun publish(next: UpdateRecord, persist: Boolean = true) {
    rec = next
    if (persist) prefs.edit().putString(KEY_RECORD, next.toJson()).apply()
    ClipBus.onAppUpdate?.invoke(next.toMap())
  }

  companion object {
    private const val PREFS = "linktomac_update"
    private const val KEY_RECORD = "record"
    private const val KEY_AUTO = "auto"
    private const val KEY_FEED_OVERRIDE = "feedOverride"

    private const val FEED_URL = "https://api.github.com/repos/grkndev/LinkToMac/releases/latest"

    /** First check shortly after the service starts; then every 6 h (60 unauthenticated GitHub
     *  requests/h per IP is nowhere near a limit at this rate). */
    private const val FIRST_CHECK_S = 60L
    private const val CHECK_INTERVAL_S = 6 * 60 * 60L
    private const val RETRY_AFTER_MIN = 15L

    @Volatile private var instance: AppUpdater? = null

    fun get(ctx: Context): AppUpdater =
      instance ?: synchronized(this) {
        instance ?: AppUpdater(ctx.applicationContext).also { instance = it }
      }
  }
}
