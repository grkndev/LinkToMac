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
