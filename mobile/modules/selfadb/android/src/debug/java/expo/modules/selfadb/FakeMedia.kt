package expo.modules.selfadb

import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper

/**
 * Debug builds only: a media session of our own that does what many real players do — it becomes ACTIVE first and gets its title and
 * playback state a moment later. That ordering is what used to leave the Mac's media card empty until "Mirror media" was toggled
 * (`MediaMirror` picked a session only when the session LIST changed, and at that instant the session had no title yet).
 * Driven by `scripts/media-check.sh` through the debug receiver (`MEDIA_FAKE`, `MEDIA_FAKE_STOP`).
 */
object FakeMedia {
  private var session: MediaSession? = null
  private val main = Handler(Looper.getMainLooper())

  /** Activates a session now, then writes a title and PLAYING [delayMs] later. */
  fun start(context: Context, delayMs: Long = 3_000L) {
    stop()
    val s = MediaSession(context.applicationContext, "ltm-debug-fake")
    session = s
    s.setActive(true)
    main.postDelayed({
      if (session !== s) return@postDelayed
      s.setMetadata(
        MediaMetadata.Builder()
          .putString(MediaMetadata.METADATA_KEY_TITLE, "Debug track")
          .putString(MediaMetadata.METADATA_KEY_ARTIST, "Debug artist")
          .putLong(MediaMetadata.METADATA_KEY_DURATION, 180_000L)
          .build(),
      )
      s.setPlaybackState(
        PlaybackState.Builder()
          .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SEEK_TO)
          .setState(PlaybackState.STATE_PLAYING, 0L, 1f)
          .build(),
      )
    }, delayMs)
  }

  fun stop() {
    main.removeCallbacksAndMessages(null)
    session?.let { it.isActive = false; it.release() }
    session = null
  }
}
