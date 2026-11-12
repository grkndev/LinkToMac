package expo.modules.selfadb

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Runs the shared vectors (`protocol-vectors/stat-media.json`) — the Mac's `NowPlayingTests` run the
 * same file — plus the phone-side decisions that have no Mac twin.
 */
class MediaStateTest {

  private fun cases(kind: String): List<JSONObject> {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    val all: JSONArray = JSONObject(File(dir, "stat-media.json").readText()).getJSONArray("cases")
    return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.getString("kind") == kind }
  }

  /** A snapshot read back from a wire `media` object — enough to check the key names and omissions. */
  private fun snapshotFrom(m: JSONObject): MediaSnapshot {
    val can = m.optJSONObject("can") ?: JSONObject()
    return MediaSnapshot(
      pkg = m.getString("pkg"), app = m.getString("app"), id = m.getString("id"),
      title = m.getString("title"), artist = m.optString("artist", ""), album = m.optString("album", ""),
      state = m.getString("state"), posMs = m.getLong("pos"), durMs = m.optLong("dur", 0),
      speed = m.getDouble("speed").toFloat(),
      canPrev = can.getBoolean("prev"), canNext = can.getBoolean("next"), canSeek = can.getBoolean("seek"),
      vol = m.getInt("vol"), volMax = m.getInt("volMax"),
    )
  }

  /** Same keys, same values (numbers compared as numbers), recursively. */
  private fun assertSameJson(expected: JSONObject, actual: JSONObject, path: String = "") {
    assertEquals("keys at '$path'", expected.keys().asSequence().toSet(), actual.keys().asSequence().toSet())
    for (k in expected.keys()) {
      val e = expected.get(k)
      val a = actual.get(k)
      when {
        e is JSONObject && a is JSONObject -> assertSameJson(e, a, "$path/$k")
        e is Number && a is Number -> assertEquals("$path/$k", e.toDouble(), a.toDouble(), 1e-9)
        else -> assertEquals("$path/$k", e, a)
      }
    }
  }

  @Test fun theMediaObjectMatchesTheSharedVectors() {
    val states = cases("state")
    assertTrue("no state vectors found", states.isNotEmpty())
    for (c in states) {
      val wire = c.getJSONObject("wire").getJSONObject("media")
      assertSameJson(wire, MediaState.toJson(snapshotFrom(wire)), c.getString("name"))
    }
  }

  @Test fun theNonTrackStatesMatchTheSharedVectors() {
    for (c in cases("special")) {
      val wire = c.getJSONObject("wire")
      val built = when (c.getString("name")) {
        "no_session_clears_the_card" -> MediaState.statWithMedia(null)
        "notification_access_missing" -> MediaState.statUnavailable("no-access")
        else -> error("unhandled special vector ${c.getString("name")}")
      }
      assertSameJson(wire, JSONObject(built), c.getString("name"))
    }
  }

  @Test fun theCommandsAreReadAsTheVectorsSay() {
    val all = cases("command") + cases("phone_only")
    assertTrue(all.size >= 8)
    for (c in all) {
      val got = MediaState.parseCommand(c.getJSONObject("cmd").toString())
      val expect = if (c.isNull("expect")) null else c.getJSONObject("expect")
      val name = c.getString("name")
      if (expect == null) {
        assertNull(name, got)
        continue
      }
      val want: MediaCommand = when (expect.getString("action")) {
        "toggle" -> MediaCommand.Toggle
        "play" -> MediaCommand.Play
        "pause" -> MediaCommand.Pause
        "next" -> MediaCommand.Next
        "prev" -> MediaCommand.Prev
        "seek" -> MediaCommand.Seek(expect.getLong("value"))
        "vol" -> MediaCommand.Volume(expect.getInt("value"))
        else -> error("unknown action in $name")
      }
      assertEquals(name, want, got)
    }
  }

  @Test fun theProgressInterpolationMatchesTheSharedVectors() {
    // The Mac does this on its side; the phone uses the same arithmetic to say where playback IS.
    for (c in cases("position")) {
      val p = c.getJSONObject("params")
      val got = MediaState.currentPosition(
        posMs = p.getLong("pos"), updatedAtMs = 0, nowMs = p.getLong("dt_ms"),
        speed = p.getDouble("speed").toFloat(), state = p.getString("state"), durMs = p.getLong("dur"),
      )
      assertEquals(c.getString("name"), c.getLong("expect_ms"), got)
    }
  }

  @Test fun anUnknownPositionCountsAsTheStart() {
    assertEquals(0L, MediaState.currentPosition(-1, 0, 5000, 1f, "paused", 100_000))
  }

  @Test fun playbackStatesMapToTheFourWords() {
    assertEquals("playing", MediaState.stateName(3))
    assertEquals("playing", MediaState.stateName(4)) // fast-forwarding: moving
    assertEquals("paused", MediaState.stateName(2))
    assertEquals("buffering", MediaState.stateName(6))
    assertEquals("buffering", MediaState.stateName(10)) // skipping to next
    for (s in listOf(0, 1, 7, 99)) assertEquals("stopped", MediaState.stateName(s))
  }

  @Test fun theTrackIdFollowsTheTrackNotThePosition() {
    val a = MediaState.trackId("com.x", "Song", "Artist", 200_000)
    assertEquals(12, a.length)
    assertEquals(a, MediaState.trackId("com.x", "Song", "Artist", 200_000))
    assertNotEquals(a, MediaState.trackId("com.x", "Other", "Artist", 200_000))
    assertNotEquals(a, MediaState.trackId("com.y", "Song", "Artist", 200_000))
    assertNotEquals(a, MediaState.trackId("com.x", "Song", "Artist", 201_000))
  }

  @Test fun theCurrentSessionIsThePlayingOneElseTheFirstWithSomethingToShow() {
    fun c(playing: Boolean, hasMetadata: Boolean) = MediaState.Candidate(playing, hasMetadata)
    assertNull(MediaState.pickCurrent(emptyList()))
    assertNull(MediaState.pickCurrent(listOf(c(playing = false, hasMetadata = false))))
    // priority order: first playing wins even when an earlier one is merely paused
    assertEquals(1, MediaState.pickCurrent(listOf(c(false, true), c(true, true), c(true, true))))
    // nothing playing: the highest-priority one that has metadata
    assertEquals(1, MediaState.pickCurrent(listOf(c(false, false), c(false, true), c(false, true))))
    // "playing" without metadata is not a card
    assertEquals(1, MediaState.pickCurrent(listOf(c(true, false), c(false, true))))
  }

  private fun snap(pos: Long = 10_000, state: String = "playing", title: String = "T", vol: Int = 5) = MediaSnapshot(
    pkg = "p", app = "A", id = "i", title = title, artist = "x", album = "", state = state, posMs = pos,
    durMs = 200_000, speed = 1f, canPrev = true, canNext = true, canSeek = true, vol = vol, volMax = 15,
  )

  @Test fun aPlayingTrackThatSimplyKeptAdvancingIsNotAChange() {
    // 3 s later the callback reports 13 s: exactly where the Mac's own interpolation already is.
    assertFalse(MediaState.changedMeaningfully(snap(10_000), snap(13_000), elapsedMs = 3_000))
    // within the tolerance
    assertFalse(MediaState.changedMeaningfully(snap(10_000), snap(14_200), elapsedMs = 3_000))
  }

  @Test fun aSeekAnythingElseTheMacShowsIsAChange() {
    assertTrue("seek forward", MediaState.changedMeaningfully(snap(10_000), snap(90_000), elapsedMs = 3_000))
    assertTrue("seek back", MediaState.changedMeaningfully(snap(60_000), snap(5_000), elapsedMs = 1_000))
    assertTrue("pause", MediaState.changedMeaningfully(snap(10_000), snap(10_000, state = "paused"), 1_000))
    assertTrue("new title", MediaState.changedMeaningfully(snap(), snap(title = "Other"), 1_000))
    assertTrue("volume", MediaState.changedMeaningfully(snap(), snap(vol = 6), 1_000))
    assertTrue("paused then moved", MediaState.changedMeaningfully(snap(state = "paused"), snap(20_000, "paused"), 5_000))
    assertFalse("paused and still", MediaState.changedMeaningfully(snap(state = "paused"), snap(state = "paused"), 5_000))
  }

  @Test fun appearingAndDisappearingAreChanges() {
    assertTrue(MediaState.changedMeaningfully(null, snap(), 0))
    assertTrue(MediaState.changedMeaningfully(snap(), null, 0))
    assertFalse(MediaState.changedMeaningfully(null, null, 0))
  }

  @Test fun theArtFrameCarriesTheTrackIdAndTheImage() {
    val o = JSONObject(MediaState.statArt("abc123", "QUJD")).getJSONObject("mediaArt")
    assertEquals("abc123", o.getString("id"))
    assertEquals("QUJD", o.getString("jpeg"))
  }
}
