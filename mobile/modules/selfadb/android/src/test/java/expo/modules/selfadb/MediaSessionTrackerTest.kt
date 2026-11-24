package expo.modules.selfadb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which media session the phone mirrors, and WHEN it looks again. The bug this pins: a player activates its session first and writes the title a
 * moment later; the old code chose a session only when the session LIST changed, found no title, followed nothing, and so never heard about the
 * title: the Mac's card stayed empty until "Mirror media" was toggled.
 */
class MediaSessionTrackerTest {
  private class Fake(val token: String, var playing: Boolean = false, var title: Boolean = false)

  private val registered = mutableListOf<String>()
  private val unregistered = mutableListOf<String>()
  private val failing = mutableSetOf<String>()
  private val errors = mutableListOf<String>()

  private fun tracker() = MediaSessionTracker<Fake>(
    tokenOf = { it.token },
    candidateOf = { MediaState.Candidate(playing = it.playing, hasMetadata = it.title) },
    register = { if (it.token in failing) error("cannot follow"); registered += it.token },
    unregister = { unregistered += it.token },
    onError = { c, _ -> errors += c.token },
  )

  @Test fun aSessionWithoutATitleIsStillWatched() {
    val t = tracker()
    val a = Fake("a")
    t.update(listOf(a))
    assertEquals(listOf("a"), registered)
    assertNull(t.current)
  }

  /** THE regression. */
  @Test fun theTitleArrivingLaterIsPickedUpWithoutAnotherListChange() {
    val t = tracker()
    val a = Fake("a")
    t.update(listOf(a))
    assertNull(t.current)
    a.title = true; a.playing = true
    assertTrue("a change of current is reported", t.reevaluate())
    assertSame(a, t.current)
    assertEquals("watching it did not need a second registration", listOf("a"), registered)
  }

  @Test fun reevaluatingWithNothingNewChangesNothing() {
    val t = tracker()
    val a = Fake("a", playing = true, title = true)
    t.update(listOf(a))
    assertFalse(t.reevaluate())
    assertFalse(t.reevaluate())
    assertEquals(listOf("a"), registered)
    assertTrue(unregistered.isEmpty())
  }

  @Test fun aSessionThatStartsPlayingWhileAnotherIsPausedTakesOver() {
    val t = tracker()
    val paused = Fake("paused", playing = false, title = true)
    val other = Fake("other", playing = false, title = true)
    t.update(listOf(paused, other))
    assertSame("the first one with something to show", paused, t.current)
    other.playing = true
    assertTrue(t.reevaluate())
    assertSame(other, t.current)
  }

  @Test fun playingBeatsPausedWhateverTheOrderAndAPausedTitleBeatsNothing() {
    val t = tracker()
    val bare = Fake("bare")
    val paused = Fake("paused", title = true)
    val playing = Fake("playing", playing = true, title = true)
    t.update(listOf(bare, paused, playing))
    assertSame(playing, t.current)
    playing.playing = false
    t.reevaluate()
    assertSame("nothing plays: the first one with a title", paused, t.current)
    paused.title = false
    t.reevaluate()
    assertSame("the only one left with a title, although it is not playing now", playing, t.current)
  }

  @Test fun anEqualPriorityKeepsTheListOrder() {
    val t = tracker()
    val a = Fake("a", playing = true, title = true)
    val b = Fake("b", playing = true, title = true)
    t.update(listOf(a, b))
    assertSame(a, t.current)
    t.update(listOf(b, a))
    assertSame("the list is in priority order (most recently active first): b now leads", b, t.current)
  }

  @Test fun aSessionThatGoesAwayIsReleasedExactlyOnceAndTheNextOneTakesOver() {
    val t = tracker()
    val a = Fake("a", playing = true, title = true)
    val b = Fake("b", title = true)
    t.update(listOf(a, b))
    assertSame(a, t.current)
    assertTrue(t.update(listOf(b)))
    assertEquals(listOf("a"), unregistered)
    assertSame(b, t.current)
    t.update(listOf(b))
    assertEquals("not released again", listOf("a"), unregistered)
  }

  @Test fun anEmptyListReleasesEverythingAndLeavesNoCurrent() {
    val t = tracker()
    t.update(listOf(Fake("a", title = true), Fake("b", title = true)))
    assertTrue(t.update(emptyList()))
    assertNull(t.current)
    assertEquals(setOf("a", "b"), unregistered.toSet())
    assertEquals(2, unregistered.size)
  }

  @Test fun theSameSessionTwiceOrAnEqualTokenIsRegisteredOnce() {
    val t = tracker()
    val a = Fake("a", title = true)
    t.update(listOf(a, a))
    t.update(listOf(a))
    t.update(listOf(Fake("a", title = true))) // a new object for the same session token
    assertEquals(listOf("a"), registered)
    assertTrue(unregistered.isEmpty())
    assertEquals("a", t.current?.token)
  }

  @Test fun aSessionThatCannotBeFollowedDoesNotHurtTheOthersAndIsRetriedLater() {
    val t = tracker()
    failing += "bad"
    val bad = Fake("bad", playing = true, title = true)
    val good = Fake("good", title = true)
    t.update(listOf(bad, good))
    assertSame("the unfollowable one is not chosen", good, t.current)
    assertEquals(listOf("bad"), errors)
    failing.clear()
    t.update(listOf(bad, good))
    assertSame("registered on the next update, and it plays", bad, t.current)
    assertEquals(listOf("good", "bad"), registered)
  }

  @Test fun updateSaysWhetherTheChosenSessionChanged() {
    val t = tracker()
    val a = Fake("a", playing = true, title = true)
    assertTrue(t.update(listOf(a)))
    assertFalse("same session, nothing new", t.update(listOf(a)))
    assertTrue("it went away", t.update(emptyList()))
    assertFalse("still nothing", t.update(emptyList()))
  }

  @Test fun aCandidateThatThrowsIsTreatedAsHavingNothingToShow() {
    val t = MediaSessionTracker<Fake>(
      tokenOf = { it.token },
      candidateOf = { if (it.token == "boom") throw SecurityException("no access") else MediaState.Candidate(it.playing, it.title) },
      register = { registered += it.token },
      unregister = { unregistered += it.token },
    )
    val ok = Fake("ok", title = true)
    t.update(listOf(Fake("boom", playing = true, title = true), ok))
    assertSame(ok, t.current)
  }

  @Test fun clearReleasesEverythingOnceAndTheTrackerIsReusable() {
    val t = tracker()
    t.update(listOf(Fake("a", title = true), Fake("b", title = true)))
    t.clear()
    t.clear()
    assertNull(t.current)
    assertEquals(2, unregistered.size)
    val c = Fake("c", title = true)
    t.update(listOf(c))
    assertSame(c, t.current)
  }
}
