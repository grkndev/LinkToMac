package expo.modules.selfadb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import expo.modules.selfadb.R
import org.json.JSONObject

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
  private var conn: ConnectionManager? = null
  private var bleAdvertiser: BleAdvertiser? = null

  /** Last text we wrote to the device clipboard; its echo `onClip` is swallowed. */
  @Volatile private var lastWritten: String? = null

  /** Outbound gate: when true, captured clips are NOT forwarded to the Mac (inbound still
   *  works). Seeded from PREFS_UI in onStartCommand so a START_STICKY restart with no JS
   *  keeps honoring the user's choice. */
  @Volatile private var sendPaused: Boolean = false

  /** Last telemetry payload sent, so a battery broadcast only forwards a `stat` when it changed. */
  @Volatile private var lastStatSent: String? = null
  /** Tracks the peer-online edge so we push fresh telemetry once per (re)connect, not every tick. */
  @Volatile private var lastPeerOnline = false
  private var batteryReceiver: BroadcastReceiver? = null

  override fun onCreate() {
    super.onCreate()
    startInForeground()
    registerBatteryReceiver()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT) ?: DEFAULT_PORT
    instance = this
    sendPaused = getClipSendPaused(this)
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
            if (!sendPaused) conn?.sendClip(text)
          }
        },
        onLog = { ClipBus.log(it) }
      ).also { it.start() }
    }
    // Auto-start the connection from persisted config. Also covers the null-intent START_STICKY
    // restart after the app is killed -> reconnects to the Mac with no JS runtime.
    maybeStartConnection()
    // Same for the BLE presence beacon (proximity auto-lock), if the user opted in.
    maybeStartAdvertising()
    return START_STICKY
  }

  fun write(text: String) {
    bridge?.write(text)
  }

  /** Whether the localhost bridge currently holds a live connection to the daemon. */
  fun isBridgeConnected(): Boolean = bridge?.isConnected() == true

  /**
   * Send a remote action to the Mac (e.g. "lock"). Independent of [sendPaused]: the pause
   * toggle only gates outbound *clipboard* forwarding, not commands. No-op if not connected.
   */
  fun sendCmd(action: String) {
    conn?.sendCmd(action)
  }

  /**
   * Forward a mirrored device notification to the Mac. Called by [NotificationListener] (same
   * process). Independent of [sendPaused] (that gate is clipboard-only); the listener already
   * checks [getNotificationForwarding]. No-op if not connected.
   */
  fun sendNote(json: String) {
    conn?.sendNote(json)
  }

  // ---- Connection (LAN-direct preferred, relay fallback) -------------------

  /** Persist config and (re)connect — but skip the restart if nothing changed. */
  fun applyRelayConfig(
    url: String, token: String, room: String, key: String, peerName: String?,
    lanEnabled: Boolean, lanPort: Int, lanHost: String?,
  ) {
    val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val unchanged = p.getString("url", null) == url &&
      p.getString("token", null) == token &&
      p.getString("room", null) == room &&
      p.getString("key", null) == key &&
      p.getString("peerName", null) == peerName &&
      p.getBoolean("lanEnabled", true) == lanEnabled &&
      p.getInt("lanPort", 0) == lanPort &&
      p.getString("lanHost", null) == lanHost
    saveConfig(this, url, token, room, key, peerName, lanEnabled, lanPort, lanHost)
    if (unchanged && conn != null) return
    reloadConnection()
    reloadAdvertiser() // room may have changed -> re-derive the beacon UUID
  }

  /** (Re)apply persisted config, replacing any running connection. */
  fun reloadConnection() {
    conn?.shutdown()
    conn = null
    maybeStartConnection()
  }

  /** Unpair: drop the persisted config and the live connection. Stays disconnected
   *  (including across START_STICKY restarts) until a new pairing is pushed. */
  fun clearRelayConfig() {
    clearConfig(this)
    conn?.shutdown()
    conn = null
    bleAdvertiser?.stop() // room is gone -> nothing to advertise
    bleAdvertiser = null
    ClipBus.relay("disconnected", false, null)
    updateNotification(peerOnline = false)
  }

  /**
   * Live toggle of the outbound (Mac-bound) clip forwarding. The relay stays connected so
   * the Mac's clips keep arriving even while paused — only our own sends are suppressed.
   * Persisted so a START_STICKY restart with no JS keeps honoring it.
   */
  fun setPaused(paused: Boolean) {
    sendPaused = paused
    setClipSendPaused(this, paused)
  }

  private fun maybeStartConnection() {
    if (conn != null) return
    val p = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val room = p.getString("room", null) ?: return
    // Fail closed: without the pairing key we can't E2E-encrypt, so don't connect. The JS
    // pairing context re-pushes setRelay(...key) on launch, which then starts us.
    val key = p.getString("key", null) ?: run { ClipBus.log("relay: waiting for pairing key"); return }
    val url = p.getString("url", null) ?: ""
    val token = p.getString("token", null) ?: ""
    val lanEnabled = p.getBoolean("lanEnabled", true)
    val lanPort = p.getInt("lanPort", 0)
    val lanHost = p.getString("lanHost", null)
    val lanReady = lanEnabled && lanPort > 0
    if (url.isEmpty() && !lanReady) {
      ClipBus.log("connection: nothing configured (no relay, LAN off)")
      return
    }
    ClipBus.log("connection starting (relay=${if (url.isEmpty()) "none" else url}, lan=${if (lanReady) lanPort else "off"})")
    conn = ConnectionManager(
      context = this,
      relayUrl = url,
      token = token,
      room = room,
      key = key,
      lanEnabled = lanEnabled,
      lanPort = lanPort,
      lanHost = lanHost,
      onClipReceived = { text ->
        lastWritten = text
        bridge?.write(text)
        ClipBus.macClip(text, System.currentTimeMillis().toDouble())
        ClipBus.log("clip -> clipboard (${text.length})")
      },
      onStatReceived = { json -> ClipBus.macStat(json) },
      onStatus = { transport, status, peerOnline, error, attempt ->
        ClipBus.relay(status, peerOnline, error, transport, attempt)
        updateNotification(peerOnline)
        // Give the Mac fresh battery + name the moment it (re)connects, without waiting for a change.
        if (peerOnline && !lastPeerOnline) pushBatteryStat(force = true)
        lastPeerOnline = peerOnline
      },
      log = { ClipBus.log(it) },
    ).also { it.start() }
  }

  // ---- Telemetry (battery + name -> Mac) -----------------------------------
  // Lives in the service so it keeps reporting even when the JS app is swiped away. Sends a `stat`
  // frame (E2E-encrypted by the active link) carrying {"level":N,"charging":bool,"name":"…"}.
  // Independent of [sendPaused] (that gate is clipboard-only).

  /** Send the current battery to the Mac if it changed since the last send (or `force` on connect). */
  private fun pushBatteryStat(force: Boolean = false) {
    val payload = batteryStatPayload() ?: return
    if (!force && payload == lastStatSent) return
    lastStatSent = payload
    conn?.sendStat(payload)
  }

  /** This phone's telemetry as the wire payload, or null if the battery can't be read. */
  private fun batteryStatPayload(): String? {
    val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
    val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
    val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
    if (level < 0 || scale <= 0) return null
    val pct = (level * 100 / scale).coerceIn(0, 100)
    val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
    val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
      status == BatteryManager.BATTERY_STATUS_FULL
    return JSONObject()
      .put("level", pct)
      .put("charging", charging)
      .put("name", deviceName())
      .toString()
  }

  /** User-set device name (Settings.Global "device_name") when available, else the hardware model. */
  private fun deviceName(): String {
    val name = try {
      Settings.Global.getString(contentResolver, "device_name")
    } catch (e: Exception) {
      null
    }
    return if (!name.isNullOrBlank()) name else Build.MODEL
  }

  private fun registerBatteryReceiver() {
    if (batteryReceiver != null) return
    val r = object : BroadcastReceiver() {
      override fun onReceive(context: Context?, intent: Intent?) = pushBatteryStat()
    }
    batteryReceiver = r
    registerReceiver(r, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
  }

  private fun unregisterBatteryReceiver() {
    val r = batteryReceiver ?: return
    batteryReceiver = null
    try { unregisterReceiver(r) } catch (e: Exception) {}
  }

  // ---- BLE presence beacon (proximity auto-lock) ---------------------------

  /**
   * Live toggle of the presence beacon. When on, advertise the pairing-derived UUID so the Mac
   * can lock when this phone leaves; when off, stop advertising. Persisted so a START_STICKY
   * restart with no JS keeps honoring it.
   */
  fun setProximityAdvertise(enabled: Boolean) {
    setProximityAdvertiseEnabled(this, enabled)
    if (enabled) {
      maybeStartAdvertising()
    } else {
      bleAdvertiser?.stop()
      bleAdvertiser = null
    }
  }

  private fun maybeStartAdvertising() {
    if (!getProximityAdvertise(this)) return
    val room = getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("room", null) ?: return
    if (bleAdvertiser == null) bleAdvertiser = BleAdvertiser(applicationContext) { ClipBus.log(it) }
    bleAdvertiser?.start(room)
  }

  /** Restart advertising under a (possibly) new room — e.g. after a re-pair. */
  private fun reloadAdvertiser() {
    bleAdvertiser?.stop()
    bleAdvertiser = null
    maybeStartAdvertising()
  }

  override fun onDestroy() {
    unregisterBatteryReceiver()
    conn?.shutdown()
    conn = null
    bleAdvertiser?.stop()
    bleAdvertiser = null
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
      // NONE importance keeps the status-bar icon hidden while the foreground service runs;
      // the notification still lives in the shade. IMPORTANCE_MIN used to be enough but leaks
      // the icon on Android 12+ and OEM skins (e.g. Samsung One UI). A channel's importance is
      // immutable once created, so this lives under a fresh id (the old CHANNEL_MIN is dropped).
      nm.deleteNotificationChannel("linktomac_min")
      nm.createNotificationChannel(
        NotificationChannel(CHANNEL_HIDDEN, "Link to macOS (icon hidden)", NotificationManager.IMPORTANCE_NONE)
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
      Notification.Builder(this, if (getStatusNotificationVisible(this)) CHANNEL else CHANNEL_HIDDEN)
    } else {
      @Suppress("DEPRECATION") Notification.Builder(this)
    }
    return builder
      .setContentTitle(title)
      .setContentText(text)
      // Status-bar glyph: a tightly-cropped white silhouette of the app mark (res/drawable-*/
      // ic_stat_link.png), tinted by Android to the device theme. Cropped from the monochrome
      // adaptive icon, whose safe-zone padding made the bare mipmap render tiny in the bar.
      .setSmallIcon(R.drawable.ic_stat_link)
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
    private const val CHANNEL_HIDDEN = "linktomac_hidden"
    private const val NOTIF_ID = 1001
    private const val EXTRA_PORT = "port"
    private const val PREFS = "linktomac_relay"
    // Separate prefs file: clearConfig() wipes PREFS on unpair, UI settings must survive that.
    private const val PREFS_UI = "linktomac_ui"
    private const val KEY_STATUS_NOTIF_VISIBLE = "statusNotifVisible"
    private const val KEY_CLIP_SEND_PAUSED = "clipSendPaused"
    private const val KEY_NOTIFICATION_FORWARDING = "notificationForwarding"
    private const val KEY_PROXIMITY_ADVERTISE = "proximityAdvertise"
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

    /** Whether outbound (Mac-bound) clip forwarding is paused (default false = sending). */
    fun getClipSendPaused(ctx: Context): Boolean =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getBoolean(KEY_CLIP_SEND_PAUSED, false)

    fun setClipSendPaused(ctx: Context, paused: Boolean) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putBoolean(KEY_CLIP_SEND_PAUSED, paused)
        .apply()
    }

    /** Whether mirroring device notifications to the Mac is enabled (default true). Gates
     *  [NotificationListener] independently of the system "Notification access" grant, so the
     *  user can pause mirroring without revoking access. Persisted in PREFS_UI (survives unpair). */
    fun getNotificationForwarding(ctx: Context): Boolean =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getBoolean(KEY_NOTIFICATION_FORWARDING, true)

    fun setNotificationForwarding(ctx: Context, enabled: Boolean) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putBoolean(KEY_NOTIFICATION_FORWARDING, enabled)
        .apply()
    }

    /** Whether the BLE presence beacon is enabled (default false = not advertising). */
    fun getProximityAdvertise(ctx: Context): Boolean =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getBoolean(KEY_PROXIMITY_ADVERTISE, false)

    fun setProximityAdvertiseEnabled(ctx: Context, enabled: Boolean) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putBoolean(KEY_PROXIMITY_ADVERTISE, enabled)
        .apply()
    }

    /** Persist connection config so the service (incl. a START_STICKY restart) can connect. */
    fun saveConfig(
      ctx: Context, url: String, token: String, room: String, key: String, peerName: String?,
      lanEnabled: Boolean, lanPort: Int, lanHost: String?,
    ) {
      ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        .putString("url", url)
        .putString("token", token)
        .putString("room", room)
        .putString("key", key)
        .putString("peerName", peerName)
        .putBoolean("lanEnabled", lanEnabled)
        .putInt("lanPort", lanPort)
        .putString("lanHost", lanHost)
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
