package expo.modules.selfadb

import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * The platform-free half of the self-updater: what a GitHub release looks like to us, how versions
 * compare, how a half-downloaded file resumes, and the persisted state record. Kept free of
 * `Context` so it is covered by plain JVM tests (`AppUpdateTest`); [AppUpdater] is the part that
 * touches the network, the filesystem and the package manager.
 */

/** The native-update facts we need from a GitHub release. */
data class ReleaseInfo(
  /** `tag_name` without a leading `v` ("0.12.0"). */
  val version: String,
  val notes: String?,
  /** The release page — the fallback when there is no APK asset. */
  val pageUrl: String?,
  val apkUrl: String?,
  /** Asset size in bytes, 0 when unknown. */
  val apkSize: Long,
  /** Lower-case hex SHA-256 from the asset's `digest`, null when GitHub didn't report one. */
  val sha256: String?,
)

enum class UpdateState { IDLE, DOWNLOADING, READY, FAILED }

/** Everything persisted about the pending update, so the service and the JS side agree across restarts. */
data class UpdateRecord(
  val release: ReleaseInfo?,
  val state: UpdateState = UpdateState.IDLE,
  /** 0..100 while [UpdateState.DOWNLOADING]. */
  val progress: Int = 0,
  /** The verified APK, when [UpdateState.READY]. */
  val path: String? = null,
  val error: String? = null,
) {
  fun toJson(): String = JSONObject().apply {
    put("state", state.name)
    put("progress", progress)
    put("path", path ?: JSONObject.NULL)
    put("error", error ?: JSONObject.NULL)
    release?.let {
      put(
        "release",
        JSONObject().apply {
          put("version", it.version)
          put("notes", it.notes ?: JSONObject.NULL)
          put("pageUrl", it.pageUrl ?: JSONObject.NULL)
          put("apkUrl", it.apkUrl ?: JSONObject.NULL)
          put("apkSize", it.apkSize)
          put("sha256", it.sha256 ?: JSONObject.NULL)
        },
      )
    }
  }.toString()

  /** The shape JS receives (module events + `checkAppUpdate`). `url` is the APK, else the release page. */
  fun toMap(): Map<String, Any?> = mapOf(
    "state" to state.name.lowercase(),
    "version" to release?.version,
    "notes" to release?.notes,
    "url" to (release?.apkUrl ?: release?.pageUrl),
    "downloadable" to (release?.apkUrl != null),
    "progress" to progress,
    "error" to error,
  )

  companion object {
    fun fromJson(raw: String?): UpdateRecord {
      if (raw.isNullOrBlank()) return UpdateRecord(null)
      return try {
        val o = JSONObject(raw)
        val r = o.optJSONObject("release")
        UpdateRecord(
          release = r?.let {
            ReleaseInfo(
              version = it.getString("version"),
              notes = it.optStringOrNull("notes"),
              pageUrl = it.optStringOrNull("pageUrl"),
              apkUrl = it.optStringOrNull("apkUrl"),
              apkSize = it.optLong("apkSize", 0),
              sha256 = it.optStringOrNull("sha256"),
            )
          },
          state = runCatching { UpdateState.valueOf(o.optString("state")) }.getOrDefault(UpdateState.IDLE),
          progress = o.optInt("progress", 0),
          path = o.optStringOrNull("path"),
          error = o.optStringOrNull("error"),
        )
      } catch (e: Exception) {
        UpdateRecord(null)
      }
    }
  }
}

private fun JSONObject.optStringOrNull(key: String): String? =
  if (isNull(key) || !has(key)) null else optString(key).ifBlank { null }

object UpdateLogic {
  /**
   * Compare dotted numeric versions: >0 when [a] is newer than [b], 0 when equal, <0 when older.
   * Tolerates a leading "v", differing segment counts ("0.2" vs "0.2.0") and a suffix on a segment
   * ("0.12.0-beta" reads as 0.12.0). Mirrors `compareVersions` in `src/features/updates/check.ts`.
   */
  fun compareVersions(a: String, b: String): Int {
    fun parse(v: String) = v.removePrefix("v").split('.').map { seg -> seg.takeWhile { it.isDigit() }.toIntOrNull() ?: 0 }
    val pa = parse(a)
    val pb = parse(b)
    for (i in 0 until maxOf(pa.size, pb.size)) {
      val d = (pa.getOrElse(i) { 0 }) - (pb.getOrElse(i) { 0 })
      if (d != 0) return d
    }
    return 0
  }

  /**
   * Read GitHub's `releases/latest` payload. Takes the first `.apk` asset; null when the payload has
   * no usable version (the caller treats that as "check failed", never "up to date").
   */
  fun parseRelease(json: String): ReleaseInfo? {
    return try {
      val o = JSONObject(json)
      val version = o.optString("tag_name").removePrefix("v").trim()
      if (version.isEmpty()) return null
      val assets = o.optJSONArray("assets")
      var apk: JSONObject? = null
      if (assets != null) {
        for (i in 0 until assets.length()) {
          val a = assets.optJSONObject(i) ?: continue
          if (a.optString("name").endsWith(".apk", ignoreCase = true)) {
            apk = a
            break
          }
        }
      }
      ReleaseInfo(
        version = version,
        notes = o.optString("body").trim().ifEmpty { null },
        pageUrl = o.optString("html_url").ifEmpty { null },
        apkUrl = apk?.optString("browser_download_url")?.ifEmpty { null },
        apkSize = apk?.optLong("size", 0) ?: 0,
        sha256 = apk?.optString("digest")?.let(::parseDigest),
      )
    } catch (e: Exception) {
      null
    }
  }

  /** `"sha256:ABC…"` → `"abc…"`; anything else (another algorithm, malformed hex) → null. */
  fun parseDigest(digest: String): String? {
    val hex = digest.removePrefix("sha256:").takeIf { digest.startsWith("sha256:") } ?: return null
    return hex.lowercase().takeIf { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } }
  }

  /**
   * Where a partial download resumes. A leftover that is already as big as (or bigger than) the
   * whole asset is stale or corrupt — start over rather than ask for a Range past the end.
   */
  fun resumeOffset(part: File, total: Long): Long {
    if (!part.exists()) return 0
    val len = part.length()
    return if (total > 0 && len >= total) 0 else len
  }

  fun sha256Hex(file: File): String {
    val md = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
      val buf = ByteArray(64 * 1024)
      while (true) {
        val n = input.read(buf)
        if (n < 0) break
        md.update(buf, 0, n)
      }
    }
    return md.digest().joinToString("") { "%02x".format(it) }
  }
}
