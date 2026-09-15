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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.net.Uri
import android.util.Base64
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import expo.modules.selfadb.R
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

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

  /** The chunked `file` transfer currently in flight, so inbound [FileFrame.OP_ACK] frames can
   *  find its window. Single-slot on purpose: [shareExec] runs one transfer at a time. */
  @Volatile private var transfer: Transfer? = null

  /** Reassembles chunked inbound `file` transfers from the Mac (streamed to a temp file, never
   *  held whole in memory). */
  private val fileInbox by lazy { FileInbox(File(cacheDir, INBOX_DIR)) { ClipBus.log(it) } }

  /** Notification id for the next received file; incremented so arrivals stack. */
  private var fileNotifId = FILE_NOTIF_ID_BASE

  /** Serialises share-sheet sends off the main thread. One thread, so two shares can never
   *  interleave their chunks on the socket or race for the same ack window. */
  private val shareExec = Executors.newSingleThreadExecutor()

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
    // Re-publish the share-sheet Direct Share targets (idempotent; the system drops dynamic
    // shortcuts on some upgrade paths, and the Mac's name may have changed since last run).
    refreshShareShortcuts()
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
    // A share-sheet send. Off the main thread (it reads a file and can block on acks for as
    // long as the transfer takes) but never off the service, which outlives the activity.
    if (intent?.action == ACTION_SUBMIT_SHARE) {
      val path = intent.getStringExtra(EXTRA_PATH)
      val name = intent.getStringExtra(EXTRA_NAME) ?: "shared"
      val mime = intent.getStringExtra(EXTRA_MIME) ?: "application/octet-stream"
      val disp = intent.getStringExtra(EXTRA_DISP) ?: FileFrame.DISP_CLIP
      if (path != null) shareExec.execute { sendShared(path, name, mime, disp) }
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
      onStatReceived = { json -> ClipBus.macStat(json); rememberMacName(json) },
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

  /** Handle an inbound `file` frame from the Mac. Four shapes arrive on this one entry point:
   *  a whole clipboard image (the original shape), one chunk of a larger file, a one-frame file,
   *  and an [FileFrame.OP_ACK] for a transfer *we* are sending.
   *
   *  Every frame carrying an `id` is acked as soon as it is stored — that ack is the Mac sender's
   *  flow control, and without it a big file would outrun the relay's 8 MiB per-peer buffer and
   *  get the phone disconnected mid-transfer. Clipboard images carry no `id` and aren't acked. */
  private fun applyFile(bytes: ByteArray) {
    try {
      val frame = FileFrame.parse(bytes)
      if (frame == null) { ClipBus.log("file: frame malformed"); return }

      if (frame.op == FileFrame.OP_ACK) {
        // Flow control for our own outbound transfer — see [sendAsFile].
        val t = transfer
        if (t != null && t.id == frame.id) t.window.release()
        return
      }

      // Ack on `id` alone, not on chunk count: a one-chunk file transfer carries an id too, and
      // the Mac blocks on its receipt before reporting success.
      frame.id?.let { conn?.sendFile(FileFrame.ack(it, frame.seq)) }

      if (!frame.isSingle) {
        when (val result = fileInbox.accept(frame)) {
          is FileInbox.Result.Buffered -> postTransferProgress(
            notifId = TRANSFER_IN_NOTIF_ID,
            title = "Receiving from your Mac",
            name = frame.name ?: "File",
            done = result.received,
            total = result.total,
          )
          is FileInbox.Result.Rejected -> clearTransferProgress(TRANSFER_IN_NOTIF_ID)
          is FileInbox.Result.Done -> {
            clearTransferProgress(TRANSFER_IN_NOTIF_ID)
            val done = result.completed
            try {
              if (done.disp == FileFrame.DISP_SAVE) {
                saveIncomingFile(done.file, done.name, done.mime)
              } else {
                // Clipboard images are always fit into one frame by the sender, so a chunked one
                // is a peer bug; reading it whole to paste it would be an unbounded allocation.
                ClipBus.log("file: chunked clipboard images aren't supported (${done.file.length()} B)")
              }
            } finally {
              done.file.delete()
            }
          }
        }
        return
      }

      if (frame.disp == FileFrame.DISP_SAVE) {
        val staged = File(File(cacheDir, INBOX_DIR).apply { mkdirs() }, "in-${System.currentTimeMillis()}")
        try {
          staged.writeBytes(frame.bytes)
          saveIncomingFile(staged, frame.name, frame.mime)
        } finally {
          staged.delete()
        }
      } else {
        applyClipboardImage(frame.bytes, frame.mime)
      }
    } catch (e: Exception) {
      ClipBus.log("file apply failed: ${e.message}")
    }
  }

  /** Put a received image on the system clipboard as a FileProvider content URI.
   *
   *  Goes through [ClipboardManager] directly (background clipboard *writes* are allowed; only
   *  reads are focus-gated) — NOT through the shell daemon, which is text-only and holds no
   *  grant to our provider. The daemon's clip-changed listener reads no text off a URI clip,
   *  so nothing echoes back to the Mac ([recentWrites] stays untouched). */
  private fun applyClipboardImage(bytes: ByteArray, mime: String) {
    val ext = if (mime == "image/jpeg") "jpg" else "png"
    val dir = File(cacheDir, "clips").apply { mkdirs() }
    // Reap stale clips by AGE, not wholesale: a paste target may still be streaming a
    // previous image off its FileProvider URI (slow editor), and deleting it mid-decode
    // breaks that read. 30 s comfortably outlives any real paste.
    val reapCutoff = System.currentTimeMillis() - CLIP_FILE_REAP_MS
    dir.listFiles()?.filter { it.lastModified() < reapCutoff }?.forEach { it.delete() }
    // Fresh timestamped name so a paste target never serves a cached read of an old URI.
    val file = File(dir, "clip-${System.currentTimeMillis()}.$ext")
    file.outputStream().use { it.write(bytes) }

    // Stamp the raw image bytes' hash BEFORE putting them on the clipboard: the daemon's
    // clip-changed listener will re-read this exact file and try to forward it back to the Mac;
    // [captureImage] consumes this stamp and drops that echo.
    stampImageWrite(sha256(bytes))

    val uri = FileProvider.getUriForFile(this, "$packageName.selfadb.fileprovider", file)
    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newUri(contentResolver, "Image", uri))
    ClipBus.macClip("[Image]", System.currentTimeMillis().toDouble())
    ClipBus.log("file -> clipboard image ($mime, ${file.length()} B)")
  }

  /** Write a completed `disp:"save"` transfer into shared Downloads and raise a notification —
   *  nothing about this lands on the clipboard, so the notification is the only thing that makes
   *  the file discoverable. Tapping it opens the file. */
  private fun saveIncomingFile(source: File, name: String?, mime: String) {
    val display = FileSink.sanitize(name, mime)
    val uri = FileSink.saveToDownloads(this, source, name, mime)
    if (uri == null) {
      ClipBus.log("file: couldn't save $display")
      postFileNotification("Couldn't save file", display, null, mime)
      return
    }
    ClipBus.log("file saved to Downloads: $display (${source.length()} B)")
    postFileNotification("Saved from your Mac", display, uri, mime)
  }

  /** Last post time per progress notification, so a fast transfer doesn't hammer the notification
   *  manager — it rate-limits updates, and at 640 KiB a chunk a LAN transfer can fire dozens a
   *  second. Keyed by notification id; there is one per direction. */
  private val lastProgressPost = HashMap<Int, Long>()

  /**
   * Show (or update) the progress bar for a transfer in flight. Throttled to
   * [PROGRESS_THROTTLE_MS], except for the final step, which always posts so the bar visibly
   * reaches the end instead of stopping at whatever the last throttled update showed.
   *
   * Its own low-importance channel: this is a running status, not an event, and it must never
   * make a sound or a heads-up on every file.
   */
  private fun postTransferProgress(notifId: Int, title: String, name: String, done: Int, total: Int) {
    val now = SystemClock.elapsedRealtime()
    val complete = done >= total
    if (!complete && now - (lastProgressPost[notifId] ?: 0L) < PROGRESS_THROTTLE_MS) return
    lastProgressPost[notifId] = now

    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      nm.createNotificationChannel(
        NotificationChannel(CHANNEL_TRANSFER, "File transfers", NotificationManager.IMPORTANCE_LOW)
      )
    }
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_TRANSFER)
    } else {
      @Suppress("DEPRECATION") Notification.Builder(this)
    }
    val percent = if (total > 0) done * 100 / total else 0
    nm.notify(
      notifId,
      builder
        .setContentTitle(title)
        .setContentText(name)
        .setSubText("$percent%")
        .setSmallIcon(R.drawable.ic_stat_link)
        .setProgress(total, done, false)
        .setOnlyAlertOnce(true)
        // NOT ongoing: a transfer that dies in a way we can't observe (process death mid-send)
        // would otherwise leave an undismissable notification behind.
        .setOngoing(false)
        .build()
    )
  }

  /** Take the progress bar down — on completion, on failure, and on a rejected chunk. */
  private fun clearTransferProgress(notifId: Int) {
    lastProgressPost.remove(notifId)
    (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(notifId)
  }

  /** Heads-up for a file that arrived from the Mac. [uri] non-null makes the notification open it. */
  private fun postFileNotification(title: String, body: String, uri: Uri?, mime: String) {
    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      nm.createNotificationChannel(
        NotificationChannel(CHANNEL_FILE, "Received files", NotificationManager.IMPORTANCE_DEFAULT)
      )
    }
    val contentIntent = uri?.let {
      val view = Intent(Intent.ACTION_VIEW)
        .setDataAndType(it, mime)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
      PendingIntent.getActivity(
        this, fileNotifId, view, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
      )
    }
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_FILE)
    } else {
      @Suppress("DEPRECATION") Notification.Builder(this)
    }
    val notification = builder
      .setContentTitle(title)
      .setContentText(body)
      .setSmallIcon(R.drawable.ic_stat_link)
      .setAutoCancel(true)
      .apply { contentIntent?.let { setContentIntent(it) } }
      .build()
    // A fresh id per file so several arrivals stack instead of overwriting each other.
    nm.notify(fileNotifId++, notification)
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
      conn?.sendFile(FileFrame.encode(fit.second, fit.first))
    } catch (e: Exception) {
      ClipBus.log("image capture failed: ${e.message}")
    }
  }

  // ---- Share-sheet sends (ShareActivity -> here) ----------------------------
  // The activity has already copied the shared bytes into cacheDir/outbox (its URI grant dies
  // with it), so this side only has a path. Runs on [shareExec] — a single thread, so two
  // transfers can never interleave on one ack window or one socket.

  /** Send a file the user picked from the share sheet, then delete the staged copy. Returns
   *  through a toast either way: this is a fire-and-forget action with no app UI to update. */
  private fun sendShared(path: String, name: String, mime: String, disp: String) {
    val file = File(path)
    try {
      val link = conn
      val result = when {
        link == null || !ClipBus.peerOnline() -> NOT_CONNECTED
        !file.isFile -> "Couldn't read $name"
        disp == FileFrame.DISP_SAVE -> sendAsFile(link, file, name, mime)
        else -> sendToClipboard(link, file, mime)
      }
      toastOnMain(result)
    } catch (e: Exception) {
      ClipBus.log("share send failed: ${e.message}")
      toastOnMain("Couldn't send $name")
    } finally {
      file.delete()
    }
  }

  /** Share → the Mac's clipboard: one frame, downscaled to fit, exactly like a copied image.
   *  Losing resolution is correct here — the user asked to paste it, not to keep it. */
  private fun sendToClipboard(link: ConnectionManager, file: File, mime: String): String {
    // [fitImage] works on a whole ByteArray, so an enormous source would OOM before it ever
    // got to sample it down. Files past this are a "Send as a File" job anyway.
    if (file.length() > MAX_CLIPBOARD_SOURCE_BYTES) return "That image is too large to paste"
    val fit = fitImage(file.readBytes(), mime) ?: return "Couldn't fit that image"
    link.sendFile(FileFrame.encode(fit.second, fit.first))
    ClipBus.log("share -> Mac clipboard (${fit.second}, ${fit.first.size} B)")
    return "Sent to your Mac's clipboard"
  }

  /** Share → a file saved on the Mac, at original quality, in [FileFrame.CHUNK_RAW_BYTES] chunks.
   *
   *  Two independent relay limits shape this, and tripping either one drops the connection
   *  rather than just the frame:
   *
   *   - **Buffer.** The relay hangs up on a peer buffering more than 8 MiB (`maxPayloadBytes * 8`),
   *     so blasting every chunk at once would disconnect the Mac partway through. At most
   *     [ACK_WINDOW] chunks stay unacked ([FileFrame.OP_ACK]), holding the relay near 3 MB.
   *   - **Rate.** `RATE_LIMIT_MSGS` frames per `RATE_LIMIT_WINDOW_MS` (120 / 10 s), counted per
   *     connection — and a big file is a lot of frames. [RELAY_CHUNK_INTERVAL_MS] keeps us well
   *     under it. LAN-direct talks straight to the Mac with no such limit, so it isn't paced.
   *
   *  The final drain means the success toast is a real delivery receipt, not an optimistic
   *  guess — the only send path here that can say that. */
  private fun sendAsFile(link: ConnectionManager, file: File, name: String, mime: String): String {
    val total = file.length()
    if (total <= 0L) return "$name is empty"
    if (total > FileFrame.MAX_TRANSFER_BYTES) return "$name is too large"
    val count = ((total + FileFrame.CHUNK_RAW_BYTES - 1) / FileFrame.CHUNK_RAW_BYTES).toInt()
    val id = UUID.randomUUID().toString().substring(0, 8)
    val t = Transfer(id)
    transfer = t
    ClipBus.log("share -> Mac file: $name ($total B, $count chunk(s), id=$id)")
    try {
      val buf = ByteArray(FileFrame.CHUNK_RAW_BYTES)
      var lastSentAt = 0L
      file.inputStream().use { input ->
        for (seq in 0 until count) {
          if (!t.window.tryAcquire(ACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            ClipBus.log("share: timed out waiting for ack ${seq - ACK_WINDOW} of $id")
            return "Your Mac stopped responding"
          }
          val read = fill(input, buf)
          if (read <= 0) return "Couldn't read $name"
          // Re-read the transport each chunk: a LAN link can drop to the relay mid-transfer.
          val pace = if (ClipBus.onLan()) 0L else RELAY_CHUNK_INTERVAL_MS
          val wait = pace - (SystemClock.elapsedRealtime() - lastSentAt)
          if (wait > 0) Thread.sleep(wait)
          link.sendFile(
            FileFrame.encode(mime, buf, 0, read, name, FileFrame.DISP_SAVE, id, seq, count)
          )
          lastSentAt = SystemClock.elapsedRealtime()
          // Progress is counted in chunks *sent*, not acked: the ack window means the two differ
          // by at most [ACK_WINDOW], which is invisible on a transfer of any real size — and the
          // final drain below is what makes the completion honest.
          postTransferProgress(TRANSFER_OUT_NOTIF_ID, "Sending to your Mac", name, seq + 1, count)
        }
      }
      // Reclaim the whole window: every outstanding chunk has been acked once we can.
      repeat(ACK_WINDOW) {
        if (!t.window.tryAcquire(ACK_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
          ClipBus.log("share: transfer $id never fully acked")
          return "Your Mac stopped responding"
        }
      }
      ClipBus.log("share: file $id delivered")
      return "Saved $name on your Mac"
    } finally {
      transfer = null
      clearTransferProgress(TRANSFER_OUT_NOTIF_ID)
    }
  }

  /** Read until [buf] is full or the stream ends — `InputStream.read` is allowed to return
   *  short, and `readNBytes` is API 33 (this module ships to 30). */
  private fun fill(input: InputStream, buf: ByteArray): Int {
    var n = 0
    while (n < buf.size) {
      val r = input.read(buf, n, buf.size - n)
      if (r < 0) break
      n += r
    }
    return n
  }

  /** One chunked `file` transfer in flight. [window] starts full; a send takes a permit and an
   *  ack returns one, so at most [ACK_WINDOW] chunks are ever unacknowledged. */
  private class Transfer(val id: String) {
    val window = Semaphore(ACK_WINDOW)
  }

  private fun toastOnMain(msg: String) {
    Handler(Looper.getMainLooper()).post {
      Toast.makeText(applicationContext, msg, Toast.LENGTH_SHORT).show()
    }
  }

  /** Fit a raw image under [RAW_IMAGE_BUDGET]: a small PNG passes through; anything bigger is
   *  downscaled + JPEG-compressed down a (scale, quality) ladder until it fits. Returns
   *  (bytes, mime) or null when even the smallest step won't fit (or the image won't decode). */
  private fun fitImage(bytes: ByteArray, mime: String): Pair<ByteArray, String>? {
    // Already under budget and a format the receiver handles (png/jpeg) → send as-is, no re-encode.
    if (bytes.size <= RAW_IMAGE_BUDGET && (mime == "image/png" || mime == "image/jpeg")) return bytes to mime
    val bmp = decodeBounded(bytes) ?: return null
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

  /** Decode capped at [MAX_DECODE_PIXELS] via `inSampleSize`. A full-resolution decode is fine
   *  for the screenshots the clipboard path sees, but the share sheet hands us camera photos —
   *  a 50 MP frame is ~200 MB as ARGB_8888 and takes the foreground service down with it. */
  private fun decodeBounded(bytes: ByteArray): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (bounds.outWidth.toLong() * bounds.outHeight / (sample.toLong() * sample) > MAX_DECODE_PIXELS) {
      sample *= 2
    }
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply {
      inSampleSize = sample
    })
  }

  // ---- Direct Share (the share sheet's top row) ----------------------------

  /**
   * Publish the two share targets as long-lived dynamic shortcuts. `res/xml/selfadb_shortcuts.xml`
   * only *authorises* a target; the shortcut pushed here is what actually draws the entry in the
   * share sheet's top row, alongside Quick Share's nearby devices and WhatsApp's contacts.
   *
   * Excluded from the launcher surface: these exist to be shared *to*, and adding two entries to
   * the app's long-press menu that do nothing but open the app would be noise.
   *
   * Idempotent — re-pushing the same id updates it — so it runs on every start and again whenever
   * the Mac's name arrives or changes.
   */
  private fun refreshShareShortcuts() {
    try {
      val mac = getMacName(this)
      val shortcuts = listOf(
        shareShortcut(
          id = SHORTCUT_CLIPBOARD,
          short = "Clipboard",
          long = if (mac != null) "Clipboard on $mac" else "Send to your Mac's clipboard",
          icon = R.drawable.ic_share_clipboard,
          category = CATEGORY_CLIPBOARD,
          target = ShareToClipboardActivity::class.java,
        ),
        shareShortcut(
          id = SHORTCUT_FILE,
          short = "Save file",
          long = if (mac != null) "Save on $mac" else "Save a file on your Mac",
          icon = R.drawable.ic_share_file,
          category = CATEGORY_FILE,
          target = ShareAsFileActivity::class.java,
        ),
      )
      // The result matters: this returns false (no throw) when the push is rejected — the
      // per-app quota is full, or the system is rate-limiting a background caller.
      val ok = ShortcutManagerCompat.addDynamicShortcuts(this, shortcuts)
      ClipBus.log(
        "share shortcuts: published=$ok, max=${ShortcutManagerCompat.getMaxShortcutCountPerActivity(this)}" +
          ", rateLimited=${ShortcutManagerCompat.isRateLimitingActive(this)}"
      )
    } catch (e: Exception) {
      // Never fatal: OEM launchers have their own shortcut quotas and some reject the push.
      ClipBus.log("share shortcuts not published: ${e.message}")
    }
  }

  private fun shareShortcut(
    id: String,
    short: String,
    long: String,
    icon: Int,
    category: String,
    target: Class<*>,
  ): ShortcutInfoCompat =
    ShortcutInfoCompat.Builder(this, id)
      .setShortLabel(short)
      .setLongLabel(long)
      .setLongLived(true)
      .setIcon(IconCompat.createWithResource(this, icon))
      .setCategories(setOf(category))
      // Required by the builder even though Direct Share replaces it with the real share intent.
      .setIntent(Intent(this, target).setAction(Intent.ACTION_DEFAULT))
      .setExcludedFromSurfaces(ShortcutInfoCompat.SURFACE_LAUNCHER)
      .build()

  /** Note the Mac's name off its `stat` frame, so the Direct Share entries can say whose Mac this
   *  is instead of a generic "your Mac". Persisted (the shortcuts outlive the process) and only
   *  re-pushed when it actually changed — a `stat` arrives on every battery tick. */
  private fun rememberMacName(json: String) {
    val name = try {
      JSONObject(json).optString("name").takeIf { it.isNotBlank() }
    } catch (e: Exception) {
      null
    } ?: return
    if (name == getMacName(this)) return
    getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).edit().putString(KEY_MAC_NAME, name).apply()
    refreshShareShortcuts()
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
    shareExec.shutdownNow()
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
    private const val CHANNEL_FILE = "linktomac_file"
    /** Separate from [CHANNEL_FILE]: progress is a running status, not an event, so it gets its
     *  own LOW-importance channel and never alerts. */
    private const val CHANNEL_TRANSFER = "linktomac_transfer"
    /** cacheDir subfolder holding in-flight + just-completed inbound transfers. */
    private const val INBOX_DIR = "inbox"
    private const val NOTIF_ID = 1001
    private const val SMS_ALERT_NOTIF_ID = 1002
    /** First id for received-file notifications; each arrival takes the next one. */
    private const val FILE_NOTIF_ID_BASE = 2000
    /** Fixed ids for the two progress bars (one transfer per direction at a time: outbound is
     *  serialised on [shareExec], inbound is realistically one file). */
    private const val TRANSFER_OUT_NOTIF_ID = 1003
    private const val TRANSFER_IN_NOTIF_ID = 1004
    /** Minimum gap between progress updates. The notification manager rate-limits, and a LAN
     *  transfer can complete dozens of chunks a second. */
    private const val PROGRESS_THROTTLE_MS = 400L
    /** PendingIntent request code for the notification's "Send clipboard" action. */
    private const val REQ_SEND_CLIPBOARD = 1
    private const val EXTRA_PORT = "port"

    /** Start-intent action carrying a manually captured clip (see [submitClip]). */
    private const val ACTION_SUBMIT_CLIP = "expo.modules.selfadb.SUBMIT_CLIP"
    private const val EXTRA_TEXT = "text"

    /** Start-intent action carrying a share-sheet send (see [submitShare]). */
    private const val ACTION_SUBMIT_SHARE = "expo.modules.selfadb.SUBMIT_SHARE"
    private const val EXTRA_PATH = "path"
    private const val EXTRA_NAME = "name"
    private const val EXTRA_MIME = "mime"
    private const val EXTRA_DISP = "disp"

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

    /**
     * Hand a share-sheet payload to the service. [path] is a file the caller already staged in
     * our own cache — [ShareActivity] has to copy it there anyway (its URI grant dies with the
     * activity), and a path survives the Binder transaction limit that the bytes would not.
     * The service deletes it when the send finishes, however it finishes.
     */
    fun submitShare(ctx: Context, path: String, name: String, mime: String, disp: String) {
      val intent = Intent(ctx, ClipForegroundService::class.java)
        .setAction(ACTION_SUBMIT_SHARE)
        .putExtra(EXTRA_PATH, path)
        .putExtra(EXTRA_NAME, name)
        .putExtra(EXTRA_MIME, mime)
        .putExtra(EXTRA_DISP, disp)
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
    /** The Mac's device name, learned from its `stat` frames — see [rememberMacName]. */
    private const val KEY_MAC_NAME = "macName"
    private const val KEY_DAEMON_SECRET = "daemonSecret"
    private const val KEY_CLIP_PORT = "clipPort"
    /** How long a write stamp lives before it can no longer suppress an echo. */
    private const val ECHO_WINDOW_MS = 10_000L
    /** Raw image budget before sealing: ~700 KB → ~960 KB frame after base64, under the relay's
     *  1 MiB cap. Same budget as the Mac's `ImagePrep`; bump both with `MAX_PAYLOAD_BYTES`. */
    private const val RAW_IMAGE_BUDGET = 700 * 1024
    /** (scale, JPEG quality) ladder for fitting an oversize image; first output under budget wins.
     *  The last two steps exist for the share sheet: a full-frame camera photo is still well over
     *  budget at half scale, and stopping there would reject the most common thing a user shares. */
    private val IMAGE_FIT_STEPS =
      listOf(1.0f to 0.8f, 0.7f to 0.7f, 0.5f to 0.5f, 0.35f to 0.5f, 0.25f to 0.4f)

    /** Pixel ceiling for [decodeBounded]: 4 MP is ~16 MB as ARGB_8888, plenty for something that
     *  is about to be squeezed under [RAW_IMAGE_BUDGET] anyway. */
    private const val MAX_DECODE_PIXELS = 4L * 1024 * 1024

    /** Biggest source file the clipboard path will read whole (it decodes from a ByteArray).
     *  Anything larger belongs on the "Send as a File" path, which streams. */
    private const val MAX_CLIPBOARD_SOURCE_BYTES = 32L * 1024 * 1024

    /** Chunks allowed in flight unacknowledged. At ~853 KB on the wire each, four keeps the
     *  relay's per-peer buffer near 3 MB — comfortably under the 8 MiB at which it hangs up. */
    private const val ACK_WINDOW = 4

    /** How long one chunk may go unacknowledged before the transfer is declared dead. Generous:
     *  it covers a relay reconnect, not just a slow link. */
    private const val ACK_TIMEOUT_MS = 30_000L

    /** Minimum gap between chunk sends ON THE RELAY: 8 frames/s against the relay's 120-per-10 s
     *  per-connection limit, leaving headroom for `stat`/ping traffic and for the Mac's ack
     *  stream, which is counted against *its* connection at the same rate. Coupled to the relay's
     *  `RATE_LIMIT_MSGS`/`RATE_LIMIT_WINDOW_MS` — revisit this if either moves. It costs nothing
     *  real: 8 x 640 KiB is ~5 MB/s, far above any relay link. */
    private const val RELAY_CHUNK_INTERVAL_MS = 125L

    private const val NOT_CONNECTED = "Your Mac isn't connected"

    // Direct Share ids + categories. The categories must match res/xml/selfadb_shortcuts.xml
    // exactly or the system refuses to use the shortcut as a share target.
    private const val SHORTCUT_CLIPBOARD = "share-clipboard"
    private const val SHORTCUT_FILE = "share-file"
    private const val CATEGORY_CLIPBOARD = "expo.modules.selfadb.category.CLIPBOARD"
    private const val CATEGORY_FILE = "expo.modules.selfadb.category.FILE"
    const val DEFAULT_PORT = 53123

    /** The daemon port this install actually runs on (per-variant; JS passes it to autoStart).
     *  Persisted in PREFS_UI so START_STICKY restarts and adb-free liveness checks agree with
     *  the JS-chosen port instead of assuming [DEFAULT_PORT]. */
    /** The paired Mac's name, or null before its first `stat` arrives. */
    fun getMacName(ctx: Context): String? =
      ctx.getSharedPreferences(PREFS_UI, Context.MODE_PRIVATE).getString(KEY_MAC_NAME, null)

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
