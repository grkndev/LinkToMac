package expo.modules.selfadb

import expo.modules.selfadb.LanHostBook.Source.DISCOVERED
import expo.modules.selfadb.LanHostBook.Source.HINT
import expo.modules.selfadb.LanHostBook.Source.REMEMBERED
import expo.modules.selfadb.LanHostBook.Source.SEED
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which Mac address to try, and in what order (the LAN no longer depends on mDNS alone). */
class LanHostBookTest {
  private val a = "192.168.1.10"
  private val b = "10.0.0.7"
  private val c = "172.16.0.9"
  private fun best(book: LanHostBook) = book.best()?.let { "${it.host}:${it.port}" }

  @Test fun anEmptyBookHasNoBest() {
    assertNull(LanHostBook().best())
    assertEquals(emptyList<LanHostBook.Entry>(), LanHostBook().entries())
  }

  @Test fun aFreshDiscoveryBeatsAHintBeatsTheSeedBeatsTheRemembered() {
    val book = LanHostBook()
    book.add(a, 53124, REMEMBERED); assertEquals("$a:53124", best(book))
    book.add(b, 53124, SEED); assertEquals("$b:53124", best(book))
    book.add(c, 53124, HINT); assertEquals("$c:53124", best(book))
    book.add("192.168.9.9", 53124, DISCOVERED); assertEquals("192.168.9.9:53124", best(book))
    assertEquals(listOf(DISCOVERED, HINT, SEED, REMEMBERED), book.entries().map { it.source })
  }

  @Test fun theSameAddressIsOneEntryKeepingItsBestSource() {
    val book = LanHostBook()
    book.add(a, 53124, REMEMBERED)
    book.add(a, 53124, DISCOVERED)
    book.add(a, 53124, SEED)
    assertEquals(1, book.entries().size)
    assertEquals(DISCOVERED, book.entries().single().source)
  }

  @Test fun theSameHostOnAnotherPortIsAnotherEntry() {
    val book = LanHostBook()
    book.add(a, 53124, SEED); book.add(a, 53999, SEED)
    assertEquals(2, book.entries().size)
  }

  @Test fun equalSourcesKeepTheirInsertionOrder() {
    val book = LanHostBook()
    book.add(a, 53124, HINT); book.add(b, 53124, HINT); book.add(c, 53124, HINT)
    assertEquals(listOf(a, b, c), book.entries().map { it.host })
    assertEquals("$a:53124", best(book))
  }

  @Test fun anAddressThatFailedTwiceIsSkippedUntilReset() {
    val book = LanHostBook()
    book.add(a, 53124, DISCOVERED); book.add(b, 53124, HINT)
    book.markFailed(a, 53124)
    assertEquals("one failure is not enough", "$a:53124", best(book))
    book.markFailed(a, 53124)
    assertEquals("$b:53124", best(book))
    book.markFailed(b, 53124); book.markFailed(b, 53124)
    assertNull("everything failed", best(book))
    book.resetFailures()
    assertEquals("$a:53124", best(book))
  }

  @Test fun failingAnUnknownAddressChangesNothing() {
    val book = LanHostBook()
    book.add(a, 53124, SEED)
    book.markFailed(b, 53124); book.markFailed(b, 53124)
    assertEquals("$a:53124", best(book))
    assertEquals(1, book.entries().size)
  }

  @Test fun aJoinedAddressIsPreferredAndForgivenItsFailures() {
    val book = LanHostBook()
    book.add(a, 53124, DISCOVERED); book.add(b, 53124, REMEMBERED)
    book.markFailed(b, 53124); book.markFailed(b, 53124)
    book.markJoined(b, 53124)
    assertEquals("$b:53124", best(book))
    book.markFailed(a, 53124)
    assertEquals("the joined one stays first even against a fresh discovery", "$b:53124", best(book))
  }

  @Test fun onlyTheLastAddressThatJoinedCountsAsJoined() {
    val book = LanHostBook()
    book.markJoined(a, 53124)
    book.markJoined(b, 53124)
    assertEquals(listOf(false, true), listOf(a, b).map { h -> book.entries().first { it.host == h }.joined })
    assertEquals("$b:53124", best(book))
    book.add("192.168.9.9", 53124, DISCOVERED)
    assertEquals("the latest joined one still leads, a is not joined any more", listOf(b, "192.168.9.9", a), book.entries().map { it.host })
  }

  @Test fun markJoinedOnAnUnknownAddressAddsItAsRemembered() {
    val book = LanHostBook()
    book.markJoined(a, 53124)
    val e = book.entries().single()
    assertEquals("$a:53124", "${e.host}:${e.port}")
    assertTrue(e.joined)
  }

  @Test fun newHintsReplaceTheOldHintsButNotOtherSources() {
    val book = LanHostBook()
    book.add(a, 53124, SEED)
    book.offerHints(listOf(StatLan.Hint(b, 53124), StatLan.Hint(c, 53124)))
    assertEquals(setOf(a, b, c), book.entries().map { it.host }.toSet())
    book.offerHints(listOf(StatLan.Hint("10.9.9.9", 53124)))
    assertEquals(setOf(a, "10.9.9.9"), book.entries().map { it.host }.toSet())
    assertEquals(SEED, book.entries().first { it.host == a }.source)
  }

  @Test fun anEmptyHintListDropsAllHints() {
    val book = LanHostBook()
    book.offerHints(listOf(StatLan.Hint(a, 53124)))
    book.offerHints(emptyList())
    assertTrue(book.entries().isEmpty())
  }

  @Test fun aHintForAnAddressWeAlreadyRememberUpgradesItAndSurvivesTheNextHintSetOnlyIfStillHinted() {
    val book = LanHostBook()
    book.add(a, 53124, REMEMBERED)
    book.offerHints(listOf(StatLan.Hint(a, 53124)))
    assertEquals(HINT, book.entries().single().source)
    book.offerHints(listOf(StatLan.Hint(b, 53124)))
    // a is no longer hinted: it falls back to what it was before (remembered), it is not forgotten
    assertEquals(REMEMBERED, book.entries().first { it.host == a }.source)
  }

  @Test fun theBookHoldsAtMostFourEntriesDroppingTheLeastPreferred() {
    val book = LanHostBook()
    book.add("10.0.0.1", 53124, REMEMBERED)
    book.add("10.0.0.2", 53124, SEED)
    book.add("10.0.0.3", 53124, HINT)
    book.add("10.0.0.4", 53124, DISCOVERED)
    book.add("10.0.0.5", 53124, HINT)
    assertEquals(4, book.entries().size)
    assertFalse("the remembered one was the least preferred", book.entries().any { it.host == "10.0.0.1" })
    assertEquals("10.0.0.4", book.entries().first().host)
  }

  @Test fun anInvalidAddressIsRefused() {
    val book = LanHostBook()
    assertFalse(book.add("", 53124, SEED))
    assertFalse(book.add("  ", 53124, SEED))
    assertFalse(book.add(a, 0, SEED))
    assertFalse(book.add(a, 65536, SEED))
    assertFalse(book.add(a, -1, SEED))
    assertTrue(book.entries().isEmpty())
    assertTrue(book.add(a, 1, SEED))
  }

  @Test fun theBookNeverPrintsAnAddress() {
    val book = LanHostBook(); book.add(a, 53124, SEED)
    assertFalse(book.toString().contains(a))
    assertFalse(book.entries().single().toString().contains(a))
  }
}
