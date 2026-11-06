package expo.modules.selfadb

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.ContextCompat
import java.io.File

/**
 * Hands the downloaded, verified APK to the system installer. The app never installs anything
 * itself: the system shows its own "Update" screen and the user confirms there.
 *
 * Reached from the "Update ready" notification and from the update sheet's Install button. An
 * invisible activity (same shape as [PickActivity]) because it only brokers: it may have to send
 * the user to a settings screen first and wait for them to come back.
 *
 *  1. **"Install unknown apps" for this app.** Even opening the installer needs it; it is a one-time
 *     per-app switch the user flips in system settings. We send them there, and carry on from
 *     `onResume` once they are back (or give up if they didn't allow it).
 *  2. **A `PackageInstaller` session** carrying the APK. The commit's result comes back as a
 *     broadcast to a receiver registered by this activity; `STATUS_PENDING_USER_ACTION` carries the
 *     system's confirmation screen, which we start from here — we are in the foreground, so it is
 *     allowed to appear.
 *
 * No `noHistory`: that would finish the activity on the trip to settings and lose the flow.
 */
class InstallActivity : Activity() {
  private var receiver: BroadcastReceiver? = null
  private var sentToSettings = false

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // A recreated activity must not start a second install; the first one's receiver died with it.
    if (savedInstanceState != null) {
      finish()
      return
    }
    proceed()
  }

  override fun onResume() {
    super.onResume()
    // Back from the "Install unknown apps" screen.
    if (sentToSettings) {
      sentToSettings = false
      proceed()
    }
  }

  private fun proceed() {
    val file = AppUpdater.get(this).readyFile()
    if (file == null) {
      toast("The update isn't ready yet")
      finish()
      return
    }
    if (!packageManager.canRequestPackageInstalls()) {
      if (sentToSettings) {
        finish()
        return
      }
      requestInstallPermission()
      return
    }
    install(file)
  }

  private fun requestInstallPermission() {
    toast("Allow installs from this app, then come back")
    try {
      sentToSettings = true
      startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
    } catch (e: Exception) {
      ClipBus.log("update: couldn't open the install-permission screen (${e.message})")
      sentToSettings = false
      finish()
    }
  }

  private fun install(file: File) {
    try {
      val installer = packageManager.packageInstaller
      val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
        setAppPackageName(packageName)
        setSize(file.length())
        // The user confirms in the system UI; never ask the system to apply it silently.
        if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
      }
      val sessionId = installer.createSession(params)
      installer.openSession(sessionId).use { session ->
        file.inputStream().use { input ->
          session.openWrite("update.apk", 0, file.length()).use { out ->
            input.copyTo(out)
            session.fsync(out)
          }
        }
        listenForResult()
        val result = PendingIntent.getBroadcast(
          this,
          sessionId,
          Intent(ACTION_RESULT).setPackage(packageName),
          // Mutable: the system fills in the status extras.
          PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        session.commit(result.intentSender)
      }
      ClipBus.log("update: handed ${file.name} to the system installer")
    } catch (e: Exception) {
      ClipBus.log("update: install failed to start (${e.message})")
      toast("Couldn't start the update")
      finish()
    }
  }

  private fun listenForResult() {
    val r = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
          PackageInstaller.STATUS_PENDING_USER_ACTION -> {
            val confirm = if (Build.VERSION.SDK_INT >= 33) {
              intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            } else {
              @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
            }
            if (confirm == null) {
              ClipBus.log("update: installer sent no confirmation screen")
              finish()
              return
            }
            try {
              startActivity(confirm)
            } catch (e: Exception) {
              ClipBus.log("update: couldn't show the install screen (${e.message})")
              finish()
            }
          }
          PackageInstaller.STATUS_SUCCESS -> finish() // the process is replaced about now
          else -> {
            // Includes the user pressing Cancel on the system screen. The download stays ready, so
            // the notification / the sheet can offer it again.
            ClipBus.log("update: install ended with status $status (${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)})")
            finish()
          }
        }
      }
    }
    ContextCompat.registerReceiver(this, r, IntentFilter(ACTION_RESULT), ContextCompat.RECEIVER_NOT_EXPORTED)
    receiver = r
  }

  override fun onDestroy() {
    receiver?.let { runCatching { unregisterReceiver(it) } }
    receiver = null
    super.onDestroy()
  }

  private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

  companion object {
    private const val ACTION_RESULT = "expo.modules.selfadb.INSTALL_RESULT"

    /** Open the installer flow for the ready update (callable from any context; adds NEW_TASK). */
    fun launch(ctx: Context) {
      ctx.startActivity(Intent(ctx, InstallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
  }
}
