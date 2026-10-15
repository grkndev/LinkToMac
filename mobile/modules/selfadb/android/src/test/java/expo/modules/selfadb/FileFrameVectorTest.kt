package expo.modules.selfadb

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The shared wire vectors (`protocol-vectors/file-frame.json`) — the Mac codec runs the same file.
 * They exist because the two codecs are mirrored by hand and drifted once already: Swift omitted
 * `id` on one-chunk files, so the phone never acked anything small.
 */
class FileFrameVectorTest {

  private fun cases(kind: String): List<JSONObject> {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    val doc = JSONObject(File(dir, "file-frame.json").readText())
    val all: JSONArray = doc.getJSONArray("cases")
    return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.getString("kind") == kind }
  }

  private fun hex(s: String): ByteArray =
    ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

  private fun JSONObject.str(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)

  /** Split a frame into (header object, body). */
  private fun split(frame: ByteArray): Pair<JSONObject, ByteArray> {
    val headerLen = ((frame[0].toInt() and 0xFF) shl 8) or (frame[1].toInt() and 0xFF)
    val header = JSONObject(String(frame, 2, headerLen, Charsets.UTF_8))
    return header to frame.copyOfRange(2 + headerLen, frame.size)
  }

  private fun build(p: JSONObject): ByteArray {
    val id = p.optString("id")
    val seq = p.optInt("seq", 0)
    return when (p.optString("op", "data")) {
      FileFrame.OP_ACK -> FileFrame.ack(id, seq, if (p.has("have")) p.getInt("have") else null)
      FileFrame.OP_NACK -> FileFrame.nack(id, seq, p.str("reason"))
      else -> {
        val bytes = hex(p.optString("bytes_hex"))
        FileFrame.encode(
          mime = p.getString("mime"),
          bytes = bytes,
          name = p.str("name"),
          dir = p.str("dir"),
          disp = p.optString("disp", FileFrame.DISP_CLIP),
          id = p.str("id"),
          seq = seq,
          count = p.optInt("count", 1),
        )
      }
    }
  }

  @Test
  fun everyVectorParsesToTheExpectedFields() {
    val cases = cases("roundtrip")
    assertTrue("no roundtrip vectors loaded", cases.isNotEmpty())
    for (c in cases) {
      val name = c.getString("name")
      val frame = assertNotNull_("$name: did not parse", FileFrame.parse(hex(c.getString("frame_hex"))))
      val want = c.getJSONObject("parsed")
      assertEquals("$name: op", want.getString("op"), frame.op)
      assertEquals("$name: mime", want.getString("mime"), frame.mime)
      assertEquals("$name: name", want.str("name"), frame.name)
      assertEquals("$name: dir", want.str("dir"), frame.dir)
      assertEquals("$name: disp", want.getString("disp"), frame.disp)
      assertEquals("$name: id", want.str("id"), frame.id)
      assertEquals("$name: seq", want.getInt("seq"), frame.seq)
      assertEquals("$name: count", want.getInt("count"), frame.count)
      assertEquals("$name: reason", want.str("reason"), frame.reason)
      assertEquals("$name: have", if (want.isNull("have")) null else want.getInt("have"), frame.have)
      assertEquals("$name: bytes", want.getString("bytes_hex"), frame.bytes.joinToString("") { "%02x".format(it) })
    }
  }

  @Test
  fun everyVectorEncodesToTheExpectedHeader() {
    for (c in cases("roundtrip")) {
      val name = c.getString("name")
      val params = c.getJSONObject("params")
      val (header, body) = split(build(params))
      // Compared as objects: org.json and Swift's JSONSerialization disagree on key order.
      assertHeaderEquals("$name: header", c.getJSONObject("header"), header)
      assertEquals("$name: body", params.optString("bytes_hex"), body.joinToString("") { "%02x".format(it) })
    }
  }

  @Test
  fun overlongNamesAndDirsFitTheHeaderPrefix() {
    val cases = cases("fits")
    assertTrue("no fits vectors loaded", cases.isNotEmpty())
    for (c in cases) {
      val name = c.getString("name")
      val p = c.getJSONObject("params")
      fun expand(key: String): String? =
        p.optJSONObject(key)?.let { it.getString("char").repeat(it.getInt("times")) }
      val longName = expand("name_repeat")!!
      val frame = FileFrame.encode(
        mime = p.getString("mime"),
        bytes = hex(p.getString("bytes_hex")),
        name = longName,
        dir = expand("dir_repeat"),
        disp = p.getString("disp"),
        id = p.getString("id"),
        seq = p.getInt("seq"),
        count = p.getInt("count"),
      )
      val want = c.getJSONObject("expect")
      val headerLen = ((frame[0].toInt() and 0xFF) shl 8) or (frame[1].toInt() and 0xFF)
      assertTrue("$name: header length $headerLen", headerLen <= want.getInt("max_header_bytes"))
      val (header, body) = split(frame)
      assertEquals("$name: dir dropped", want.getBoolean("dir_dropped"), !header.has("dir"))
      assertTrue("$name: name shortened", header.optString("name").length < longName.length)
      assertEquals("$name: id", want.getString("id"), header.getString("id"))
      assertEquals("$name: seq", want.getInt("seq"), header.getInt("seq"))
      assertEquals("$name: n", want.getInt("count"), header.getInt("n"))
      assertEquals("$name: body", want.getString("bytes_hex"), body.joinToString("") { "%02x".format(it) })
      assertNotNull("$name: parses", FileFrame.parse(frame))
    }
  }

  @Test
  fun dirSanitizeVectors() {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    val cases = JSONObject(File(dir, "dir-sanitize.json").readText()).getJSONArray("cases")
    assertTrue("no dir-sanitize vectors loaded", cases.length() > 0)
    for (i in 0 until cases.length()) {
      val c = cases.getJSONObject(i)
      val input = if (c.isNull("input")) null else c.getString("input")
      assertEquals(c.getString("name"), c.getString("expected"), FileSink.sanitizeDir(input))
    }
  }

  @Test
  fun malformedVectorsParseToNothing() {
    val cases = cases("malformed")
    assertTrue("no malformed vectors loaded", cases.isNotEmpty())
    for (c in cases) assertNull(c.getString("name"), FileFrame.parse(hex(c.getString("frame_hex"))))
  }

  /** Order-insensitive object equality (the android.jar org.json stub has no toMap/similar). */
  private fun assertHeaderEquals(message: String, expected: JSONObject, actual: JSONObject) {
    val want = expected.keys().asSequence().toSet()
    val got = actual.keys().asSequence().toSet()
    assertEquals("$message: keys", want, got)
    for (k in want) assertEquals("$message: $k", expected.get(k).toString(), actual.get(k).toString())
  }

  private fun <T : Any> assertNotNull_(message: String, value: T?): T {
    assertNotNull(message, value)
    return value!!
  }
}
