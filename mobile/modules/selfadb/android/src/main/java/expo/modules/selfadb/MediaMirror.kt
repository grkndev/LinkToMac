package expo.modules.selfadb

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Base64
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream

/**
 * Mirrors what the phone is playing to the Mac, and carries the Mac's play/pause/next/seek/volume
 * back to it. FGS-owned like [SmsMirror], so it survives an app swipe.
 *
 * **No ADB, no daemon, no shell.** It needs exactly one thing: the "Notification access" grant the
 * app already asks for, because [MediaSessionManager.getActiveSessions] only answers a caller that
 * names an enabled notification listener ([NotificationListener]). Controls go out through the
 * session's own `transportControls` and [AudioManager] — both ordinary app APIs. Without the grant
 * the platform throws [SecurityException]; that becomes `{"media":{"on":false,"reason":"no-access"}}`
 * so the Mac card can say what to fix.
 *
 * Wire format and the "is this worth a frame" decision live in [MediaState] (unit-tested). The one
 * rule here: a state is sent when it **changes**, never as a ticking position — the Mac advances the
 * progress itself (see `NowPlaying.positionMs`), and the relay rate-limits a chatty peer.
 *
 * Privacy: titles, artists and app names never reach a log line — only counts, states and exception
 * class names (`scripts/check-log-privacy.mjs`).
 *
 * Threading: everything runs on one private [HandlerThread]; the public methods only post to it.
 */
class MediaMirror(
  private val context: Context,
  /** Sends one ready `stat` payload (→ `ClipForegroundService.sendStat`). */
  private val send: (String) -> Unit,
  private val log: (String) -> Unit,
) {
  private val thread = HandlerThread("media-mirror").also { it.start() }
  private val handler = Handler(thread.looper)
  private val sessions = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
  private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  private val listenerComponent = ComponentName(context, NotificationListener::class.java)

  // All below: touched only on [handler]'s thread.
  private var registered = false
  private var stopped = false
  private var controller: MediaController? = null
  private var lastSent: MediaSnapshot? = null
  private var lastSentAt = 0L
  /** Whether the last frame told the Mac we have no access (so it isn't repeated every callback). */
  private var sentNoAccess = false
  private var flushPending = false
  /** The track whose cover the Mac already holds, so one cover goes out per track. */
  private var artSentFor: String? = null
  /** The last cover payload, kept to re-send it when the Mac reconnects (its cache is in memory). */
  private var lastArt: Pair<String, String>? = null
  private val appLabels = HashMap<String, String>()

  private val sessionsListener = MediaSessionManager.OnActiveSessionsChangedListener { list ->
    adopt(list.orEmpty())
    schedule()
  }

  private val controllerCallback = object : MediaController.Callback() {
    override fun onMetadataChanged(metadata: MediaMetadata?) = schedule()
    override fun onPlaybackStateChanged(state: PlaybackState?) = schedule()
    override fun onAudioInfoChanged(info: MediaController.PlaybackInfo) = schedule()
    override fun onSessionDestroyed() {
      handler.post {
        controller = null
        refreshSessions()
        schedule()
      }
    }
  }

  /** The music-stream volume has no callback of its own; this broadcast is how every volume UI learns of it. */
  private val volumeReceiver = object : BroadcastReceiver() {
    override fun onReceive(c: Context?, intent: Intent?) {
      schedule()
    }
  }

  // ---- lifecycle ------------------------------------------------------------------------------

  fun start() {
    handler.post {
      if (stopped) return@post
      ContextCompat.registerReceiver(
        context, volumeReceiver, IntentFilter(VOLUME_CHANGED_ACTION), ContextCompat.RECEIVER_NOT_EXPORTED,
      )
      register()
      refreshSessions()
      flush(force = false)
    }
  }

  /** Detach everything. Tells the Mac the card is off so it doesn't keep showing a stale track. */
  fun stop(reason: String? = "off") {
    handler.post {
      if (stopped) return@post
      stopped = true
      handler.removeCallbacksAndMessages(null)
      try { context.unregisterReceiver(volumeReceiver) } catch (_: Exception) {}
      if (registered) {
        try { sessions.removeOnActiveSessionsChangedListener(sessionsListener) } catch (_: Exception) {}
      }
      registered = false
      detachController()
      if (reason != null) send(MediaState.statUnavailable(reason))
      thread.quitSafely()
    }
  }

  /**
   * Send the current state whatever was sent before — the Mac (re)connected, or the notification
   * grant just changed. Always sends something (a track, `null` or "no access"), so the Mac never
   * has to guess why its card is empty.
   */
  fun pushSnapshot() {
    handler.post {
      if (stopped) return@post
      if (!registered) register()
      refreshSessions()
      lastSent = null
      sentNoAccess = false
      artSentFor = null
      flush(force = true)
    }
  }

  /** Re-check access (the user may just have granted it) and publish. */
  fun refresh() {
    handler.post {
      if (stopped) return@post
      if (!registered) register()
      refreshSessions()
      schedule()
    }
  }

  // ---- reading the sessions -------------------------------------------------------------------

  private fun register() {
    try {
      sessions.addOnActiveSessionsChangedListener(sessionsListener, listenerComponent, handler)
      registered = true
    } catch (e: SecurityException) {
      registered = false
    } catch (e: Exception) {
      registered = false
      log("media: could not watch sessions (${e.javaClass.simpleName})")
    }
  }

  private fun refreshSessions() {
    try {
      adopt(sessions.getActiveSessions(listenerComponent))
    } catch (e: SecurityException) {
      detachController()
    } catch (e: Exception) {
      log("media: could not list sessions (${e.javaClass.simpleName})")
    }
  }

  /** Follow the session [MediaState.pickCurrent] chooses. */
  private fun adopt(list: List<MediaController>) {
    val candidates = list.map {
      MediaState.Candidate(
        playing = it.playbackState?.state == PlaybackState.STATE_PLAYING,
        hasMetadata = !titleOf(it.metadata).isNullOrBlank(),
      )
    }
    val next = MediaState.pickCurrent(candidates)?.let { list[it] }
    if (sameSession(next, controller)) return
    detachController()
    controller = next
    try {
      next?.registerCallback(controllerCallback, handler)
    } catch (e: Exception) {
      log("media: could not follow the session (${e.javaClass.simpleName})")
      controller = null
    }
    log("media: session ${if (controller != null) "followed" else "none"} of ${list.size}")
  }

  private fun sameSession(a: MediaController?, b: MediaController?): Boolean =
    a === b || (a != null && b != null && a.sessionToken == b.sessionToken)

  private fun detachController() {
    try { controller?.unregisterCallback(controllerCallback) } catch (_: Exception) {}
    controller = null
  }

  // ---- publishing -----------------------------------------------------------------------------

  /** Coalesce a burst of callbacks (a track change fires several) into one look. */
  private fun schedule() {
    handler.post {
      if (stopped || flushPending) return@post
      flushPending = true
      handler.postDelayed({
        flushPending = false
        flush(force = false)
      }, COALESCE_MS)
    }
  }

  private fun flush(force: Boolean) {
    if (stopped) return
    if (!registered) {
      // Not allowed (yet): say so once; a grant calls [refresh]/[pushSnapshot].
      if (!sentNoAccess || force) {
        send(MediaState.statUnavailable("no-access"))
        sentNoAccess = true
      }
      return
    }
    sentNoAccess = false
    val now = SystemClock.elapsedRealtime()
    val snap = snapshot(now)
    if (force || MediaState.changedMeaningfully(lastSent, snap, now - lastSentAt)) {
      send(MediaState.statWithMedia(snap))
      lastSent = snap
      lastSentAt = now
    }
    if (snap != null) sendArtIfNew(snap.id)
  }

  /** One cover per track; retried on later callbacks when the app publishes the bitmap after the title. */
  private fun sendArtIfNew(id: String) {
    if (artSentFor == id) return
    val cached = lastArt?.takeIf { it.first == id }
    val b64 = cached?.second ?: encodeCover(controller?.metadata)?.also { lastArt = id to it }
    if (b64 == null) return
    send(MediaState.statArt(id, b64))
    artSentFor = id
  }

  private fun snapshot(now: Long): MediaSnapshot? {
    val c = controller ?: return null
    val md = c.metadata
    val title = titleOf(md)
    if (title.isNullOrBlank()) return null
    val ps = c.playbackState
    val state = MediaState.stateName(ps?.state ?: PlaybackState.STATE_NONE)
    val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
      ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
      ?: md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)
      ?: ""
    val album = md?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
    val dur = (md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L).coerceAtLeast(0L)
    val speed = ps?.playbackSpeed?.takeIf { it > 0f } ?: 1f
    val pos = MediaState.currentPosition(
      posMs = ps?.position ?: -1L,
      updatedAtMs = ps?.lastPositionUpdateTime ?: now,
      nowMs = now,
      speed = speed,
      state = state,
      durMs = dur,
    )
    val actions = ps?.actions ?: 0L
    val pkg = c.packageName ?: ""
    val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    return MediaSnapshot(
      pkg = pkg,
      app = appLabel(pkg),
      id = MediaState.trackId(pkg, title, artist, dur),
      title = title,
      artist = artist,
      album = album,
      state = state,
      posMs = pos,
      durMs = dur,
      speed = speed,
      canPrev = actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS != 0L,
      canNext = actions and PlaybackState.ACTION_SKIP_TO_NEXT != 0L,
      canSeek = dur > 0 && actions and PlaybackState.ACTION_SEEK_TO != 0L,
      vol = audio.getStreamVolume(AudioManager.STREAM_MUSIC),
      volMax = max,
    )
  }

  private fun titleOf(md: MediaMetadata?): String? =
    md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: md?.getString(MediaMetadata.METADATA_KEY_TITLE)

  private fun appLabel(pkg: String): String = appLabels.getOrPut(pkg) {
    try {
      val pm = context.packageManager
      pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) {
      "" // not visible to us (package-visibility rules): the Mac simply shows no app name
    }
  }

  /** The track's cover, scaled to at most [ART_MAX_PX] on a side, as a base64 JPEG. Null when the app gave none. */
  private fun encodeCover(md: MediaMetadata?): String? {
    val src = md?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
      ?: md?.getBitmap(MediaMetadata.METADATA_KEY_ART)
      ?: md?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
      ?: return null
    return try {
      val scale = ART_MAX_PX.toFloat() / maxOf(src.width, src.height)
      val bmp = if (scale < 1f) {
        Bitmap.createScaledBitmap(src, (src.width * scale).toInt().coerceAtLeast(1), (src.height * scale).toInt().coerceAtLeast(1), true)
      } else src
      var quality = 70
      var bytes: ByteArray
      do {
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
        bytes = out.toByteArray()
        quality -= 20
      } while (bytes.size > ART_MAX_BYTES && quality >= 10)
      if (bytes.size > ART_MAX_BYTES) null else Base64.encodeToString(bytes, Base64.NO_WRAP)
    } catch (e: Exception) {
      log("media: cover not encoded (${e.javaClass.simpleName})")
      null
    }
  }

  // ---- controls from the Mac ------------------------------------------------------------------

  fun control(cmd: MediaCommand) {
    handler.post {
      if (stopped) return@post
      try {
        when (cmd) {
          is MediaCommand.Volume -> setVolume(cmd.level)
          else -> transport(cmd)
        }
      } catch (e: Exception) {
        log("media: command refused (${e.javaClass.simpleName})")
      }
      schedule()
    }
  }

  private fun transport(cmd: MediaCommand) {
    val c = controller ?: return
    val t = c.transportControls
    when (cmd) {
      MediaCommand.Toggle ->
        if (MediaState.stateName(c.playbackState?.state ?: PlaybackState.STATE_NONE) == "playing") t.pause() else t.play()
      MediaCommand.Play -> t.play()
      MediaCommand.Pause -> t.pause()
      MediaCommand.Next -> t.skipToNext()
      MediaCommand.Prev -> t.skipToPrevious()
      is MediaCommand.Seek -> t.seekTo(cmd.ms)
      is MediaCommand.Volume -> Unit
    }
  }

  private fun setVolume(level: Int) {
    val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    audio.setStreamVolume(AudioManager.STREAM_MUSIC, level.coerceIn(0, max), 0)
  }

  private companion object {
    /** `AudioManager.VOLUME_CHANGED_ACTION` — not in the public SDK, but what every volume UI listens to. */
    const val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"
    const val COALESCE_MS = 250L
    const val ART_MAX_PX = 256
    /** Keeps the base64 cover far below the relay's 1 MiB frame cap. */
    const val ART_MAX_BYTES = 150_000
  }
}
