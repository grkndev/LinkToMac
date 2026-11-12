package expo.modules.selfadb

import org.junit.Assert.assertEquals
import org.junit.Test

class ExitReasonsTest {
  @Test fun namesTheReasonsThatExplainSilentDeaths() {
    assertEquals("LOW_MEMORY", ExitReasons.reasonName(3))
    assertEquals("CRASH", ExitReasons.reasonName(4))
    assertEquals("CRASH_NATIVE", ExitReasons.reasonName(5))
    assertEquals("ANR", ExitReasons.reasonName(6))
    assertEquals("USER_REQUESTED", ExitReasons.reasonName(10))
    assertEquals("USER_STOPPED", ExitReasons.reasonName(11))
    assertEquals("EXCESSIVE_RESOURCE_USAGE", ExitReasons.reasonName(9))
    assertEquals("FREEZER", ExitReasons.reasonName(14))
  }

  @Test fun anUnknownReasonDegradesInsteadOfFailing() {
    assertEquals("REASON_99", ExitReasons.reasonName(99))
    assertEquals("REASON_-1", ExitReasons.reasonName(-1))
  }

  @Test fun importanceNames() {
    assertEquals("FOREGROUND", ExitReasons.importanceName(100))
    assertEquals("FOREGROUND_SERVICE", ExitReasons.importanceName(125))
    assertEquals("VISIBLE", ExitReasons.importanceName(200))
    assertEquals("SERVICE", ExitReasons.importanceName(300))
    assertEquals("CACHED", ExitReasons.importanceName(400))
    assertEquals("GONE", ExitReasons.importanceName(1000))
    assertEquals("IMPORTANCE_777", ExitReasons.importanceName(777))
  }

  @Test fun descriptionIsTrimmedAndCapped() {
    assertEquals("", ExitReasons.cleanDescription(null))
    assertEquals("", ExitReasons.cleanDescription("   "))
    assertEquals("stop com.x", ExitReasons.cleanDescription("  stop com.x \n"))
    val long = "a".repeat(500)
    val capped = ExitReasons.cleanDescription(long)
    assertEquals(ExitReasons.MAX_DESCRIPTION, capped.length)
    assertEquals('…', capped.last())
  }
}
