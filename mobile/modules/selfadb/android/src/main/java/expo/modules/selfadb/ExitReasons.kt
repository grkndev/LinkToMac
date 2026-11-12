package expo.modules.selfadb

/**
 * Readable names for `ApplicationExitInfo` — why Android last ended this app's process.
 *
 * This is the one direct evidence of the silent deaths (One UI / lmkd killing the foreground
 * service or the daemon's host process, issues #29–#31): they are not exceptions, so a crash
 * reporter would never see them, but the OS keeps them for us.
 *
 * Plain Kotlin on purpose (literal ints, no android.* constants), so the mapping is unit-tested on
 * the JVM. The numbers are the documented `ApplicationExitInfo.REASON_*` and
 * `ActivityManager.RunningAppProcessInfo.IMPORTANCE_*` values; the app-facing API level for the
 * newest ones is noted inline, and an unknown number degrades to `REASON_<n>` instead of failing.
 */
object ExitReasons {
  /** Longest `description` forwarded. It is OEM free text; the JS side also sanitizes it. */
  const val MAX_DESCRIPTION = 200

  fun reasonName(reason: Int): String = when (reason) {
    0 -> "UNKNOWN"
    1 -> "EXIT_SELF"
    2 -> "SIGNALED"
    3 -> "LOW_MEMORY"
    4 -> "CRASH"
    5 -> "CRASH_NATIVE"
    6 -> "ANR"
    7 -> "INITIALIZATION_FAILURE"
    8 -> "PERMISSION_CHANGE"
    9 -> "EXCESSIVE_RESOURCE_USAGE"
    10 -> "USER_REQUESTED"
    11 -> "USER_STOPPED"
    12 -> "DEPENDENCY_DIED"
    13 -> "OTHER"
    14 -> "FREEZER" // API 31
    15 -> "PACKAGE_STATE_CHANGE" // API 33
    16 -> "PACKAGE_UPDATED" // API 34
    else -> "REASON_$reason"
  }

  fun importanceName(importance: Int): String = when {
    importance <= 100 -> "FOREGROUND"
    importance == 125 -> "FOREGROUND_SERVICE"
    importance == 150 -> "TOP_SLEEPING"
    importance == 200 -> "VISIBLE"
    importance == 230 -> "PERCEPTIBLE"
    importance == 300 -> "SERVICE"
    importance == 350 -> "CANT_SAVE_STATE"
    importance == 400 -> "CACHED"
    importance == 1000 -> "GONE"
    else -> "IMPORTANCE_$importance"
  }

  /** The OEM description, trimmed and length-capped; empty when there is none. */
  fun cleanDescription(description: String?): String {
    val text = description?.trim().orEmpty()
    return if (text.length <= MAX_DESCRIPTION) text else text.take(MAX_DESCRIPTION - 1) + "…"
  }
}
