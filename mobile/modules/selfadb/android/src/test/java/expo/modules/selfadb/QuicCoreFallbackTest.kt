package expo.modules.selfadb

import expo.modules.selfadb.quic.QuicCore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The JVM never has libquic_core.so, which is exactly the situation of an x86_64 emulator or of a
 * build made without `build-so.sh`. QuicCore must degrade to "unavailable", never throw.
 */
class QuicCoreFallbackTest {
  @Test
  fun missingLibraryMeansUnavailableNotACrash() {
    assertFalse(QuicCore.isAvailable())
  }

  @Test
  fun callsReturnNullInsteadOfThrowing() {
    assertNull(QuicCore.ping())
    assertNull(QuicCore.probe())
  }

  @Test
  fun failureIsRecordedAsAClassNameOnly() {
    QuicCore.isAvailable()
    val failure = QuicCore.loadFailure
    assertNotNull(failure)
    // Only the exception class name is kept: no message, so no path or other detail can leak into logs.
    assertEquals("UnsatisfiedLinkError", failure)
  }

  @Test
  fun repeatedCallsAreStable() {
    val first = QuicCore.isAvailable()
    repeat(3) {
      assertEquals(first, QuicCore.isAvailable())
      assertNull(QuicCore.ping())
    }
  }
}
