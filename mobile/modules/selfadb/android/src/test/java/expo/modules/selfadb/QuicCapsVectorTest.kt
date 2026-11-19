package expo.modules.selfadb

import expo.modules.selfadb.quic.PeerCaps
import expo.modules.selfadb.quic.QuicCaps
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * `stat.caps` (plan stage 1.4): how each side learns whether the other speaks the QUIC session protocol. Runs the shared vectors
 * (`protocol-vectors/quic-control.json`, section `stat`); the Mac's `QuicCapsVectorTests` runs the same file.
 */
class QuicCapsVectorTest {
  private fun cases(kind: String): List<JSONObject> {
    val dir = requireNotNull(System.getProperty("vectors.dir")) { "vectors.dir not set (see build.gradle)" }
    val all: JSONArray = JSONObject(File(dir, "quic-control.json").readText()).getJSONObject("stat").getJSONArray("cases")
    return (0 until all.length()).map { all.getJSONObject(it) }.filter { it.getString("kind") == kind }
  }

  private fun names(a: JSONArray?): Set<String> = if (a == null) emptySet() else (0 until a.length()).map { a.getString(it) }.toSet()

  @Test fun theVectorFileHasTheCasesThisSuiteRuns() {
    for (kind in listOf("parse", "sequence", "available", "advertise")) assertTrue(kind, cases(kind).isNotEmpty())
  }

  @Test fun parseVectors() {
    for (c in cases("parse")) {
      val expect = c.getJSONObject("expect")
      val update = QuicCaps.parse(c.getJSONObject("stat"))
      when (expect.getString("update")) {
        "absent" -> assertEquals(c.getString("name"), QuicCaps.Update.Absent, update)
        "set" -> assertEquals(c.getString("name"), QuicCaps.Update.Known(names(expect.getJSONArray("caps"))), update)
        else -> throw AssertionError("${c.getString("name")}: unknown expected update")
      }
    }
  }

  @Test fun sequenceVectors() {
    for (c in cases("sequence")) {
      val peer = PeerCaps()
      val steps = c.getJSONArray("steps")
      val after = c.getJSONArray("after")
      assertEquals("${c.getString("name")}: steps and after differ in length", steps.length(), after.length())
      for (i in 0 until steps.length()) {
        val step = steps.getJSONObject(i)
        when (step.getString("op")) {
          "stat" -> peer.applyStat(step.getJSONObject("stat"))
          "offline" -> peer.peerWentOffline()
          else -> throw AssertionError("${c.getString("name")} step $i: unknown op")
        }
        assertEquals("${c.getString("name")} after step $i", names(after.getJSONArray(i)), peer.caps)
      }
    }
  }

  @Test fun availableVectors() {
    for (c in cases("available")) {
      val onLan = c.getBoolean("onLan")
      val caps = names(c.getJSONArray("caps"))
      val got = QuicCaps.available(onLan, caps)
      assertEquals(c.getString("name"), c.getBoolean("expect"), got)
      val peer = PeerCaps(caps)
      assertEquals("${c.getString("name")} via PeerCaps", got, peer.quicAvailable(onLan))
      peer.peerWentOffline()
      assertFalse("${c.getString("name")} after offline", peer.quicAvailable(true))
    }
  }

  @Test fun advertiseVectors() {
    for (c in cases("advertise")) {
      val want = (0 until c.getJSONArray("expect").length()).map { c.getJSONArray("expect").getString(it) }
      assertEquals(c.getString("name"), want, QuicCaps.advertised(c.getBoolean("supportsQuic")))
    }
  }

  @Test fun theAdvertisedListFitsInsideAStatObjectTheMacParses() {
    val stat = JSONObject().put("level", 80).put("caps", JSONArray(QuicCaps.advertised(true)))
    assertEquals(QuicCaps.Update.Known(setOf("q1")), QuicCaps.parse(stat))
  }

  /**
   * Run by hand, not in CI: `QUIC_STAT_JSON` holds a `stat` the MAC's own code wrote with QUIC switched on (its `QuicCaps.statFragment`
   * inside a hand-built object, exactly like `currentStatPayload`). The phone must read `q1` out of it.
   */
  @Test fun aStatTheMacWroteIsUnderstoodHere() {
    val text = System.getenv("QUIC_STAT_JSON")
    assumeTrue("no Mac-written stat provided (manual proof)", text != null)
    assertEquals(QuicCaps.Update.Known(setOf("q1")), QuicCaps.parse(JSONObject(text!!)))
    val peer = PeerCaps()
    peer.applyStat(JSONObject(text))
    assertTrue(peer.quicAvailable(onLan = true))
    assertFalse(peer.quicAvailable(onLan = false))
  }

  @Test fun aFreshPeerCapsKnowsNothing() {
    assertTrue(PeerCaps().caps.isEmpty())
    assertFalse(PeerCaps().quicAvailable(true))
  }
}
