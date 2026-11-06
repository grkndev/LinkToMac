package expo.modules.selfadb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * The two notifications of a native update: a quiet progress bar while the APK downloads, and the
 * "ready" one whose tap opens [InstallActivity].
 *
 * The tap is the whole reason this exists. Android 10+ stops a background app from opening an
 * Activity, so when the download finishes with the app swiped away "start the installer now" is not
 * possible — a notification tap is a user action, which is allowed to. With the app in the
 * foreground the update sheet offers the same thing as a button.
 *
 * Driven from [AppUpdater] on every state change, so it works with no service instance and no JS.
 */
object UpdateNotifier {
  private const val CHANNEL_PROGRESS = "linktomac_update_progress"
  private const val CHANNEL_READY = "linktomac_update"
  private const val ID_PROGRESS = 1007
  private const val ID_READY = 1006
  private const val REQ_INSTALL = 4101
  private const val PROGRESS_THROTTLE_MS = 1000L

  private var lastProgressPost = 0L

  /** Bring the notifications in line with a state change. [prev] lets "ready" post once, not per publish. */
  fun sync(ctx: Context, prev: UpdateRecord, next: UpdateRecord) {
    when (next.state) {
      UpdateState.DOWNLOADING -> {
        cancel(ctx, ID_READY)
        progress(ctx, next)
      }
      UpdateState.READY -> {
        cancel(ctx, ID_PROGRESS)
        if (prev.state != UpdateState.READY || prev.release?.version != next.release?.version) ready(ctx, next)
      }
      else -> {
        cancel(ctx, ID_PROGRESS)
        // `idle` after a reset (installed, or no longer newer) must also take the "ready" one down.
        cancel(ctx, ID_READY)
      }
    }
  }

  private fun manager(ctx: Context) = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

  private fun channel(ctx: Context, id: String, name: String, importance: Int) {
    manager(ctx).createNotificationChannel(NotificationChannel(id, name, importance))
  }

  private fun progress(ctx: Context, rec: UpdateRecord) {
    val now = SystemClock.elapsedRealtime()
    // The first post of a download always goes; after that one a second is plenty for a bar.
    if (rec.progress > 0 && now - lastProgressPost < PROGRESS_THROTTLE_MS) return
    lastProgressPost = now
    channel(ctx, CHANNEL_PROGRESS, "App updates", NotificationManager.IMPORTANCE_LOW)
    manager(ctx).notify(
      ID_PROGRESS,
      Notification.Builder(ctx, CHANNEL_PROGRESS)
        .setContentTitle("Downloading update")
        .setContentText("Version ${rec.release?.version ?: ""}")
        .setSubText("${rec.progress}%")
        .setSmallIcon(R.drawable.ic_stat_link)
        .setProgress(100, rec.progress, false)
        .setOnlyAlertOnce(true)
        // Not ongoing: a download the process dies in must not leave an undismissable notification.
        .setOngoing(false)
        .build(),
    )
  }

  private fun ready(ctx: Context, rec: UpdateRecord) {
    channel(ctx, CHANNEL_READY, "App updates ready", NotificationManager.IMPORTANCE_DEFAULT)
    val open = PendingIntent.getActivity(
      ctx,
      REQ_INSTALL,
      Intent(ctx, InstallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    manager(ctx).notify(
      ID_READY,
      Notification.Builder(ctx, CHANNEL_READY)
        .setContentTitle("Update ready")
        .setContentText("Version ${rec.release?.version ?: ""} is downloaded. Tap to install.")
        .setSmallIcon(R.drawable.ic_stat_link)
        .setContentIntent(open)
        .setAutoCancel(true)
        .build(),
    )
  }

  private fun cancel(ctx: Context, id: Int) = manager(ctx).cancel(id)
}
