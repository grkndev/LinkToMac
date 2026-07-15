package expo.modules.selfadb

import android.app.Notification
import android.content.ComponentName
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.LruCache
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Mirrors device notifications to the Mac. A system-bound [NotificationListenerService] — it needs
 * the special **"Notification access"** grant (Settings ▸ Notification access; surfaced from the
 * app's settings via [SelfAdbModule]'s `openNotificationAccessSettings`), which is NOT a runtime
 * permission. Once granted the system binds this service in the app process and delivers every
 * posted/removed notification, even while the JS app is swiped away.
 *
 * Each accepted post becomes a JSON payload forwarded over the E2E `note` channel via the running
 * [ClipForegroundService] (same process). The Mac decodes it, stores it, raises a banner, and shows
 * it in the dashboard's Notifications tab. A removal forwards a minimal `{"op":"remove","key":…}`
 * so a phone-side dismissal clears the Mac copy.
 *
 * Wire payload (plaintext, then E2E-encrypted by the active link):
 *   { "op":"post"|"remove", "key":<sbn.key>, "pkg":…, "app":…, "title":…, "text":…,
 *     "category":…, "time":<postTime ms>, "icon":<base64 png ~72px> }
 */
class NotificationListener : NotificationListenerService() {

  /** Heavy work (icon decode/scale/encode, app-label lookup) runs off the binder callback thread
   *  to keep the listener responsive — system callbacks arrive on the main thread. */
  private val worker = Executors.newSingleThreadExecutor()

  /** Run on the worker, dropping the task after [onDestroy] — the system can still deliver
   *  binder callbacks during teardown, and an unguarded execute() would throw
   *  [RejectedExecutionException] on the binder thread. */
  private fun post(task: Runnable) {
    if (worker.isShutdown) return
    try {
      worker.execute(task)
    } catch (e: RejectedExecutionException) {
      // shutting down; late notification intentionally dropped
    }
  }

  /** base64-PNG app icons keyed by package, so we encode each app's icon once, not per notification.
   *  ~64 entries × ~10 KB ≈ tolerable; evicted LRU. */
  private val iconCache = LruCache<String, String>(64)

  override fun onListenerConnected() {
    ClipBus.log("notif listener connected")
  }

  override fun onListenerDisconnected() {
    // Ask the system to rebind us (e.g. after an OEM kill) so mirroring resumes without a re-grant.
    if (Build.VERSION.SDK_INT >= 24) {
      ClipBus.log("notif listener disconnected; requesting rebind")
      requestRebind(ComponentName(this, NotificationListener::class.java))
    }
  }

  override fun onNotificationPosted(sbn: StatusBarNotification?) {
    sbn ?: return
    if (!ClipForegroundService.getNotificationForwarding(this)) return
    if (sbn.packageName == packageName) return // our own foreground-service notification
    // Per-app filter (Settings ▸ Notifications): "include" mirrors only the selected apps,
    // "exclude" (default) mirrors everything except the deselected ones. Removals are NOT
    // filtered — a dismissal must still clear a Mac copy mirrored before a filter change.
    val mirrored = if (ClipForegroundService.getNotifFilterMode(this) == "include") {
      ClipForegroundService.getNotifIncludePkgs(this).contains(sbn.packageName)
    } else {
      !ClipForegroundService.getNotifExcludePkgs(this).contains(sbn.packageName)
    }
    if (!mirrored) return
    val n = sbn.notification ?: return
    // Drop status/persistent noise: ongoing (e.g. media/FGS), foreground-service, and the
    // group-summary placeholder (its children carry the real content -> avoids duplicates).
    val flags = n.flags
    if (flags and Notification.FLAG_ONGOING_EVENT != 0) return
    if (flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return
    if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return

    val extras = n.extras
    val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
    val text = (extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)
      ?: extras?.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.trim().orEmpty()
    if (title.isEmpty() && text.isEmpty()) return // nothing worth mirroring

    // Snapshot the primitives now; build/encode/send on the worker.
    val pkg = sbn.packageName
    val key = sbn.key
    val time = sbn.postTime
    val category = n.category
    post {
      val json = JSONObject()
        .put("op", "post")
        .put("key", key)
        .put("pkg", pkg)
        .put("app", appLabel(pkg))
        .put("title", title)
        .put("text", text)
        .put("time", time)
      if (category != null) json.put("category", category)
      iconBase64(pkg)?.let { json.put("icon", it) }
      val svc = ClipForegroundService.instance
      if (svc != null) {
        svc.sendNote(json.toString())
      } else {
        ClipBus.log("note dropped (service down): $pkg")
      }
    }
  }

  override fun onNotificationRemoved(sbn: StatusBarNotification?) {
    sbn ?: return
    if (!ClipForegroundService.getNotificationForwarding(this)) return
    if (sbn.packageName == packageName) return
    val key = sbn.key
    post {
      val json = JSONObject().put("op", "remove").put("key", key)
      ClipForegroundService.instance?.sendNote(json.toString())
    }
  }

  override fun onDestroy() {
    worker.shutdown()
    super.onDestroy()
  }

  /** Human app name for [pkg], falling back to the package id. */
  private fun appLabel(pkg: String): String = try {
    val ai = packageManager.getApplicationInfo(pkg, 0)
    packageManager.getApplicationLabel(ai).toString()
  } catch (e: Exception) {
    pkg
  }

  /** The app's launcher icon as a base64 PNG (~72px), memoized per package. Null if it can't load. */
  private fun iconBase64(pkg: String): String? {
    iconCache.get(pkg)?.let { return it }
    return try {
      val bmp = drawableToBitmap(packageManager.getApplicationIcon(pkg), ICON_PX)
      val out = ByteArrayOutputStream()
      bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
      val b64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
      iconCache.put(pkg, b64)
      b64
    } catch (e: Exception) {
      null
    }
  }

  private companion object {
    const val ICON_PX = 72
  }
}

/** Rasterize any drawable (incl. adaptive icons) to a size×size bitmap. Shared with
 *  [SelfAdbModule]'s `getInstalledApps` app-picker icon export. */
internal fun drawableToBitmap(d: Drawable, size: Int): Bitmap {
  if (d is BitmapDrawable) {
    d.bitmap?.let { return Bitmap.createScaledBitmap(it, size, size, true) }
  }
  val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
  val canvas = Canvas(bmp)
  d.setBounds(0, 0, canvas.width, canvas.height)
  d.draw(canvas)
  return bmp
}
