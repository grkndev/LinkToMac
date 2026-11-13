package expo.modules.selfadb

import org.json.JSONObject
import java.security.MessageDigest

/**
 * What the phone is playing, as the Mac needs to see it. A snapshot is built from the current
 * `MediaController` by [MediaMirror]; everything in this file is plain Kotlin on purpose, so the
 * wire format and the decisions around it are unit-tested on the JVM (the android.jar stubs would
 * make `PlaybackState` and friends useless there).
 */
data class MediaSnapshot(
  val pkg: String,
  /** Human app name ("YouTube"), resolved by the caller. */
  val app: String,
  /** [MediaState.trackId]: changes with the track, so the Mac knows when the cover art is stale. */
  val id: String,
  val title: String,
  val artist: String,
  val album: String,
  /** `playing`, `paused`, `buffering` or `stopped`. */
  val state: String,
  /** Position **now** (already advanced to the moment of the snapshot), in ms. */
  val posMs: Long,
  /** Length in ms, or 0 when unknown (a live stream). */
  val durMs: Long,
  val speed: Float,
  val canPrev: Boolean,
  val canNext: Boolean,
  val canSeek: Boolean,
  val vol: Int,
  val volMax: Int,
)

/** What the Mac can ask for. Parsed from the `mediaCmd` field of an inbound `stat`. */
sealed class MediaCommand {
  object Toggle : MediaCommand()
  object Play : MediaCommand()
  object Pause : MediaCommand()
  object Next : MediaCommand()
  object Prev : MediaCommand()
  data class Seek(val ms: Long) : MediaCommand()
  data class Volume(val level: Int) : MediaCommand()
}

/**
 * The media fields of the `stat` frame — wire format pinned by `protocol-vectors/stat-media.json`,
 * which the Mac's `NowPlaying.swift` runs too.
 *
 * Privacy: nothing here logs. A title or an artist is exactly what the log-privacy rule keeps out
 * of log lines (`scripts/check-log-privacy.mjs`).
 */
object MediaState {
  /** A position further than this from where playback should be means the user seeked. */
  const val SEEK_TOLERANCE_MS = 1500L

  // `PlaybackState.STATE_*` as literals, so the file needs no Android classes.
  private const val ST_PAUSED = 2
  private const val ST_PLAYING = 3
  private const val ST_FAST_FORWARDING = 4
  private const val ST_REWINDING = 5
  private const val ST_BUFFERING = 6
  private const val ST_CONNECTING = 8
  private const val ST_SKIPPING_TO_PREVIOUS = 9
  private const val ST_SKIPPING_TO_NEXT = 10
  private const val ST_SKIPPING_TO_QUEUE_ITEM = 11

  /** `PlaybackState.getState()` → the four words the Mac understands. */
  fun stateName(playbackState: Int): String = when (playbackState) {
    ST_PLAYING, ST_FAST_FORWARDING, ST_REWINDING -> "playing"
    ST_PAUSED -> "paused"
    ST_BUFFERING, ST_CONNECTING, ST_SKIPPING_TO_PREVIOUS, ST_SKIPPING_TO_NEXT, ST_SKIPPING_TO_QUEUE_ITEM -> "buffering"
    else -> "stopped" // STOPPED, NONE, ERROR, anything new
  }

  /**
   * Where playback is **now**. `PlaybackState` reports a position as of `updatedAtMs` plus a speed,
   * so a playing track has moved on since; a paused or buffering one hasn't. Clamped to the track.
   */
  fun currentPosition(posMs: Long, updatedAtMs: Long, nowMs: Long, speed: Float, state: String, durMs: Long): Long {
    var pos = if (posMs < 0) 0 else posMs // PLAYBACK_POSITION_UNKNOWN is -1
    if (state == "playing") pos += ((nowMs - updatedAtMs) * speed).toLong()
    if (pos < 0) pos = 0
    if (durMs > 0 && pos > durMs) pos = durMs
    return pos
  }

  /** A short, stable key for a track: the same song keeps it, the next song doesn't. */
  fun trackId(pkg: String, title: String, artist: String, durMs: Long): String {
    val digest = MessageDigest.getInstance("SHA-256").digest("$pkg|$title|$artist|$durMs".toByteArray(Charsets.UTF_8))
    return digest.take(6).joinToString("") { "%02x".format(it) }
  }

  /** The `media` object. Blank artist/album and an unknown duration are left out, not sent empty. */
  fun toJson(s: MediaSnapshot): JSONObject {
    val o = JSONObject()
      .put("on", true)
      .put("pkg", s.pkg)
      .put("app", s.app)
      .put("id", s.id)
      .put("title", s.title)
    if (s.artist.isNotBlank()) o.put("artist", s.artist)
    if (s.album.isNotBlank()) o.put("album", s.album)
    o.put("state", s.state).put("pos", s.posMs)
    if (s.durMs > 0) o.put("dur", s.durMs)
    o.put("speed", s.speed.toDouble())
      .put("can", JSONObject().put("prev", s.canPrev).put("next", s.canNext).put("seek", s.canSeek))
      .put("vol", s.vol)
      .put("volMax", s.volMax)
    return o
  }

  /** `{"media": {...}}`, or `{"media": null}` when nothing is playing any more. */
  fun statWithMedia(s: MediaSnapshot?): String =
    JSONObject().put("media", if (s == null) JSONObject.NULL else toJson(s)).toString()

  /** The Mac can't be shown anything: say why, so its card can tell the user what to fix. */
  fun statUnavailable(reason: String): String =
    JSONObject().put("media", JSONObject().put("on", false).put("reason", reason)).toString()

  /** Cover art for track [id], sent once per track. */
  fun statArt(id: String, jpegBase64: String): String =
    JSONObject().put("mediaArt", JSONObject().put("id", id).put("jpeg", jpegBase64)).toString()

  /** The command in an inbound `stat`, or null when it carries none or one we refuse. */
  fun parseCommand(statJson: String): MediaCommand? {
    val cmd = try {
      JSONObject(statJson).optJSONObject("mediaCmd")
    } catch (e: Exception) {
      null
    } ?: return null
    return when (cmd.optString("a")) {
      "toggle" -> MediaCommand.Toggle
      "play" -> MediaCommand.Play
      "pause" -> MediaCommand.Pause
      "next" -> MediaCommand.Next
      "prev" -> MediaCommand.Prev
      "seek" -> (cmd.opt("v") as? Number)?.toLong()?.takeIf { it >= 0 }?.let { MediaCommand.Seek(it) }
      "vol" -> (cmd.opt("v") as? Number)?.toInt()?.takeIf { it >= 0 }?.let { MediaCommand.Volume(it) }
      else -> null
    }
  }

  /** One active session, reduced to what choosing between them needs. */
  data class Candidate(val playing: Boolean, val hasMetadata: Boolean)

  /**
   * Which of the active sessions to show. The list arrives in priority order (the most recently
   * active first), so: the first one that is actually playing; failing that, the first one with
   * something to show. Null when there is nothing worth a card.
   */
  fun pickCurrent(candidates: List<Candidate>): Int? {
    val playing = candidates.indexOfFirst { it.playing && it.hasMetadata }
    if (playing >= 0) return playing
    val any = candidates.indexOfFirst { it.hasMetadata }
    return if (any >= 0) any else null
  }

  /**
   * Whether [next] differs from [prev] enough to be worth a frame. The relay allows 120 frames per
   * ten seconds and the platform fires callbacks freely, so a playing track whose position simply
   * kept advancing is **not** a change (the Mac advances it itself); a jump is (a seek), and so is
   * anything else the Mac displays.
   */
  fun changedMeaningfully(prev: MediaSnapshot?, next: MediaSnapshot?, elapsedMs: Long): Boolean {
    if (prev == null || next == null) return prev != next
    if (prev.copy(posMs = 0) != next.copy(posMs = 0)) return true
    return if (prev.state == "playing") {
      val expected = prev.posMs + (elapsedMs * prev.speed).toLong()
      kotlin.math.abs(next.posMs - expected) > SEEK_TOLERANCE_MS
    } else {
      next.posMs != prev.posMs
    }
  }
}
