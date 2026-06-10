package expo.modules.selfadb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Hosts the clipboard pipeline so it survives the app being swiped away.
 *
 * Now: owns the [ClipBridge] (localhost socket to the shell daemon) and posts
 * captured clips to [ClipBus] (UI when alive) + logcat.
 * Next: this is where the WS-relay client + E2E crypto will live, so clips are
 * forwarded to the Mac even when the app is fully closed.
 *
 * START_STICKY → the system restarts it (with a null intent) after a kill, and
 * it reconnects to the still-running daemon on the default port.
 */
class ClipForegroundService : Service() {

  private var bridge: ClipBridge? = null
  private var relay: RelayClient? = null

  /** Last text we wrote to the device clipboard; its echo `onClip` is swallowed. */
  @Volatile private var lastWritten: String? = null

  override fun onCreate() {
    super.onCreate()
    startInForeground()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT) ?: DEFAULT_PORT
    instance = this
    if (bridge == null) {
      ClipBus.log("service: starting bridge on :$port")
      bridge = ClipBridge(
        port = port,
        onClip = { text, ts ->
          if (text == lastWritten) {
            lastWritten = null // echo of our own write -> swallow
          } else {
            ClipBus.log("clip: ${text.take(60)}")
            ClipBus.clip(text, ts)
            relay?.sendClip(text)
          }
        },
        onLog = { ClipBus.log(it) }
      ).also { it.start() }
    }
    // Auto-start the relay from persisted config. Also covers the null-intent START_STICKY
    // restart after the app is killed -> reconnects to the Mac with no JS runtime.
    maybeStartRelay()
    return START_STICKY
  }

  fun write(text: String) {
    bridge?.write(text)
  }

  // ---- Relay (WS to the Mac) -----------------------------------------------

  /** Persist config and (re)connect — but skip the restart if nothing changed. */
  fun applyRelayConfig(url: String, token: String, room: String, peerName: String?) {
    val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val unchanged = p.getString("url", null) == url &&
      p.getString("token", null) == token &&
      p.getString("room", null) == room &&
      p.getString("peerName", null) == peerName
    saveConfig(this, url, token, room, peerName)
    if (unchanged && relay != null) return
    reloadRelay()
  }

  /** (Re)apply persisted relay config, replacing any running client. */
  fun reloadRelay() {
    relay?.shutdown()
    relay = null
    maybeStartRelay()
  }

  /** Unpair: drop the persisted config and the live connection. Stays disconnected
   *  (including across START_STICKY restarts) until a new pairing is pushed. */
  fun clearRelayConfig() {
    clearConfig(this)
    relay?.shutdown()
    relay = null
    ClipBus.relay("disconnected", false, null)
    updateNotification(peerOnline = false)
  }

  /** Live pause/resume; does not touch persisted config. */
  fun setPaused(paused: Boolean) {
    if (paused) {
      relay?.shutdown()
      relay = null
      ClipBus.relay("disconnected", false, null)
      updateNotification(peerOnline = false)
    } else {
      reloadRelay()
    }
  }

  private fun maybeStartRelay() {
    if (relay != null) return
    val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val url = p.getString("url", null) ?: return
    val token = p.getString("token", null) ?: return
    val room = p.getString("room", null) ?: return
    ClipBus.log("relay starting -> $url")
    relay = RelayClient(
      url = url,
      token = token,
      room = room,
      onClipReceived = { text ->
        lastWritten = text
        bridge?.write(text)
        ClipBus.log("relay -> clipboard (${text.length})")
      },
      onStatus = { status, peerOnline, error ->
        ClipBus.relay(status, peerOnline, error)
        updateNotification(peerOnline)
      },
      log = { ClipBus.log(it) },
    ).also { it.start() }
  }

  override fun onDestroy() {
    relay?.shutdown()
    relay = null
    bridge?.stop()
    bridge = null
    instance = null
    super.onDestroy()
  }

  override fun onBind(intent: Intent?): IBinder? = null

  private fun startInForeground() {
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      nm.createNotificationChannel(
        NotificationChannel(CHANNEL, "Link to macOS", NotificationManager.IMPORTANCE_LOW)
      )
      // MIN importance hides the status-bar icon; the notification stays in the shade.
      nm.createNotificationChannel(
        NotificationChannel(CHANNEL_MIN, "Link to macOS (icon hidden)", NotificationManager.IMPORTANCE_MIN)
      )
    }
    val notification = buildNotification("Device disconnected", "Waiting for connection…")
    if (Build.VERSION.SDK_INT >= 34) {
      startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
    } else {
      startForeground(NOTIF_ID, notification)
    }
  }

  private fun buildNotification(title: String, text: String): Notification {
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, if (getStatusNotificationVisible(this)) CHANNEL else CHANNEL_MIN)
    } else {
      @Suppress("DEPRECATION") Notification.Builder(this)
    }
    return builder
      .setContentTitle(title)
      .setContentText(text)
      .setSmallIcon(android.R.drawable.stat_notify_sync)
      .setOngoing(true)
      .build()
  }

  /** Last peerOnline value shown in the notification; skips redundant notify() calls. */
  @Volatile private var notifiedPeerOnline: Boolean? = null

  /**
   * Re-post the notification with the current state. Needed right after POST_NOTIFICATIONS
   * is granted: the grant doesn't retroactively reveal a notification posted while denied.
   */
  fun refreshNotification() {
    val online = notifiedPeerOnline ?: false
    notifiedPeerOnline = null
    updateNotification(online)
  }

  /**
   * Switch the notification between the LOW (icon visible) and MIN (icon hidden) channels.
   * notify() can't move an existing notification to another channel, so re-enter the
   * foreground state with a freshly built one.
   */
  fun applyStatusNotificationVisibility() {
    val online = notifiedPeerOnline ?: false
    notifiedPeerOnline = null
    stopForeground(STOP_FOREGROUND_REMOVE)
    val name = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .getString("peerName", null) ?: "your Mac"
    val notification = if (online) {
      buildNotification("Device connected", "Your device has connected to $name")
    } else {
      buildNotification("Device disconnected", "Waiting to reconnect to $name")
    }
    if (Build.VERSION.SDK_INT >= 34) {
      startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
    } else {
      startForeground(NOTIF_ID, notification)
    }
    notifiedPeerOnline = online
  }

  /** Reflect the Mac's presence in the sticky foreground notification. */
  private fun updateNotification(peerOnline: Boolean) {
    if (notifiedPeerOnline == peerOnline) return
    notifiedPeerOnline = peerOnline
    val name = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .getString("peerName", null) ?: "your Mac"
    val notification = if (peerOnline) {
      buildNotification("Device connected", "Your device has connected to $name")
    } else {
      buildNotification("Device disconnected", "Waiting to reconnect to $name")
    }
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    nm.notify(NOTIF_ID, notification)
  }

  companion object {
    @Volatile
    var instance: ClipForegroundService? = null

    private const val CHANNEL = "linktomac"
    private const val CHANNEL_MIN = "linktomac_min"
    private const val NOTIF_ID = 1001
    private const val EXTRA_PORT = "port"
    private const val PREFS = "linktomac_relay"
    // Separate prefs file: clearConfig() wipes PREFS on unpair, UI settings must survive that.
    private const val PREFS_UI = "linktomac_ui"
    private const val KEY_STATUS_NOTIF_VISIBLE = "statusNotifVisible"
    const val DEFAULT_PORT = 53123

    /** Whether the foreground notification should show a status-bar icon (default true). */
    fun getStatusNotificationVisible(ctx: Context): Boolean =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getBoolean(KEY_STATUS_NOTIF_VISIBLE, true)

    fun setStatusNotificationVisible(ctx: Context, visible: Boolean) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putBoolean(KEY_STATUS_NOTIF_VISIBLE, visible)
        .apply()
    }

    /** Persist relay config so the service (incl. a START_STICKY restart) can connect. */
    fun saveConfig(ctx: Context, url: String, token: String, room: String, peerName: String?) {
      ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        .putString("url", url)
        .putString("token", token)
        .putString("room", room)
        .putString("peerName", peerName)
        .apply()
    }

    /** Forget the persisted relay config (unpair); safe to call with the service down. */
    fun clearConfig(ctx: Context) {
      ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    fun start(ctx: Context, port: Int) {
      val intent = Intent(ctx, ClipForegroundService::class.java).putExtra(EXTRA_PORT, port)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        ctx.startForegroundService(intent)
      } else {
        ctx.startService(intent)
      }
    }

    fun stop(ctx: Context) {
      ctx.stopService(Intent(ctx, ClipForegroundService::class.java))
    }
  }
}
