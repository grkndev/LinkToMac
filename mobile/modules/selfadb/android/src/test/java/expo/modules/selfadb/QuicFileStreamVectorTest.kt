package expo.modules.selfadb

import expo.modules.selfadb.quic.QuicFileStream
import expo.modules.selfadb.quic.QuicFileStream.FinalResult
import expo.modules.selfadb.quic.QuicFileStream.HaveResult
import expo.modules.selfadb.quic.QuicFileStream.Header
import expo.modules.selfadb.quic.QuicFileStream.HeaderInvalid
import expo.modules.selfadb.quic.QuicFileStream.HeaderResult
import expo.modules.selfadb.quic.QuicFileStream.Refusal
import expo.modules.selfadb.quic.QuicFileStream.WireError
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The QUIC file stream's bytes (plan stage 2.2, Faz 2): runs the `file_stream` section of `protocol-vectors/quic-control.json`. The Mac's
 * `QuicFileStreamTests` and the Rust core's `tests/vectors.rs` run the same file, so every byte on the stream is pinned three times.
 */
class QuicFileStreamVectorTest {
  private fun doc(): JSONObject {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    return JSONObject(File(dir, "quic-control.json").readText())
  }

  private fun cases(kind: String): List<JSONObject> {
    val all: JSONArray = doc().getJSONObject("file_stream").getJSONArray("cases")
    return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.getString("kind") == kind }
  }

  private fun name(c: JSONObject) = c.getString("name")
  private fun bytes(hex: String): ByteArray = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

  private fun header(o: JSONObject) = Header(
    dir = if (o.has("dir")) o.getString("dir") else null,
    id = o.getString("id"), mime = o.getString("mime"), mtime = o.getLong("mtime"), name = o.getString("name"), size = o.getLong("size"),
  )

  private fun expectedDecode(e: JSONObject): HeaderResult = when (e.getString("result")) {
    "header" -> HeaderResult.Parsed(header(e.getJSONObject("header")), e.getInt("consumed"))
    "needMore" -> HeaderResult.NeedMore
    else -> HeaderResult.Invalid(when (e.getString("code")) {
      "bad-id" -> HeaderInvalid.BAD_ID
      "not-file" -> HeaderInvalid.NOT_FILE
      else -> HeaderInvalid.BAD_HEADER
    })
  }

  private fun refusal(s: String?): Refusal = WireError.values().firstOrNull { it.wire == s }?.let { Refusal.Known(it) } ?: Refusal.Unknown

  @Test fun theVectorFileHasTheCasesThisSuiteRuns() {
    for (k in listOf("header_encode", "header_parse", "have_parse", "result_parse", "have_encode", "result_encode", "body_length", "finish_verdict")) {
      assertTrue(k, cases(k).isNotEmpty())
    }
    assertTrue(cases("header_parse").size >= 60)
  }

  @Test fun theLimitsAreOneNumberOnEverySide() {
    val v = doc().getJSONObject("constants").getJSONObject("values")
    assertEquals(v.getInt("file_header_max_bytes"), QuicFileStream.HEADER_MAX_BYTES)
    assertEquals(v.getInt("file_name_max_bytes"), QuicFileStream.NAME_MAX_BYTES)
    assertEquals(v.getInt("file_mime_max_bytes"), QuicFileStream.MIME_MAX_BYTES)
    assertEquals(v.getInt("file_first_byte_timeout_ms"), QuicFileStream.FIRST_BYTE_TIMEOUT_MS)
    assertEquals(v.getLong("file_size_max"), QuicFileStream.SIZE_MAX)
  }

  @Test fun headerEncodeVectors() {
    for (c in cases("header_encode")) {
      val h = header(c.getJSONObject("header"))
      val want = bytes(c.getString("hex"))
      assertArrayEquals(name(c), want, QuicFileStream.encodeHeader(h))
      assertEquals("${name(c)} round trip", HeaderResult.Parsed(h, want.size), QuicFileStream.decodeHeader(want))
    }
  }

  @Test fun headerParseVectors() {
    for (c in cases("header_parse")) {
      assertEquals(name(c), expectedDecode(c.getJSONObject("expect")), QuicFileStream.decodeHeader(bytes(c.getString("hex"))))
    }
  }

  /** A stream delivers bytes in pieces: whatever the split, the answer must be the same, and an early answer must already be the final one. */
  @Test fun headerParseGivesTheSameAnswerWhereverTheBytesAreSplit() {
    for (c in cases("header_parse")) {
      val all = bytes(c.getString("hex"))
      val want = expectedDecode(c.getJSONObject("expect"))
      for (cut in 0..all.size) {
        val d = QuicFileStream.HeaderDecoder()
        val first = d.feed(all.copyOfRange(0, cut))
        if (first != HeaderResult.NeedMore) assertEquals("${name(c)} decided too early at $cut", want, first)
        assertEquals("${name(c)} split at $cut", want, d.feed(all.copyOfRange(cut, all.size)))
      }
      val d = QuicFileStream.HeaderDecoder()
      var last: HeaderResult = HeaderResult.NeedMore
      for (b in all) last = d.feed(byteArrayOf(b))
      assertEquals("${name(c)} byte by byte", want, last)
    }
  }

  @Test fun haveParseVectors() {
    for (c in cases("have_parse")) {
      val got = QuicFileStream.parseHave(bytes(c.getString("hex")), c.getLong("size"))
      val e = c.getJSONObject("expect")
      val want: HaveResult = when (e.getString("result")) {
        "have" -> HaveResult.Have(e.getLong("have"))
        "err" -> HaveResult.Refused(refusal(e.getString("err")))
        else -> HaveResult.Invalid
      }
      assertEquals(name(c), want, got)
    }
  }

  @Test fun resultParseVectors() {
    for (c in cases("result_parse")) {
      val got = QuicFileStream.parseResult(bytes(c.getString("hex")))
      val e = c.getJSONObject("expect")
      val want: FinalResult = when (e.getString("result")) {
        "ok" -> FinalResult.Ok
        "err" -> FinalResult.Refused(refusal(e.getString("err")))
        else -> FinalResult.Invalid
      }
      assertEquals(name(c), want, got)
    }
  }

  @Test fun haveAndResultEncodeVectors() {
    for (c in cases("have_encode")) assertArrayEquals(name(c), bytes(c.getString("hex")), QuicFileStream.encodeHave(c.getLong("have")))
    for (c in cases("result_encode")) {
      val err = if (c.has("err")) WireError.values().first { it.wire == c.getString("err") } else null
      assertArrayEquals(name(c), bytes(c.getString("hex")), QuicFileStream.encodeResult(c.getBoolean("ok"), err))
    }
  }

  @Test fun bodyLengthAndFinishVerdictVectors() {
    for (c in cases("body_length")) {
      val want: Long? = if (c.isNull("expect")) null else c.getLong("expect")
      assertEquals(name(c), want, QuicFileStream.bodyLength(c.getLong("size"), c.getLong("have")))
    }
    for (c in cases("finish_verdict")) {
      val want = if (c.getString("expect") == "ok") QuicFileStream.Verdict.OK else QuicFileStream.Verdict.SIZE_MISMATCH
      assertEquals(name(c), want, QuicFileStream.finishVerdict(c.getLong("expected"), c.getLong("received")))
    }
  }

  @Test fun aMessageIsTwoLengthBytesPlusItsBody() {
    assertNull(QuicFileStream.messageLength(byteArrayOf()))
    assertNull(QuicFileStream.messageLength(byteArrayOf(0)))
    assertEquals(14, QuicFileStream.messageLength(byteArrayOf(0, 12)))
    assertEquals(4098, QuicFileStream.messageLength(byteArrayOf(0x10, 0x00, 1, 2, 3)))
  }
}
