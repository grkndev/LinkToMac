package expo.modules.selfadb

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import expo.modules.selfadb.R
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * What caught a clip. The shell daemon is the only source that sees a copy on its own; every
 * other one costs the user a tap but needs no ADB, no Wi-Fi and no special permission — so a
 * dead daemon degrades capture instead of ending it.
 */
enum class ClipSource(val label: String) {
  /** The shell-UID daemon's clip-changed listener (self-ADB pipeline). */
  DAEMON("daemon"),

  /** An explicit user action: the text-selection toolbar entry, or the notification action. */
  MANUAL("manual"),
}

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
  /** The secret [bridge] was built with, to detect a daemon relaunch under a fresh secret. */
  @Volatile private var bridgeSecret: String? = null
  private var conn: ConnectionManager? = null
  private var bleAdvertiser: BleAdvertiser? = null
  /** Reads + live-observes the SMS store, forwarding to the Mac over the `sms` channel. Started
   *  only when the user enabled message mirroring AND granted READ_SMS. */
  private var sms: SmsMirror? = null

  /** Texts we recently wrote to the device clipboard, each stamped; their daemon echoes are
   *  swallowed. A time-bounded MAP (not a single slot): rapid Mac→phone clips A then B used to
   *  overwrite the slot with B before A's echo arrived, bouncing A back to the Mac as a fresh
   *  clip. Entries are consumed on match and pruned after [ECHO_WINDOW_MS]. */
  private val recentWrites = LinkedHashMap<String, Long>()

  private fun stampWrite(text: String) {
    synchronized(recentWrites) {
      pruneWritesLocked()
      recentWrites[text] = SystemClock.elapsedRealtime()
    }
  }

  /** True (and consumes the stamp) when [text] is the echo of one of our own recent writes. */
  private fun consumeEcho(text: String): Boolean {
    synchronized(recentWrites) {
      pruneWritesLocked()
      return recentWrites.remove(text) != null
    }
  }

  private fun pruneWritesLocked() {
    val cutoff = SystemClock.elapsedRealtime() - ECHO_WINDOW_MS
    recentWrites.entries.removeAll { it.value < cutoff }
  }

  /** Content hashes of images we recently wrote to the clipboard (Mac→phone), so the daemon's
   *  re-capture of that same image isn't bounced back to the Mac. Keyed by SHA-256 of the raw
   *  received bytes — the daemon reads back the exact file we wrote, so the hashes match. Mirrors
   *  [recentWrites] for text; a separate map because the key space (byte hash) is different. */
  private val recentImageWrites = LinkedHashMap<String, Long>()

  private fun stampImageWrite(hash: String) {
    synchronized(recentImageWrites) {
      val cutoff = SystemClock.elapsedRealtime() - ECHO_WINDOW_MS
      recentImageWrites.entries.removeAll { it.value < cutoff }
      recentImageWrites[hash] = SystemClock.elapsedRealtime()
    }
  }

  private fun consumeImageEcho(hash: String): Boolean {
    synchronized(recentImageWrites) {
      val cutoff = SystemClock.elapsedRealtime() - ECHO_WINDOW_MS
      recentImageWrites.entries.removeAll { it.value < cutoff }
      return recentImageWrites.remove(hash) != null
    }
  }

  private fun sha256(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

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
    // Persist the explicit port so a null-intent START_STICKY restart (no JS) reuses it —
    // the dev variant runs on its own port, and falling back to DEFAULT_PORT would silently
    // bridge to the other install's daemon.
    val port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT)?.also { setClipPort(this, it) }
      ?: getClipPort(this)
    instance = this
    sendPaused = getClipSendPaused(this)
    val daemonSecret = getDaemonSecret(this)
    if (bridge != null && bridgeSecret != daemonSecret) {
      // deploy() relaunched the daemon under a fresh secret; a bridge still holding the old
      // one would be rejected forever. Drop it and rebuild below.
      ClipBus.log("service: daemon secret changed -> restarting bridge")
      bridge?.stop()
      bridge = null
    }
    if (bridge == null) {
      ClipBus.log("service: starting bridge on :$port")
      bridgeSecret = daemonSecret
      bridge = ClipBridge(
        port = port,
        secret = daemonSecret,
        onClip = { text, ts -> ingestClip(text, ts, ClipSource.DAEMON) },
        onImage = { mime, bytes, _ -> captureImage(mime, bytes) },
        onLog = { ClipBus.log(it) }
      ).also { it.start() }
    }
    // Auto-start the connection from persisted config. Also covers the null-intent START_STICKY
    // restart after the app is killed -> reconnects to the Mac with no JS runtime.
    maybeStartConnection()
    // Same for the BLE presence beacon (proximity auto-lock), if the user opted in.
    maybeStartAdvertising()
    // And the SMS mirror (live observer), if enabled + permitted. Backfill runs on the peer-online edge.
    maybeStartSmsMirroring()
    // A manual capture rides in on the same intent, handled only after the setup above: the
    // process may have been restarted by this very start, in which case `conn` was null until
    // maybeStartConnection() ran. The ConnectionManager queues until a link joins, so an
    // offline send still lands (PENDING_TTL_MS).
    if (intent?.action == ACTION_SUBMIT_CLIP) {
      intent.getStringExtra(EXTRA_TEXT)
        ?.let { ingestClip(it, System.currentTimeMillis().toDouble(), ClipSource.MANUAL) }
    }
    return START_STICKY
  }

  /**
   * Single funnel for every captured clip, whatever caught it. Echo suppression, the clip
   * history and the outbound pause gate all live here so a new capture source can't
   * accidentally bypass one of them.
   */
  private fun ingestClip(text: String, ts: Double, source: ClipSource) {
    if (text.isEmpty()) return
    if (consumeEcho(text)) return // echo of our own recent write -> swallow
    ClipBus.log("clip [${source.label}]: ${text.take(60)}")
    ClipBus.clip(text, ts)
    // `sendPaused` gates *automatic* forwarding. A manual capture is an explicit tap on "send
    // this", so it isn't what the user turned off.
    if (source == ClipSource.MANUAL || !sendPaused) conn?.sendClip(text)
  }

  /** JS-initiated write (the clipboard-history screen's "copy again"). Deliberately skips the
   *  echo stamp [writeRemoteText] applies: this is an explicit user action, so letting a live
   *  daemon carry it back to the Mac keeps both clipboards in step. */
  fun write(text: String) = putOnClipboard(text)

  /** Whether the localhost bridge currently holds a live connection to the daemon. */
  fun isBridgeConnected(): Boolean = bridge?.isConnected() == true

  /** The daemon's own log over the bridge (no adb). Null if the bridge isn't connected. */
  fun requestDaemonLog(): String? = bridge?.requestLog()

  /** Whether the daemon keeps accepting-then-dropping the bridge (wrong secret / eviction —
   *  i.e. the daemon is owned by another install). autoStart redeploys when this is set. */
  fun isBridgeFlapping(): Boolean = bridge?.isFlapping() == true

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

  /**
   * Forward a batch/delta of mirrored SMS messages to the Mac. Called by [SmsMirror] (same process).
   * Independent of [sendPaused] (that gate is clipboard-only). No-op if not connected.
   */
  fun sendSms(json: String) {
    conn?.sendSms(json)
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
        writeRemoteText(text)
        ClipBus.macClip(text, System.currentTimeMillis().toDouble())
      },
      onStatReceived = { json -> ClipBus.macStat(json) },
      onFileReceived = { bytes -> applyFile(bytes) },
      onSmsReceived = { json -> handleInboundSms(json) },
      onStatus = { transport, status, peerOnline, error, attempt ->
        ClipBus.relay(status, peerOnline, error, transport, attempt)
        updateNotification(peerOnline)
        // Give the Mac fresh battery + name + SMS history the moment it (re)connects, without
        // waiting for a change. The Mac store is in-memory, so a (re)connect re-backfills (the Mac
        // upserts by id, so it's idempotent).
        if (peerOnline && !lastPeerOnline) {
          pushBatteryStat(force = true)
          sms?.backfill()
        }
        lastPeerOnline = peerOnline
      },
      log = { ClipBus.log(it) },
    ).also { it.start() }
  }

  // ---- File transfer (Mac -> phone clipboard image) -------------------------
  // Plaintext layout (byte-exact contract with the Mac's `FileFrame.payload`):
  //   u16 BE header-len ‖ header JSON utf8 ‖ raw image bytes.   Header v1: {"mime":"image/…"}.

  /**
   * Put text on the system clipboard, daemon-first with a direct fallback.
   *
   * The daemon write stays preferred while the bridge is up: it's the proven path, and the
   * daemon is the one that re-reads the resulting change. When the daemon is gone we write
   * through [ClipboardManager] ourselves — background clipboard *writes* are allowed (only
   * reads are focus-gated), the same reasoning [applyFile] already relies on for images.
   * Without the fallback a dead daemon made every inbound clip a silent no-op while the log
   * still claimed success, so ADB dying took this direction down with it even though it never
   * needed ADB.
   *
   * The two paths log distinctly on purpose: killing the daemon and watching for
   * "clip -> clipboard direct" is how we confirm background *text* writes behave like the
   * image write does. Once confirmed on-device the daemon branch can be dropped entirely.
   */
  private fun putOnClipboard(text: String) {
    val b = bridge
    if (b != null && b.isConnected()) {
      b.write(text)
      ClipBus.log("clip -> clipboard via daemon (${text.length})")
      return
    }
    try {
      val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
      clipboard.setPrimaryClip(ClipData.newPlainText("Text", text))
      ClipBus.log("clip -> clipboard direct (${text.length})")
    } catch (e: Exception) {
      ClipBus.log("clip -> clipboard failed (${e.message})")
    }
  }

  /** A clip the Mac sent us. [stampWrite] first: a live daemon's clip-changed listener will
   *  re-read this text and try to forward it straight back, and [consumeEcho] drops that. */
  private fun writeRemoteText(text: String) {
    stampWrite(text)
    putOnClipboard(text)
  }

  /** Write a received image to cache and put it on the system clipboard as a FileProvider URI.
   *  Goes through [ClipboardManager] directly (background clipboard *writes* are allowed; only
   *  reads are focus-gated) — NOT through the shell daemon, which is text-only and holds no
   *  grant to our provider. The daemon's clip-changed listener reads no text off a URI clip,
   *  so nothing echoes back to the Mac ([recentWrites] stays untouched). */
  private fun applyFile(bytes: ByteArray) {
    try {
      if (bytes.size < 2) { ClipBus.log("file: frame too short"); return }
      val headerLen = ((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)
      if (bytes.size <= 2 + headerLen) { ClipBus.log("file: bad header length"); return }
      val header = JSONObject(String(bytes, 2, headerLen, Charsets.UTF_8))
      val mime = header.optString("mime", "image/png")
      val ext = if (mime == "image/jpeg") "jpg" else "png"

      val dir = File(cacheDir, "clips").apply { mkdirs() }
      // Reap stale clips by AGE, not wholesale: a paste target may still be streaming a
      // previous image off its FileProvider URI (slow editor), and deleting it mid-decode
      // breaks that read. 30 s comfortably outlives any real paste.
      val reapCutoff = System.currentTimeMillis() - CLIP_FILE_REAP_MS
      dir.listFiles()?.filter { it.lastModified() < reapCutoff }?.forEach { it.delete() }
      // Fresh timestamped name so a paste target never serves a cached read of an old URI.
      val file = File(dir, "clip-${System.currentTimeMillis()}.$ext")
      file.outputStream().use { it.write(bytes, 2 + headerLen, bytes.size - 2 - headerLen) }

      // Stamp the raw image bytes' hash BEFORE putting them on the clipboard: the daemon's
      // clip-changed listener will re-read this exact file and try to forward it back to the Mac;
      // [captureImage] consumes this stamp and drops that echo.
      val imageBytes = bytes.copyOfRange(2 + headerLen, bytes.size)
      stampImageWrite(sha256(imageBytes))

      val uri = FileProvider.getUriForFile(this, "$packageName.selfadb.fileprovider", file)
      val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
      clipboard.setPrimaryClip(ClipData.newUri(contentResolver, "Image", uri))
      ClipBus.macClip("[Image]", System.currentTimeMillis().toDouble())
      ClipBus.log("file -> clipboard image ($mime, ${file.length()} B)")
    } catch (e: Exception) {
      ClipBus.log("file apply failed: ${e.message}")
    }
  }

  /** A clipboard image the daemon captured on the phone → forward to the Mac. Drops the echo of
   *  our own Mac→phone write, respects the outbound pause, and fits the image under the relay
   *  frame cap (the same ~700 KB budget the Mac uses) before sealing it into a `file` frame. */
  private fun captureImage(mime: String, bytes: ByteArray) {
    try {
      if (consumeImageEcho(sha256(bytes))) return // echo of our own recent write -> swallow
      // Visible skip reasons so the Logs screen shows exactly why an image wasn't forwarded.
      if (sendPaused) { ClipBus.log("image not sent (clipboard sending is paused)"); return }
      if (!getSendImages(this)) { ClipBus.log("image not sent (Send images is off)"); return }
      val fit = fitImage(bytes, mime)
      if (fit == null) { ClipBus.log("image capture skipped (can't fit under the frame budget)"); return }
      ClipBus.log("image -> Mac (${fit.second}, ${fit.first.size} B)")
      conn?.sendFile(buildFilePayload(fit.second, fit.first))
    } catch (e: Exception) {
      ClipBus.log("image capture failed: ${e.message}")
    }
  }

  /** Fit a raw image under [RAW_IMAGE_BUDGET]: a small PNG passes through; anything bigger is
   *  downscaled + JPEG-compressed down a (scale, quality) ladder until it fits. Returns
   *  (bytes, mime) or null when even the smallest step won't fit (or the image won't decode). */
  private fun fitImage(bytes: ByteArray, mime: String): Pair<ByteArray, String>? {
    // Already under budget and a format the receiver handles (png/jpeg) → send as-is, no re-encode.
    if (bytes.size <= RAW_IMAGE_BUDGET && (mime == "image/png" || mime == "image/jpeg")) return bytes to mime
    val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
    for ((scale, quality) in IMAGE_FIT_STEPS) {
      val scaled = if (scale < 1f) {
        Bitmap.createScaledBitmap(
          bmp,
          (bmp.width * scale).toInt().coerceAtLeast(1),
          (bmp.height * scale).toInt().coerceAtLeast(1),
          true,
        )
      } else {
        bmp
      }
      val out = ByteArrayOutputStream()
      scaled.compress(Bitmap.CompressFormat.JPEG, (quality * 100).toInt(), out)
      if (out.size() <= RAW_IMAGE_BUDGET) return out.toByteArray() to "image/jpeg"
    }
    return null
  }

  /** Assemble the `file` frame plaintext (byte-exact contract with the Mac's `FileFrame`):
   *  u16 BE header-len ‖ header JSON utf8 ‖ raw image bytes. */
  private fun buildFilePayload(mime: String, bytes: ByteArray): ByteArray {
    val header = "{\"mime\":\"$mime\"}".toByteArray(Charsets.UTF_8)
    val out = ByteArrayOutputStream(2 + header.size + bytes.size)
    out.write((header.size shr 8) and 0xFF)
    out.write(header.size and 0xFF)
    out.write(header)
    out.write(bytes)
    return out.toByteArray()
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
    // ACTION_BATTERY_CHANGED is a protected system broadcast (exempt from Android 14's
    // mandatory-flag rule), but declare NOT_EXPORTED anyway - nothing else should ever
    // deliver into this receiver.
    ContextCompat.registerReceiver(
      this, r, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED
    )
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

  // ---- SMS mirroring (SmsMirror -> Mac) ------------------------------------
  // Lives in the service so reads + the live observer survive an app swipe. Gated by the forwarding
  // toggle AND the READ_SMS runtime grant. Independent of [sendPaused] (that gate is clipboard-only).

  private fun hasSmsPermission(): Boolean =
    checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED

  /** Start the live SMS observer if enabled + permitted (idempotent). The peer-online edge does
   *  the actual backfill; this just keeps the delta-observer running. */
  private fun maybeStartSmsMirroring() {
    if (sms != null) return
    if (!getSmsForwarding(this) || !hasSmsPermission()) return
    sms = SmsMirror(
      this,
      send = { json -> sendSms(json) },
      log = { ClipBus.log(it) },
      onSendPermissionDenied = { postSmsSendPermissionAlert() },
    ).also { it.start() }
  }

  /** A reply requested from the Mac, routed here from the relay/LAN inbound `sms` dispatch. */
  fun receiveSmsReply(addr: String, body: String, corr: String) {
    sms?.sendReply(addr, body, corr)
  }

  /** Parse a decrypted inbound `sms` payload from the Mac. The only inbound shape the phone
   *  receives is `{"op":"send","corr","addr","body"}` (batch/add are Mac-only). */
  private fun handleInboundSms(json: String) {
    val o = try { JSONObject(json) } catch (e: Exception) { return }
    if (o.optString("op") != "send") return
    val corr = o.optString("corr")
    val addr = o.optString("addr")
    val body = o.optString("body")
    if (corr.isEmpty() || addr.isEmpty() || body.isEmpty()) return
    receiveSmsReply(addr, body, corr)
  }

  /** Public hook for the module after the user grants SMS access from Settings — starts the
   *  observer and pushes an immediate backfill so the Mac fills without waiting for a reconnect. */
  fun startSmsMirroring() {
    maybeStartSmsMirroring()
    sms?.backfill()
  }

  /** Live toggle of message mirroring. Persisted so a START_STICKY restart with no JS honors it. */
  fun applySmsForwarding(enabled: Boolean) {
    setSmsForwarding(this, enabled)
    if (enabled) {
      startSmsMirroring()
    } else {
      sms?.stop()
      sms = null
    }
  }

  override fun onDestroy() {
    unregisterBatteryReceiver()
    conn?.shutdown()
    conn = null
    bleAdvertiser?.stop()
    bleAdvertiser = null
    sms?.stop()
    sms = null
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
      .addAction(sendClipboardAction())
      .build()
  }

  /**
   * "Send clipboard" on the sticky notification — the manual capture path that stays available
   * when the shell daemon is gone, and the only one that catches a *programmatic* copy (an
   * in-app "Copy link" button leaves no selection for the text-selection toolbar to hang off).
   *
   * The PendingIntent targets the Activity directly on purpose: Android 12+ bans notification
   * trampolines, so routing through a service or receiver to then launch the reader would be
   * dropped. Reading the clipboard needs real window focus, which is why it's an Activity at
   * all — see [ClipboardReadActivity].
   */
  private fun sendClipboardAction(): Notification.Action =
    Notification.Action.Builder(
      Icon.createWithResource(this, R.drawable.ic_stat_link),
      "Send clipboard",
      PendingIntent.getActivity(
        this,
        REQ_SEND_CLIPBOARD,
        Intent(this, ClipboardReadActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      ),
    ).build()

  /** Whether the "grant SMS send access" alert has already been shown this process lifetime —
   *  avoids re-notifying on every subsequent reply attempt while the permission stays denied. */
  @Volatile private var smsSendAlertShown = false

  /** Heads-up notification prompting the user to grant SEND_SMS, shown the first time a Mac
   *  reply is blocked by the missing permission (requesting it needs an Activity, which this
   *  background service doesn't have — tapping the notification opens the app instead). */
  private fun postSmsSendPermissionAlert() {
    if (smsSendAlertShown) return
    smsSendAlertShown = true
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      nm.createNotificationChannel(
        NotificationChannel(CHANNEL_SMS_ALERT, "Message replies", NotificationManager.IMPORTANCE_HIGH)
      )
    }
    val launchIntent = (packageManager.getLaunchIntentForPackage(packageName) ?: Intent())
      .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
    val contentIntent = PendingIntent.getActivity(
      this, 0, launchIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_SMS_ALERT)
    } else {
      @Suppress("DEPRECATION") Notification.Builder(this)
    }
    val notification = builder
      .setContentTitle("Reply couldn't be sent")
      .setContentText("Open Link to macOS to allow sending text messages")
      .setSmallIcon(R.drawable.ic_stat_link)
      .setAutoCancel(true)
      .setContentIntent(contentIntent)
      .build()
    nm.notify(SMS_ALERT_NOTIF_ID, notification)
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

    /** Received clip images older than this are reaped from cacheDir/clips on the next write
     *  (age-based so a paste target still decoding the previous URI isn't cut off mid-read). */
    private const val CLIP_FILE_REAP_MS = 30_000L
    private const val CHANNEL = "linktomac"
    private const val CHANNEL_HIDDEN = "linktomac_hidden"
    private const val CHANNEL_SMS_ALERT = "linktomac_sms_alert"
    private const val NOTIF_ID = 1001
    private const val SMS_ALERT_NOTIF_ID = 1002
    /** PendingIntent request code for the notification's "Send clipboard" action. */
    private const val REQ_SEND_CLIPBOARD = 1
    private const val EXTRA_PORT = "port"

    /** Start-intent action carrying a manually captured clip (see [submitClip]). */
    private const val ACTION_SUBMIT_CLIP = "expo.modules.selfadb.SUBMIT_CLIP"
    private const val EXTRA_TEXT = "text"

    /**
     * Hand a manually captured clip to the service, starting it if the process came back
     * without it. Always goes through a start-intent rather than [instance] so there is one
     * code path whether or not the service is already up. Safe from an Activity: Android 12+
     * only blocks FGS starts from the *background*, and every caller is on screen.
     */
    fun submitClip(ctx: Context, text: String) {
      val intent = Intent(ctx, ClipForegroundService::class.java)
        .setAction(ACTION_SUBMIT_CLIP)
        .putExtra(EXTRA_TEXT, text)
      ContextCompat.startForegroundService(ctx, intent)
    }
    private const val PREFS = "linktomac_relay"
    // Separate prefs file: clearConfig() wipes PREFS on unpair, UI settings must survive that.
    private const val PREFS_UI = "linktomac_ui"
    private const val KEY_STATUS_NOTIF_VISIBLE = "statusNotifVisible"
    private const val KEY_CLIP_SEND_PAUSED = "clipSendPaused"
    private const val KEY_NOTIFICATION_FORWARDING = "notificationForwarding"
    private const val KEY_NOTIF_FILTER_MODE = "notifFilterMode"
    private const val KEY_NOTIF_INCLUDE_PKGS = "notifIncludePkgs"
    private const val KEY_NOTIF_EXCLUDE_PKGS = "notifExcludePkgs"
    private const val KEY_SMS_FORWARDING = "smsForwarding"
    private const val KEY_SEND_IMAGES = "sendImages"
    private const val KEY_PROXIMITY_ADVERTISE = "proximityAdvertise"
    private const val KEY_DAEMON_SECRET = "daemonSecret"
    private const val KEY_CLIP_PORT = "clipPort"
    /** How long a write stamp lives before it can no longer suppress an echo. */
    private const val ECHO_WINDOW_MS = 10_000L
    /** Raw image budget before sealing: ~700 KB → ~960 KB frame after base64, under the relay's
     *  1 MiB cap. Same budget as the Mac's `ImagePrep`; bump both with `MAX_PAYLOAD_BYTES`. */
    private const val RAW_IMAGE_BUDGET = 700 * 1024
    /** (scale, JPEG quality) ladder for fitting an oversize image; first output under budget wins. */
    private val IMAGE_FIT_STEPS = listOf(1.0f to 0.8f, 0.7f to 0.7f, 0.5f to 0.5f)
    const val DEFAULT_PORT = 53123

    /** The daemon port this install actually runs on (per-variant; JS passes it to autoStart).
     *  Persisted in PREFS_UI so START_STICKY restarts and adb-free liveness checks agree with
     *  the JS-chosen port instead of assuming [DEFAULT_PORT]. */
    fun getClipPort(ctx: Context): Int =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getInt(KEY_CLIP_PORT, DEFAULT_PORT)

    private fun setClipPort(ctx: Context, port: Int) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putInt(KEY_CLIP_PORT, port)
        .apply()
    }

    /** The bridge-auth secret the daemon was launched with (null = never launched an
     *  auth-aware daemon). Lives in PREFS_UI, NOT PREFS: an unpair wipes PREFS but must not
     *  orphan the still-running daemon, whose expected secret can't change until relaunch. */
    fun getDaemonSecret(ctx: Context): String? =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getString(KEY_DAEMON_SECRET, null)

    /** Returns the persisted secret, minting + persisting a fresh 32-byte one if absent.
     *  Called only from the daemon launch path so the persisted value always matches what
     *  the running daemon expects. */
    fun getOrCreateDaemonSecret(ctx: Context): String {
      getDaemonSecret(ctx)?.let { return it }
      val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
      val secret = Base64.encodeToString(bytes, Base64.NO_WRAP)
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putString(KEY_DAEMON_SECRET, secret)
        .apply()
      return secret
    }

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

    /** Per-app notification-mirroring filter mode: "exclude" (default — mirror every app except
     *  [getNotifExcludePkgs]) or "include" (mirror ONLY [getNotifIncludePkgs]). Each mode keeps
     *  its own package set so flipping modes doesn't lose the other's selection. Read live by
     *  [NotificationListener] on every post; persisted in PREFS_UI (survives unpair). */
    fun getNotifFilterMode(ctx: Context): String =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getString(KEY_NOTIF_FILTER_MODE, "exclude") ?: "exclude"

    fun setNotifFilterMode(ctx: Context, mode: String) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putString(KEY_NOTIF_FILTER_MODE, if (mode == "include") "include" else "exclude")
        .apply()
    }

    /** Packages mirrored when the filter mode is "include" (empty = mirror nothing). */
    fun getNotifIncludePkgs(ctx: Context): Set<String> =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getStringSet(KEY_NOTIF_INCLUDE_PKGS, emptySet())?.toSet() ?: emptySet()

    /** Packages NOT mirrored when the filter mode is "exclude" (empty = mirror everything —
     *  the pre-filter behavior, so existing installs are unaffected). */
    fun getNotifExcludePkgs(ctx: Context): Set<String> =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getStringSet(KEY_NOTIF_EXCLUDE_PKGS, emptySet())?.toSet() ?: emptySet()

    // Fresh HashSet copies on write: SharedPreferences treats a getStringSet() result as its own
    // consistent-state object — persisting a mutated or reused instance is undefined behavior.
    fun setNotifAppFilter(ctx: Context, mode: String, include: Collection<String>, exclude: Collection<String>) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putString(KEY_NOTIF_FILTER_MODE, if (mode == "include") "include" else "exclude")
        .putStringSet(KEY_NOTIF_INCLUDE_PKGS, HashSet(include))
        .putStringSet(KEY_NOTIF_EXCLUDE_PKGS, HashSet(exclude))
        .apply()
    }

    /** Whether mirroring SMS messages to the Mac is enabled (default true). The real gate is the
     *  READ_SMS runtime grant; this is the soft pause. Persisted in PREFS_UI (survives unpair). */
    fun getSmsForwarding(ctx: Context): Boolean =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getBoolean(KEY_SMS_FORWARDING, true)

    fun setSmsForwarding(ctx: Context, enabled: Boolean) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putBoolean(KEY_SMS_FORWARDING, enabled)
        .apply()
    }

    /** Whether copied images are sent to the Mac (default true). A screenshot/photo copy can be
     *  ~1 MB over the link, so it gets its own switch on top of the clipboard `sendPaused` gate.
     *  Persisted in PREFS_UI (survives unpair) + read live by [captureImage]. */
    fun getSendImages(ctx: Context): Boolean =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE)
        .getBoolean(KEY_SEND_IMAGES, true)

    fun setSendImages(ctx: Context, enabled: Boolean) {
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit()
        .putBoolean(KEY_SEND_IMAGES, enabled)
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

    /**
     * Bring the service up (idempotent — `onStartCommand` reconnects from the persisted
     * config). Called on every app launch *before* any ADB work and again on a relay-config
     * push, because everything this service owns except clipboard *capture* works without ADB.
     */
    fun start(ctx: Context, port: Int) {
      val intent = Intent(ctx, ClipForegroundService::class.java).putExtra(EXTRA_PORT, port)
      try {
        ContextCompat.startForegroundService(ctx, intent)
      } catch (e: Exception) {
        // Android 12+ refuses an FGS start from the background. Every caller is on a
        // foreground path, so this only fires in corner cases (the app dying mid-call) —
        // log it instead of taking the process down; START_STICKY recovers on the next launch.
        ClipBus.log("service start refused (${e.message})")
      }
    }

    fun stop(ctx: Context) {
      ctx.stopService(Intent(ctx, ClipForegroundService::class.java))
    }
  }
}
