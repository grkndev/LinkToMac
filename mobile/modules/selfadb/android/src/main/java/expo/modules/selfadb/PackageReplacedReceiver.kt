package expo.modules.selfadb

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Runs once right after this app is updated (by [InstallActivity] or any other way).
 *
 * An update kills the process, and the foreground service is not restarted by the system for a
 * replaced package — without this the link to the Mac would stay down until the app was opened by
 * hand, which for a background-only tool means "silently stopped working after every update".
 * `ACTION_MY_PACKAGE_REPLACED` is one of the broadcasts exempt from Android 12's ban on starting a
 * foreground service from the background.
 *
 * It also forgets the update that was just installed: its APK is dead weight and its notifications
 * are now wrong.
 */
class PackageReplacedReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
    val app = context.applicationContext
    AppUpdater.get(app).reset()
    // Only if there is a link to restore; an app that was never paired has nothing to run.
    if (ClipForegroundService.isConfigured(app)) {
      ClipForegroundService.start(app, ClipForegroundService.getClipPort(app))
    }
  }
}
