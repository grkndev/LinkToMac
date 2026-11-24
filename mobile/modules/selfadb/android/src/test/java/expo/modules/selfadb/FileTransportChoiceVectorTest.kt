package expo.modules.selfadb

import expo.modules.selfadb.quic.FileTransportChoice
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.File

/**
 * Which path a file takes (plan stage 2.1, Faz 2): runs the `transport` section of `protocol-vectors/quic-control.json`; the Mac's
 * `FileTransportChoiceTests` runs the same file. Also pins what no vector can: the WebSocket size limit is ONE number on both sides.
 */
class FileTransportChoiceVectorTest {
  private fun doc(): JSONObject {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    return JSONObject(File(dir, "quic-control.json").readText())
  }

  private fun cases(): List<JSONObject> {
    val all: JSONArray = doc().getJSONObject("transport").getJSONArray("cases")
    return (0 until all.length()).map { all.getJSONObject(it) }
  }

  private fun sizeOf(c: JSONObject): Long? = if (c.isNull("size")) null else c.getLong("size")
  private fun capsOf(c: JSONObject): Set<String> = c.getJSONArray("caps").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
  private fun linkOf(c: JSONObject) = if (c.getString("link") == "lan") FileTransportChoice.Link.LAN else FileTransportChoice.Link.RELAY

  private fun word(s: String): FileTransportChoice = when (s) {
    "quic" -> FileTransportChoice.QUIC
    "ws" -> FileTransportChoice.WS
    "waitForLan" -> FileTransportChoice.WAIT_FOR_LAN
    "tooLarge" -> FileTransportChoice.TOO_LARGE
    else -> throw AssertionError("unknown expected word $s")
  }

  private val limit = 1_073_741_824L

  @Test fun theVectorFileHasTheCasesThisSuiteRuns() {
    assertEquals(72, cases().size)
  }

  @Test fun transportVectors() {
    for (c in cases()) {
      val got = FileTransportChoice.choose(linkOf(c), capsOf(c), sizeOf(c), c.getBoolean("clipboard"))
      assertEquals(c.getString("name"), word(c.getString("expect")), got)
    }
  }

  /** 2 links x 3 capability sets x 6 sizes x 2 kinds: none may be missing and none may be doubled. */
  @Test fun theVectorsAreTheFullCrossProduct() {
    val seen = cases().map { c ->
      "${c.getString("link")}|${capsOf(c).sorted().joinToString("+")}|${sizeOf(c) ?: "null"}|${if (c.getBoolean("clipboard")) 1 else 0}"
    }
    val want = buildSet {
      for (link in listOf("lan", "relay")) for (caps in listOf("q1", "", "q2"))
        for (size in listOf("null", "0", "1", "$limit", "${limit + 1}", "${10 * limit}"))
          for (clip in listOf(0, 1)) add("$link|$caps|$size|$clip")
    }
    assertEquals(72, want.size)
    assertEquals("a combination is doubled or missing", 72, seen.size)
    assertEquals(want, seen.toSet())
  }

  @Test fun theWebSocketLimitIsOneNumberOnBothSides() {
    assertEquals(doc().getJSONObject("constants").getJSONObject("values").getLong("ws_file_limit_bytes"), FileFrame.MAX_TRANSFER_BYTES.toLong())
    assertEquals(limit, FileFrame.MAX_TRANSFER_BYTES.toLong())
  }

  @Test fun theExactEdgeIsTheLimitItselfAndOneByteMore() {
    val relay = FileTransportChoice.Link.RELAY
    val lan = FileTransportChoice.Link.LAN
    for (caps in listOf(emptySet(), setOf("q1"))) assertEquals(FileTransportChoice.WS, FileTransportChoice.choose(relay, caps, limit, false))
    assertEquals(FileTransportChoice.WAIT_FOR_LAN, FileTransportChoice.choose(relay, setOf("q1"), limit + 1, false))
    assertEquals(FileTransportChoice.TOO_LARGE, FileTransportChoice.choose(relay, emptySet(), limit + 1, false))
    assertEquals(FileTransportChoice.TOO_LARGE, FileTransportChoice.choose(lan, emptySet(), limit + 1, false))
    assertEquals(FileTransportChoice.QUIC, FileTransportChoice.choose(lan, setOf("q1"), limit + 1, false))
  }

  @Test fun aNegativeSizeIsAnUnknownSize() {
    for (link in FileTransportChoice.Link.values()) for (caps in listOf(emptySet(), setOf("q1"))) {
      assertEquals(FileTransportChoice.choose(link, caps, null, false), FileTransportChoice.choose(link, caps, -1L, false))
    }
  }

  @Test fun aClipboardImageNeverLeavesTheWebSocketPath() {
    for (link in FileTransportChoice.Link.values()) for (size in listOf(null, 0L, 700_000L, limit + 1)) {
      assertEquals(FileTransportChoice.WS, FileTransportChoice.choose(link, setOf("q1"), size, true))
    }
  }

  /** Until the QUIC file stream exists (stage 2.5) a QUIC verdict cannot be acted on: the call sites use `effective`. */
  @Test fun whileQuicFilesAreNotServedQuicEffectivelyMeansTheWebSocketPath() {
    assertFalse(FileTransportChoice.QUIC_FILES_SERVED)
    assertEquals(FileTransportChoice.WS, FileTransportChoice.QUIC.effective)
    assertEquals(FileTransportChoice.WS, FileTransportChoice.WS.effective)
    assertEquals(FileTransportChoice.WAIT_FOR_LAN, FileTransportChoice.WAIT_FOR_LAN.effective)
    assertEquals(FileTransportChoice.TOO_LARGE, FileTransportChoice.TOO_LARGE.effective)
  }

  @Test fun theLogWordsAreFixedSentencesWithNothingAboutTheFile() {
    assertEquals("quic", FileTransportChoice.QUIC.logWord)
    assertEquals("ws", FileTransportChoice.WS.logWord)
    assertEquals("wait-for-lan", FileTransportChoice.WAIT_FOR_LAN.logWord)
    assertEquals("too-large", FileTransportChoice.TOO_LARGE.logWord)
  }
}
