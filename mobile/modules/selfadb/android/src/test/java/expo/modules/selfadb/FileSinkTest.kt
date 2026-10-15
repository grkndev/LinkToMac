package expo.modules.selfadb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The two pure functions that turn peer-supplied names into something safe to put on disk. */
class FileSinkTest {
  @Test fun nameKeepsOnlyTheLastPathComponent() {
    assertEquals("x.txt", FileSink.sanitize("../../x.txt", "text/plain"))
    assertEquals("x.txt", FileSink.sanitize("/etc/x.txt", "text/plain"))
    assertEquals("b.txt", FileSink.sanitize("a\\b.txt", "text/plain"))
  }

  @Test fun nameReplacesColons() {
    assertEquals("a-b.txt", FileSink.sanitize("a:b.txt", "text/plain"))
  }

  @Test fun emptyNamesFallBackToATimestampedOneWithAFittingExtension() {
    assertTrue(FileSink.sanitize(null, "image/jpeg").matches(Regex("mac-\\d+\\.jpg")))
    assertTrue(FileSink.sanitize("...", "application/pdf").matches(Regex("mac-\\d+\\.pdf")))
    assertTrue(FileSink.sanitize("  ", "image/webp").matches(Regex("mac-\\d+\\.webp")))
    assertTrue(FileSink.sanitize("", "application/zip").matches(Regex("mac-\\d+\\.bin")))
  }

  @Test fun dirKeepsPlainComponents() {
    assertEquals("Album/Sub", FileSink.sanitizeDir("Album/Sub"))
    assertEquals("Album", FileSink.sanitizeDir("Album"))
  }

  @Test fun dirCannotEscapeLinkToMac() {
    assertEquals("etc", FileSink.sanitizeDir("../../etc"))
    assertEquals("abs/path", FileSink.sanitizeDir("/abs/path"))
    assertEquals("a/b/c", FileSink.sanitizeDir("a//b/./c"))
    assertEquals("", FileSink.sanitizeDir(".."))
    assertEquals("", FileSink.sanitizeDir("..."))
  }

  @Test fun dirAcceptsWindowsSeparatorsAndStripsColons() {
    assertEquals("a/b", FileSink.sanitizeDir("a\\b"))
    assertEquals("a-b/c", FileSink.sanitizeDir("a:b/c"))
  }

  @Test fun dirIsBounded() {
    assertEquals("1/2/3/4/5/6/7/8", FileSink.sanitizeDir("1/2/3/4/5/6/7/8/9/10"))
    assertEquals("x".repeat(100), FileSink.sanitizeDir("x".repeat(150)))
  }

  @Test fun nullAndEmptyDirAreEmpty() {
    assertEquals("", FileSink.sanitizeDir(null))
    assertEquals("", FileSink.sanitizeDir(""))
  }
}

class TransferIdTest {
  @Test fun theSameFileAlwaysGetsTheSameId() {
    val a = TransferId.of("a.bin", 100, 1_000, "Trip")
    assertEquals(a, TransferId.of("a.bin", 100, 1_000, "Trip"))
    assertEquals(8, a.length)
  }

  @Test fun anyChangeToTheFileChangesTheId() {
    val base = TransferId.of("a.bin", 100, 1_000, "Trip")
    assertTrue(base != TransferId.of("a.bin", 101, 1_000, "Trip")) // size
    assertTrue(base != TransferId.of("a.bin", 100, 1_001, "Trip")) // mtime
    assertTrue(base != TransferId.of("b.bin", 100, 1_000, "Trip")) // name
    assertTrue(base != TransferId.of("a.bin", 100, 1_000, null)) // folder
  }

  @Test fun skipFullyConsumesExactlyTheRequestedBytes() {
    val data = ByteArray(300_000) { it.toByte() }
    val input = java.io.ByteArrayInputStream(data)
    assertEquals(200_000L, input.skipFully(200_000))
    assertEquals(data[200_000], input.read().toByte())
  }

  @Test fun skipFullyStopsAtTheEndOfTheStream() {
    val input = java.io.ByteArrayInputStream(ByteArray(10))
    assertEquals(10L, input.skipFully(1_000))
  }
}
