package expo.modules.selfadb

import expo.modules.selfadb.quic.ChannelParse
import expo.modules.selfadb.quic.QuicAction
import expo.modules.selfadb.quic.QuicChannel
import expo.modules.selfadb.quic.QuicControl
import expo.modules.selfadb.quic.QuicHandshake
import expo.modules.selfadb.quic.QuicParse
import expo.modules.selfadb.quic.QuicSide
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * The QUIC control plane's shared vectors (plan stage 1.5): `protocol-vectors/quic-control.json`, sections `constants`, `actions`,
 * `channels` and `handshake` (the `stat` section is [QuicCapsVectorTest]). The Mac's `QuicControlVectorTests` runs the SAME file against
 * the Swift twin and the Rust core checks the ALPN, so a rule can only change by changing the file, and then every side must follow.
 */
class QuicControlVectorTest {
  private val doc: JSONObject by lazy {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    JSONObject(File(dir, "quic-control.json").readText())
  }

  private fun cases(section: String, kind: String? = null): List<JSONObject> {
    val all: JSONArray = doc.getJSONObject(section).getJSONArray("cases")
    return (0 until all.length()).map { all.getJSONObject(it) }.filter { kind == null || it.optString("kind") == kind }
  }

  private fun JSONObject.label(): String = getString("name")

  @Test fun theVectorFileHasTheSectionsThisSuiteRuns() {
    assertTrue(doc.has("constants"))
    for (section in listOf("actions", "channels", "handshake")) assertTrue(section, cases(section).isNotEmpty())
  }

  // ---- constants ----

  @Test fun constantsMatchTheFile() {
    val v = doc.getJSONObject("constants").getJSONObject("values")
    assertEquals(v.getString("alpn"), QuicControl.ALPN)
    assertEquals(v.getInt("max_action_bytes"), QuicControl.MAX_ACTION_BYTES)
    assertEquals(v.getLong("accept_timeout_ms"), QuicHandshake.DEFAULT_ACCEPT_TIMEOUT_MS)
  }

  // ---- actions ----

  /** `{PAD}` in `text` becomes `pad.char` repeated: up to a total of `to_bytes` UTF-8 bytes, or `count` times. */
  private fun textOf(c: JSONObject): String {
    val raw = c.getString("text")
    val pad = c.optJSONObject("pad") ?: return raw
    val ch = pad.getString("char")
    val count = if (pad.has("to_bytes")) {
      (pad.getInt("to_bytes") - raw.replace("{PAD}", "").toByteArray(Charsets.UTF_8).size) / ch.toByteArray(Charsets.UTF_8).size
    } else {
      pad.getInt("count")
    }
    return raw.replace("{PAD}", ch.repeat(count))
  }

  @Test fun parseVectors() {
    for (c in cases("actions", "parse")) {
      val expect = c.getJSONObject("expect")
      val parsed = QuicControl.parse(textOf(c), c.optBoolean("allow_echo", false))
      when (expect.getString("result")) {
        "action" -> {
          if (parsed is QuicParse.Action) assertEquals(c.label(), expect.getString("encoded"), QuicControl.encode(parsed.action))
          else fail("${c.label()}: got $parsed, the file expects an action")
        }
        "unknown" -> assertEquals(c.label(), QuicParse.Unknown, parsed)
        "invalid" -> assertEquals(c.label(), QuicParse.Invalid(expect.getString("code")), parsed)
        else -> fail("${c.label()}: unknown expected result")
      }
    }
  }

  /** Builds an action the way a peer would put it on the wire (a JSON object), so scenarios and encode cases go through `parse`. */
  private fun actionFrom(o: JSONObject): QuicAction {
    val parsed = QuicControl.parse(o.toString(), allowEcho = true)
    if (parsed is QuicParse.Action) return parsed.action
    throw AssertionError("the action object does not parse: $o -> $parsed")
  }

  @Test fun encodeVectors() {
    for (c in cases("actions", "encode")) {
      val action = actionFrom(c.getJSONObject("action"))
      val encoded = QuicControl.encode(action)
      assertEquals(c.label(), c.getString("expect"), encoded)
      // Every canonical string must read back as the same action.
      assertEquals("${c.label()}: round trip", QuicParse.Action(action), QuicControl.parse(encoded, allowEcho = true))
    }
  }

  // ---- channels ----

  private fun bytes(hex: String): ByteArray = ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

  private fun channel(name: String): QuicChannel = when (name) {
    "file" -> QuicChannel.FILE
    "screen" -> QuicChannel.SCREEN
    "camera" -> QuicChannel.CAMERA
    else -> throw AssertionError("unknown channel $name")
  }

  @Test fun channelHeaderVectors() {
    for (c in cases("channels", "header")) {
      val ch = channel(c.getString("channel"))
      assertTrue("${c.label()}: bytes", bytes(c.getString("hex")).contentEquals(ch.header()))
      assertEquals("${c.label()}: direction", c.getString("direction") == "bidi", ch.bidirectional)
    }
  }

  @Test fun channelParseVectors() {
    for (c in cases("channels", "parse")) {
      val expect = c.getJSONObject("expect")
      val parsed = QuicChannel.parse(bytes(c.getString("hex")))
      when (expect.getString("result")) {
        "channel" -> assertEquals(c.label(), ChannelParse.Known(channel(expect.getString("channel")), expect.getInt("consumed")), parsed)
        "unknown" -> assertEquals(c.label(), ChannelParse.Unknown(expect.getLong("value"), expect.getInt("consumed")), parsed)
        "needMoreBytes" -> assertEquals(c.label(), ChannelParse.NeedMoreBytes, parsed)
        else -> fail("${c.label()}: unknown expected result")
      }
    }
  }

  // ---- handshake ----

  private fun matches(phase: QuicHandshake.Phase, expected: JSONObject): Boolean {
    val name = expected.getString("name")
    return when (phase) {
      is QuicHandshake.Phase.AwaitingAccept -> name == "awaitingAccept" && expected.getLong("deadline_ms") == phase.deadlineMs
      is QuicHandshake.Phase.AwaitingUser -> name == "awaitingUser" && expected.getLong("deadline_ms") == phase.deadlineMs
      QuicHandshake.Phase.AwaitingOffer -> name == "awaitingOffer"
      QuicHandshake.Phase.MayOffer -> name == "mayOffer"
      is QuicHandshake.Phase.Offered -> name == "offered"
      is QuicHandshake.Phase.Closed -> name == "closed" && when (val r = phase.reason) {
        QuicHandshake.Close.Ended -> expected.getString("close") == "ended" && !expected.has("reason")
        QuicHandshake.Close.TimedOut -> expected.getString("close") == "timedOut" && !expected.has("reason")
        is QuicHandshake.Close.Rejected -> expected.getString("close") == "rejected" && expected.optString("reason") == r.reason.wire
      }
    }
  }

  @Test fun handshakeVectors() {
    for (scenario in cases("handshake")) {
      val timeout = if (scenario.has("timeout_ms")) scenario.getLong("timeout_ms") else QuicHandshake.DEFAULT_ACCEPT_TIMEOUT_MS
      val hs = QuicHandshake(
        if (scenario.getString("side") == "mac") QuicSide.MAC else QuicSide.PHONE,
        scenario.getBoolean("asker"), "123e4567-e89b-12d3-a456-426614174000", scenario.getLong("start_ms"), timeout,
      )
      assertTrue("${scenario.label()}: initial phase ${hs.phase}", matches(hs.phase, scenario.getJSONObject("initial")))
      val steps = scenario.getJSONArray("steps")
      for (i in 0 until steps.length()) {
        val step = steps.getJSONObject(i)
        val where = "${scenario.label()} step $i"
        val expect = step.getJSONObject("expect")
        val at = step.getLong("at_ms")
        if (step.getString("op") == "tick") {
          assertTrue("$where: phase ${hs.tick(at)}", matches(hs.phase, expect.getJSONObject("phase")))
          continue
        }
        val action = actionFrom(step.getJSONObject("action"))
        val verdict = if (step.getString("op") == "send") hs.send(action, at) else hs.receive(action, at)
        when (verdict) {
          is QuicHandshake.Verdict.Applied -> assertTrue("$where: applied ${verdict.phase}, the file expects $expect", expect.has("applied") && matches(verdict.phase, expect.getJSONObject("applied")))
          is QuicHandshake.Verdict.Ignored -> assertEquals("$where: ignored ${verdict.code}, the file expects $expect", expect.optString("ignored"), verdict.code)
        }
        if (step.has("then")) assertTrue("$where: afterwards ${hs.phase}", matches(hs.phase, step.getJSONObject("then")))
      }
    }
  }
}
