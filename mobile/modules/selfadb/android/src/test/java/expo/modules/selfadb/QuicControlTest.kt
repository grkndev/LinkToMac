package expo.modules.selfadb

import expo.modules.selfadb.quic.QuicAction
import expo.modules.selfadb.quic.QuicControl
import expo.modules.selfadb.quic.QuicKind
import expo.modules.selfadb.quic.QuicOffer
import expo.modules.selfadb.quic.QuicParse
import expo.modules.selfadb.quic.QuicRejectReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The `q.*` actions that open and close a QUIC session (plan stage 1.3). The Swift twin (`QuicControlTests`) runs the SAME cases; the
 * golden strings below must stay byte-identical in both files.
 */
class QuicControlTest {
  private val sid = "123e4567-e89b-12d3-a456-426614174000"
  private val fp = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  private val tok = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" // bytes 0x00...0x1F, base64url, no padding
  private val tokUrlChars = "----------------------------------------__8" // exercises '-' and '_'

  private fun parse(s: String, echo: Boolean = false): QuicParse = QuicControl.parse(s, echo)
  private fun action(a: QuicAction) = QuicParse.Action(a)
  private fun invalid(code: String) = QuicParse.Invalid(code)
  private fun offerJson(
    sid: String = this.sid, port: String = "53125", fp: String = this.fp, tok: String = this.tok, extra: String = "",
  ) = """{"a":"q.offer","sid":"$sid","port":$port,"fp":"$fp","tok":"$tok"$extra}"""

  // ---- each action parses -----------------------------------------------------------------------------------------------

  @Test fun aRequestParses() {
    assertEquals(action(QuicAction.Request(sid, QuicKind.CAST)), parse("""{"a":"q.req","sid":"$sid","kind":"cast"}"""))
    for ((wire, kind) in listOf("cast" to QuicKind.CAST, "file" to QuicKind.FILE, "audio" to QuicKind.AUDIO, "cam" to QuicKind.CAM)) {
      assertEquals(action(QuicAction.Request(sid, kind)), parse("""{"a":"q.req","sid":"$sid","kind":"$wire"}"""))
    }
  }

  @Test fun anAcceptParses() = assertEquals(action(QuicAction.Accept(sid)), parse("""{"a":"q.accept","sid":"$sid"}"""))
  @Test fun anEndParses() = assertEquals(action(QuicAction.End(sid)), parse("""{"a":"q.end","sid":"$sid"}"""))

  @Test fun aRejectParsesWithEveryReason() {
    for (r in QuicRejectReason.values()) {
      assertEquals(action(QuicAction.Reject(sid, r)), parse("""{"a":"q.reject","sid":"$sid","reason":"${r.wire}"}"""))
    }
    assertEquals(5, QuicRejectReason.values().size)
  }

  @Test fun anOfferParsesWithAllItsFields() {
    assertEquals(action(QuicAction.Offer(QuicOffer(sid, 53125, fp, tok))), parse(offerJson()))
    assertEquals(action(QuicAction.Offer(QuicOffer(sid, 53125, fp, tokUrlChars))), parse(offerJson(tok = tokUrlChars)))
  }

  @Test fun theSessionIdIsNormalisedToLowerCase() {
    // the Mac writes UUID.uuidString (upper case), the phone UUID.toString() (lower case)
    assertEquals(action(QuicAction.Accept(sid)), parse("""{"a":"q.accept","sid":"${sid.uppercase()}"}"""))
  }

  @Test fun unknownExtraFieldsAreIgnoredSoNewerPeersStillWork() {
    val withExtras = offerJson(extra = ""","audio":{"t":"dgram"},"future":[1,2,3],"x":null""")
    assertEquals(action(QuicAction.Offer(QuicOffer(sid, 53125, fp, tok))), parse(withExtras))
    assertEquals(
      action(QuicAction.Request(sid, QuicKind.FILE)),
      parse("""{"a":"q.req","sid":"$sid","kind":"file","name":"a.bin","size":123}"""),
    )
  }

  // ---- encode (canonical, byte-identical with the Swift side) -------------------------------------------------------------

  // GOLDEN-BEGIN
  // req     {"a":"q.req","kind":"cast","sid":"123e4567-e89b-12d3-a456-426614174000"}
  // accept  {"a":"q.accept","sid":"123e4567-e89b-12d3-a456-426614174000"}
  // offer   {"a":"q.offer","fp":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","port":53125,"sid":"123e4567-e89b-12d3-a456-426614174000","tok":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}
  // reject  {"a":"q.reject","reason":"busy","sid":"123e4567-e89b-12d3-a456-426614174000"}
  // end     {"a":"q.end","sid":"123e4567-e89b-12d3-a456-426614174000"}
  // GOLDEN-END
  @Test fun encodingMatchesTheGoldenStrings() {
    assertEquals("""{"a":"q.req","kind":"cast","sid":"123e4567-e89b-12d3-a456-426614174000"}""", QuicControl.encode(QuicAction.Request(sid, QuicKind.CAST)))
    assertEquals("""{"a":"q.accept","sid":"123e4567-e89b-12d3-a456-426614174000"}""", QuicControl.encode(QuicAction.Accept(sid)))
    assertEquals(
      """{"a":"q.offer","fp":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","port":53125,"sid":"123e4567-e89b-12d3-a456-426614174000","tok":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}""",
      QuicControl.encode(QuicAction.Offer(QuicOffer(sid, 53125, fp, tok))),
    )
    assertEquals("""{"a":"q.reject","reason":"busy","sid":"123e4567-e89b-12d3-a456-426614174000"}""", QuicControl.encode(QuicAction.Reject(sid, QuicRejectReason.BUSY)))
    assertEquals("""{"a":"q.end","sid":"123e4567-e89b-12d3-a456-426614174000"}""", QuicControl.encode(QuicAction.End(sid)))
  }

  @Test fun everyEncodedActionParsesBackToItself() {
    val actions = listOf<QuicAction>(
      QuicAction.Request(sid, QuicKind.CAST), QuicAction.Request(sid, QuicKind.FILE), QuicAction.Request(sid, QuicKind.AUDIO),
      QuicAction.Request(sid, QuicKind.CAM), QuicAction.Accept(sid), QuicAction.End(sid),
      QuicAction.Reject(sid, QuicRejectReason.RELAY), QuicAction.Reject(sid, QuicRejectReason.TIMEOUT),
      QuicAction.Offer(QuicOffer(sid, 1024, fp, tok)), QuicAction.Offer(QuicOffer(sid, 65535, fp, tokUrlChars)),
    )
    for (a in actions) assertEquals(a.toString(), action(a), parse(QuicControl.encode(a)))
  }

  @Test fun encodingLowerCasesASessionIdSoBothSidesWriteTheSameBytes() {
    assertEquals(QuicControl.encode(QuicAction.End(sid)), QuicControl.encode(QuicAction.End(sid.uppercase())))
  }

  @Test fun theEchoKindEncodesAndParsesWhenAllowed() {
    val text = QuicControl.encode(QuicAction.Request(sid, QuicKind.ECHO))
    assertEquals(action(QuicAction.Request(sid, QuicKind.ECHO)), parse(text, echo = true))
  }

  // ---- validation: session id ---------------------------------------------------------------------------------------------

  @Test fun aBadSessionIdIsInvalid() {
    val bad = listOf(
      "", "123", "123e4567e89b12d3a456426614174000", "{123e4567-e89b-12d3-a456-426614174000}",
      "123e4567-e89b-12d3-a456-42661417400g", "123e4567-e89b-12d3-a456-4266141740000", "123e4567-e89b-12d3-a456-42661417400",
    )
    for (s in bad) assertEquals(s, invalid("sid"), parse("""{"a":"q.accept","sid":"$s"}"""))
    assertEquals(invalid("sid"), parse("""{"a":"q.accept"}"""))
    assertEquals(invalid("sid"), parse("""{"a":"q.accept","sid":123}"""))
    assertEquals(invalid("sid"), parse("""{"a":"q.end","sid":null}"""))
  }

  // ---- validation: kind ---------------------------------------------------------------------------------------------------

  @Test fun aBadKindIsInvalid() {
    for (k in listOf("video", "CAST", "Cast", "", "cast ", "echo")) {
      assertEquals(k, invalid("kind"), parse("""{"a":"q.req","sid":"$sid","kind":"$k"}"""))
    }
    assertEquals(invalid("kind"), parse("""{"a":"q.req","sid":"$sid"}"""))
    assertEquals(invalid("kind"), parse("""{"a":"q.req","sid":"$sid","kind":1}"""))
  }

  @Test fun theEchoKindOnlyExistsInADebugBuild() {
    val text = """{"a":"q.req","sid":"$sid","kind":"echo"}"""
    assertEquals(invalid("kind"), parse(text, echo = false))
    assertEquals(action(QuicAction.Request(sid, QuicKind.ECHO)), parse(text, echo = true))
  }

  @Test fun theDebugEchoGateDoesNotAffectOtherKinds() {
    assertEquals(action(QuicAction.Request(sid, QuicKind.CAM)), parse("""{"a":"q.req","sid":"$sid","kind":"cam"}""", echo = true))
  }

  // ---- validation: port ---------------------------------------------------------------------------------------------------

  @Test fun thePortMustBeAnIntegerInTheUnprivilegedRange() {
    for (good in listOf("1024", "53125", "65535")) assertTrue(good, parse(offerJson(port = good)) is QuicParse.Action)
    val bad = listOf("1023", "65536", "0", "-1", "99999999999999999999", "53125.5", "53125.0", "5.3125e4", "true", "null", "\"53125\"", "[]")
    for (b in bad) assertEquals(b, invalid("port"), parse(offerJson(port = b)))
    assertEquals(invalid("port"), parse("""{"a":"q.offer","sid":"$sid","fp":"$fp","tok":"$tok"}"""))
  }

  // ---- validation: fp -----------------------------------------------------------------------------------------------------

  @Test fun theFingerprintIsExactly64LowerCaseHexCharacters() {
    for (bad in listOf(fp.dropLast(1), fp + "a", fp.uppercase(), "g".repeat(64), "")) assertEquals(bad, invalid("fp"), parse(offerJson(fp = bad)))
    assertEquals(invalid("fp"), parse("""{"a":"q.offer","sid":"$sid","port":53125,"tok":"$tok"}"""))
    assertEquals(invalid("fp"), parse("""{"a":"q.offer","sid":"$sid","port":53125,"fp":7,"tok":"$tok"}"""))
  }

  // ---- validation: tok ----------------------------------------------------------------------------------------------------

  @Test fun theTokenIsCanonicalUnpaddedBase64urlOf32Bytes() {
    val bad = listOf(
      tok.dropLast(1), // 42 characters
      tok + "A", // 44 characters
      "$tok=", // padded
      tok.dropLast(1) + "+", // '+' is standard base64, not url-safe
      tok.dropLast(1) + "/",
      tok.dropLast(1) + "9", // right length and alphabet, but not the canonical encoding of any 32 bytes
      "A".repeat(42) + " ",
      "",
    )
    for (t in bad) assertEquals(t, invalid("tok"), parse(offerJson(tok = t)))
    assertEquals(invalid("tok"), parse("""{"a":"q.offer","sid":"$sid","port":53125,"fp":"$fp"}"""))
  }

  // ---- validation: reason -------------------------------------------------------------------------------------------------

  @Test fun aBadRejectReasonIsInvalid() {
    for (r in listOf("nope", "BUSY", "", "busy ")) assertEquals(r, invalid("reason"), parse("""{"a":"q.reject","sid":"$sid","reason":"$r"}"""))
    assertEquals(invalid("reason"), parse("""{"a":"q.reject","sid":"$sid"}"""))
    assertEquals(invalid("reason"), parse("""{"a":"q.reject","sid":"$sid","reason":3}"""))
  }

  // ---- size limit ---------------------------------------------------------------------------------------------------------

  @Test fun theActionLimitIs4096BytesNotCharacters() {
    fun padded(targetBytes: Int): String {
      val head = """{"a":"q.end","sid":"$sid","x":""""
      val tail = """"}"""
      return head + "a".repeat(targetBytes - head.toByteArray().size - tail.toByteArray().size) + tail
    }
    val exact = padded(4096)
    assertEquals(4096, exact.toByteArray(Charsets.UTF_8).size)
    assertEquals(action(QuicAction.End(sid)), parse(exact))
    assertEquals(invalid("too-large"), parse(padded(4097)))
    // 2049 two-byte characters are fewer than 4096 characters but more than 4096 bytes
    val twoByte = """{"a":"q.end","sid":"$sid","x":"${"é".repeat(2049)}"}"""
    assertTrue(twoByte.length < 4096 && twoByte.toByteArray(Charsets.UTF_8).size > 4096)
    assertEquals(invalid("too-large"), parse(twoByte))
  }

  // ---- unknown vs invalid vs not JSON -------------------------------------------------------------------------------------

  @Test fun anObjectWithAnUnknownOrMissingActionIsUnknownNotAnError() {
    val texts = listOf(
      """{"a":"q.future","sid":"$sid"}""", "{}", """{"a":5}""", """{"a":null}""", """{"sid":"$sid"}""", """{"a":""}""",
      """{"a":"Q.REQ","sid":"$sid","kind":"cast"}""",
    )
    for (t in texts) assertEquals(t, QuicParse.Unknown, parse(t))
  }

  @Test fun textThatIsNotAJSONObjectIsInvalidAndNeverThrows() {
    // a trailing comma is deliberately not in this list: both JSON parsers (Foundation, org.json) tolerate it, so it is undefined, not invalid
    for (t in listOf("", "{", """{"a":"q.end"""", "[1,2]", "5", "null", "lock", "not json at all", "\u0000", "{{}}")) {
      assertEquals(t, invalid("bad-json"), parse(t))
    }
  }

  // ---- manual cross-language proof (skipped unless the environment provides the Swift side's output) ----------------------------

  /**
   * Run by hand, not in CI: `QUIC_GOLDEN_LINES` holds what the MAC's `QuicControl.encode` printed for the five canonical actions, one
   * per line. Each must parse here and re-encode to the identical bytes, and match the golden strings above.
   */
  @Test fun whatTheMacEncodedParsesAndRoundTripsHere() {
    val lines = System.getenv("QUIC_GOLDEN_LINES")
    assumeTrue("no Mac-encoded lines provided (manual proof)", lines != null)
    val parsed = lines!!.trim().lines()
    assertEquals(5, parsed.size)
    val expected = listOf(
      QuicAction.Request(sid, QuicKind.CAST), QuicAction.Accept(sid), QuicAction.Offer(QuicOffer(sid, 53125, fp, tok)),
      QuicAction.Reject(sid, QuicRejectReason.BUSY), QuicAction.End(sid),
    )
    for ((line, want) in parsed.zip(expected)) {
      assertEquals(line, action(want), parse(line))
      assertEquals(line, QuicControl.encode(want))
    }
  }
}
