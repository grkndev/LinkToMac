package expo.modules.selfadb

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * What the phone does with a `cmd` frame from the Mac (QUIC plan stage 1.2): open it, classify the action, and route it.
 * Everything here is plain Kotlin on the JVM; `ClipCodec` runs through the test-only `android.util.Base64` stand-in.
 *
 * `ClipCodec` remembers every nonce it has accepted (replay protection), so each test seals a fresh frame.
 */
class CmdReceiveTest {
  private val rawKey = ByteArray(32) { it.toByte() }
  private val key: String = java.util.Base64.getEncoder().encodeToString(rawKey)
  private val otherKey: String = java.util.Base64.getEncoder().encodeToString(ByteArray(32) { (255 - it).toByte() })

  private fun frame(sealed: Pair<String, String>): JSONObject =
    JSONObject().put("t", "cmd").put("nonce", sealed.first).put("ct", sealed.second)

  private fun sealCmd(action: String): JSONObject = frame(ClipCodec.encode(action, key, "cmd")!!)

  /** The v2 envelope by hand, with a timestamp the test controls (what [ClipCodec.encode] does with the real clock). */
  private fun handSealed(action: String, timestampMs: Long, type: String = "cmd"): JSONObject {
    val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
    val cipher = Cipher.getInstance("ChaCha20-Poly1305")
    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(rawKey, "ChaCha20"), IvParameterSpec(nonce))
    cipher.updateAAD(type.toByteArray(Charsets.UTF_8))
    val plain = ByteBuffer.allocate(8 + action.toByteArray(Charsets.UTF_8).size)
      .putLong(timestampMs).put(action.toByteArray(Charsets.UTF_8)).array()
    val ct = cipher.doFinal(plain)
    val b64 = java.util.Base64.getEncoder()
    return JSONObject().put("t", "cmd").put("nonce", b64.encodeToString(nonce)).put("ct", b64.encodeToString(ct))
  }

  // ---- open ---------------------------------------------------------------------------------------------------------------

  @Test fun aSealedPlainActionComesOutUnchanged() {
    assertEquals("lock", InboundCmd.open(sealCmd("lock"), key))
  }

  @Test fun aJsonActionSurvivesUnchangedIncludingNonAscii() {
    val action = """{"op":"q.req","kind":"cast","sid":"a1b2c3d4","why":"Ekran yansıtma 📺 ışığı"}"""
    assertEquals(action, InboundCmd.open(sealCmd(action), key))
  }

  @Test fun theWrongKeyCannotOpenIt() {
    assertNull(InboundCmd.open(sealCmd("lock"), otherKey))
  }

  @Test fun aMalformedKeyOpensNothing() {
    assertNull(InboundCmd.open(sealCmd("lock"), "not base64!!"))
    assertNull(InboundCmd.open(sealCmd("lock"), java.util.Base64.getEncoder().encodeToString(ByteArray(16))))
  }

  @Test fun theTypeIsBoundSoAClipCannotBePassedOffAsACmd() {
    val asClip = frame(ClipCodec.encode("lock", key, "clip")!!)
    assertNull(InboundCmd.open(asClip, key))
  }

  @Test fun aReplayedFrameIsRejectedTheSecondTime() {
    val f = sealCmd("lock")
    assertEquals("lock", InboundCmd.open(f, key))
    assertNull(InboundCmd.open(f, key))
  }

  @Test fun staleAndFutureTimestampsAreRejectedButAFreshHandSealedFrameIsAccepted() {
    // positive control first: proves the hand-sealing helper builds a valid envelope
    assertEquals("lock", InboundCmd.open(handSealed("lock", System.currentTimeMillis()), key))
    val tenMinutes = 10 * 60 * 1000L
    assertNull(InboundCmd.open(handSealed("lock", System.currentTimeMillis() - tenMinutes), key))
    assertNull(InboundCmd.open(handSealed("lock", System.currentTimeMillis() + tenMinutes), key))
  }

  @Test fun malformedInputReturnsNullWithoutThrowing() {
    val good = sealCmd("lock")
    val shortCt = java.util.Base64.getEncoder().encodeToString(ByteArray(5))
    val bad = listOf(
      JSONObject(),                                                   // nothing at all
      JSONObject().put("t", "cmd"),                                   // type only
      JSONObject().put("t", "cmd").put("nonce", good.getString("nonce")),   // no ct
      JSONObject().put("t", "cmd").put("ct", good.getString("ct")),         // no nonce
      JSONObject().put("t", "cmd").put("nonce", "").put("ct", ""),
      JSONObject().put("t", "cmd").put("nonce", "!!!!").put("ct", "????"),
      JSONObject().put("t", "cmd").put("nonce", good.getString("nonce")).put("ct", shortCt),   // shorter than the tag
      JSONObject().put("t", "cmd").put("nonce", shortCt).put("ct", good.getString("ct")),      // nonce is not 12 bytes
    )
    for (f in bad) assertNull(f.toString(), InboundCmd.open(f, key))
    // none of the failures above consumed the good frame: it still opens
    assertEquals("lock", InboundCmd.open(good, key))
  }

  // ---- classify -----------------------------------------------------------------------------------------------------------

  @Test fun anObjectIsJson() {
    assertEquals(InboundCmd.Kind.JSON, InboundCmd.classify("""{"op":"q.req"}"""))
    assertEquals(InboundCmd.Kind.JSON, InboundCmd.classify("{"))
  }

  @Test fun anyOtherNonEmptyStringIsUnknown() {
    assertEquals(InboundCmd.Kind.UNKNOWN, InboundCmd.classify("lock"))
    assertEquals(InboundCmd.Kind.UNKNOWN, InboundCmd.classify("foo bar"))
    assertEquals(InboundCmd.Kind.UNKNOWN, InboundCmd.classify("[1,2]"))
  }

  @Test fun onlyTheFirstCharacterDecidesSoLeadingWhitespaceIsUnknown() {
    assertEquals(InboundCmd.Kind.UNKNOWN, InboundCmd.classify(""" {"op":"q.req"}"""))
  }

  @Test fun anEmptyActionIsEmpty() {
    assertEquals(InboundCmd.Kind.EMPTY, InboundCmd.classify(""))
  }

  // ---- route --------------------------------------------------------------------------------------------------------------

  @Test fun aJsonActionGoesToTheDispatcherExactlyOnceAndIsNotIgnored() {
    val action = """{"op":"q.req","sid":"a1b2c3d4"}"""
    val json = mutableListOf<String>()
    val ignored = mutableListOf<Pair<InboundCmd.Kind, Int>>()
    InboundCmd.route(action, onJson = { json.add(it) }, onIgnored = { kind, len -> ignored.add(kind to len) })
    assertEquals(listOf(action), json)
    assertTrue(ignored.isEmpty())
  }

  @Test fun anUnknownOrEmptyActionIsIgnoredWithItsLengthAndNeverReachesTheDispatcher() {
    val json = mutableListOf<String>()
    val ignored = mutableListOf<Pair<InboundCmd.Kind, Int>>()
    InboundCmd.route("lock", onJson = { json.add(it) }, onIgnored = { kind, len -> ignored.add(kind to len) })
    InboundCmd.route("", onJson = { json.add(it) }, onIgnored = { kind, len -> ignored.add(kind to len) })
    assertTrue(json.isEmpty())
    assertEquals(listOf(InboundCmd.Kind.UNKNOWN to 4, InboundCmd.Kind.EMPTY to 0), ignored)
  }

  // ---- manual cross-language proof (skipped unless the environment provides a frame) -----------------------------------------

  /**
   * Run by hand, not in CI: a `cmd` frame sealed by the MAC's own `ClipCodec.swift` + `CommandFrame` must open here. Needs
   * `CMD_FRAME_JSON` (the `{"t":"cmd","nonce","ct"}` the Mac side printed), `CMD_FRAME_KEY` and `CMD_FRAME_ACTION`; the frame is
   * fresh-only (±120 s), so produce it right before the run.
   */
  @Test fun aFrameSealedByTheMacOpensHere() {
    val frameJson = System.getenv("CMD_FRAME_JSON")
    val macKey = System.getenv("CMD_FRAME_KEY")
    val expected = System.getenv("CMD_FRAME_ACTION")
    assumeTrue("no Mac-sealed frame provided (manual proof)", frameJson != null && macKey != null && expected != null)
    val opened = InboundCmd.open(JSONObject(frameJson!!), macKey!!)
    assertNotNull("the Mac-sealed frame did not open (wrong key, stale >120 s, or a codec mismatch)", opened)
    assertEquals(expected, opened)
  }
}
