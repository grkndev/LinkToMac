package expo.modules.selfadb.quic

import org.json.JSONObject

// The `q.*` actions that open and close a QUIC session (plan stage 1.3). They travel as a JSON string inside the E2E `cmd` envelope
// (stage 1.1 sends it from the Mac, stage 1.2 receives it here). Plain Kotlin so the rules run in JVM unit tests. The Swift twin is
// `mac/Sources/LinkToMac/Quic/QuicControl.swift`: the rules and the canonical output must stay byte-identical (change both together).

enum class QuicKind(val wire: String) {
  CAST("cast"), FILE("file"), AUDIO("audio"), CAM("cam"),

  /** Debug builds only (`allowEcho`): the session echoes bytes back, for the stage 1.6 / 1.7 tests. */
  ECHO("echo"),
}

enum class QuicRejectReason(val wire: String) {
  RELAY("relay"), BUSY("busy"), DENIED("denied"), UNSUPPORTED("unsupported"), TIMEOUT("timeout"),
}

/** The Mac's answer to a request: where to connect (`port`), which certificate to pin (`fp`) and the one-time session token (`tok`). */
data class QuicOffer(val sid: String, val port: Int, val fp: String, val tok: String)

sealed class QuicAction {
  abstract val sid: String

  data class Request(override val sid: String, val kind: QuicKind) : QuicAction()
  data class Accept(override val sid: String) : QuicAction()
  data class Offer(val offer: QuicOffer) : QuicAction() {
    override val sid: String get() = offer.sid
  }
  data class Reject(override val sid: String, val reason: QuicRejectReason) : QuicAction()
  data class End(override val sid: String) : QuicAction()
}

/**
 * [Unknown] = a JSON object whose `a` is missing or not one of the five: ignored quietly so a newer peer cannot break an older one.
 * [Invalid] = a known `a` with bad fields: a short fixed code (`too-large`, `bad-json`, `sid`, `kind`, `port`, `fp`, `tok`, `reason`).
 */
sealed class QuicParse {
  data class Action(val action: QuicAction) : QuicParse()
  object Unknown : QuicParse() {
    override fun toString() = "Unknown"
  }
  data class Invalid(val code: String) : QuicParse()
}

object QuicControl {
  /** An action is at most this many UTF-8 bytes; checked before parsing, so a hostile frame cannot cost real work. */
  const val MAX_ACTION_BYTES = 4096

  /** Never throws. Unknown extra fields are ignored. [allowEcho] is true only in a debug build. */
  fun parse(action: String, allowEcho: Boolean): QuicParse {
    if (action.toByteArray(Charsets.UTF_8).size > MAX_ACTION_BYTES) return QuicParse.Invalid("too-large")
    val o = try {
      JSONObject(action)
    } catch (e: Exception) {
      return QuicParse.Invalid("bad-json")
    }
    val name = o.opt("a") as? String ?: return QuicParse.Unknown
    return when (name) {
      "q.req" -> {
        val sid = sid(o) ?: return QuicParse.Invalid("sid")
        val kind = kind(o, allowEcho) ?: return QuicParse.Invalid("kind")
        QuicParse.Action(QuicAction.Request(sid, kind))
      }
      "q.accept" -> QuicParse.Action(QuicAction.Accept(sid(o) ?: return QuicParse.Invalid("sid")))
      "q.end" -> QuicParse.Action(QuicAction.End(sid(o) ?: return QuicParse.Invalid("sid")))
      "q.reject" -> {
        val sid = sid(o) ?: return QuicParse.Invalid("sid")
        val reason = QuicRejectReason.values().firstOrNull { it.wire == (o.opt("reason") as? String) }
          ?: return QuicParse.Invalid("reason")
        QuicParse.Action(QuicAction.Reject(sid, reason))
      }
      "q.offer" -> {
        val sid = sid(o) ?: return QuicParse.Invalid("sid")
        val port = port(o) ?: return QuicParse.Invalid("port")
        val fp = fingerprint(o) ?: return QuicParse.Invalid("fp")
        val tok = token(o) ?: return QuicParse.Invalid("tok")
        QuicParse.Action(QuicAction.Offer(QuicOffer(sid, port, fp, tok)))
      }
      else -> QuicParse.Unknown
    }
  }

  /**
   * The canonical wire form: keys in alphabetical order, no whitespace, built from a template (not a serializer: org.json's key order
   * is undefined), so the Mac and the phone write the same bytes for the same action. A session id is lower-cased. Callers pass
   * validated values.
   */
  fun encode(action: QuicAction): String = when (action) {
    is QuicAction.Request -> """{"a":"q.req","kind":"${action.kind.wire}","sid":"${action.sid.lowercase()}"}"""
    is QuicAction.Accept -> """{"a":"q.accept","sid":"${action.sid.lowercase()}"}"""
    is QuicAction.Offer -> {
      val o = action.offer
      """{"a":"q.offer","fp":"${o.fp}","port":${o.port},"sid":"${o.sid.lowercase()}","tok":"${o.tok}"}"""
    }
    is QuicAction.Reject -> """{"a":"q.reject","reason":"${action.reason.wire}","sid":"${action.sid.lowercase()}"}"""
    is QuicAction.End -> """{"a":"q.end","sid":"${action.sid.lowercase()}"}"""
  }

  // ---- field validation (the Swift side applies the same rules) ---------------------------------------------------------------

  /** Canonical 8-4-4-4-12 UUID, either case in, lower case out. */
  private fun sid(o: JSONObject): String? {
    val s = o.opt("sid") as? String ?: return null
    if (s.length != 36) return null
    for ((i, c) in s.withIndex()) {
      if (i == 8 || i == 13 || i == 18 || i == 23) {
        if (c != '-') return null
      } else if (!(c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F')) {
        return null
      }
    }
    return s.lowercase()
  }

  private fun kind(o: JSONObject, allowEcho: Boolean): QuicKind? {
    val k = QuicKind.values().firstOrNull { it.wire == (o.opt("kind") as? String) } ?: return null
    return if (k == QuicKind.ECHO && !allowEcho) null else k
  }

  /** A JSON integer literal 1024..65535. Not a boolean, not a float (`53125.0` and `5.3125e4` are floats), not a string. */
  private fun port(o: JSONObject): Int? {
    val n = when (val v = o.opt("port")) {
      is Int -> v.toLong()
      is Long -> v
      else -> return null
    }
    return if (n in 1024L..65535L) n.toInt() else null
  }

  /** Exactly 64 lower-case hex characters (the SHA-256 of the Mac's certificate). */
  private fun fingerprint(o: JSONObject): String? {
    val s = o.opt("fp") as? String ?: return null
    if (s.length != 64) return null
    return if (s.all { it in '0'..'9' || it in 'a'..'f' }) s else null
  }

  /** 32 random bytes as unpadded base64url: exactly 43 characters, and the canonical encoding (re-encoding gives the same text). */
  private fun token(o: JSONObject): String? {
    val s = o.opt("tok") as? String ?: return null
    if (s.length != 43) return null
    if (!s.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '-' || it == '_' }) return null
    val raw = try {
      java.util.Base64.getUrlDecoder().decode(s)
    } catch (e: IllegalArgumentException) {
      return null
    }
    if (raw.size != 32) return null
    return if (java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(raw) == s) s else null
  }
}

enum class QuicSide { MAC, PHONE }

/**
 * The rules of the handshake for ONE session, as pure logic with an injected clock (milliseconds). Four views: the Mac or the phone, as
 * the side that asked or the side that was asked. The offer is always the Mac's (it is the QUIC server).
 *
 *   Mac asked:    awaitingAccept --accept--> mayOffer --send offer--> offered      (the phone's user must say yes; no accept in time: timedOut)
 *   Phone asked:  Mac: mayOffer (no accept step) --send offer--> offered
 *   Phone asked:  phone: awaitingOffer --offer--> offered
 *   Mac asked:    phone: awaitingUser --send accept--> awaitingOffer --offer--> offered   (no answer in time: timedOut)
 *
 * Anything else is [Verdict.Ignored] with a fixed code and changes nothing. After `closed` everything is ignored. The offer / session
 * wait times of stages 1.6 and 1.8 are not here; only the accept wait (60 s by default, stage 3.2) is.
 */
class QuicHandshake(
  val side: QuicSide,
  val iRequested: Boolean,
  sid: String,
  nowMs: Long,
  acceptTimeoutMs: Long = 60_000,
) {
  sealed class Phase {
    data class AwaitingAccept(val deadlineMs: Long) : Phase() // Mac asked, waits for the phone's accept
    data class AwaitingUser(val deadlineMs: Long) : Phase() // phone was asked, waits for its user
    object AwaitingOffer : Phase() { // phone waits for the Mac's offer
      override fun toString() = "AwaitingOffer"
    }
    object MayOffer : Phase() { // Mac may send the offer
      override fun toString() = "MayOffer"
    }
    data class Offered(val offer: QuicOffer) : Phase()
    data class Closed(val reason: Close) : Phase()
  }

  sealed class Close {
    object Ended : Close() {
      override fun toString() = "Ended"
    }
    data class Rejected(val reason: QuicRejectReason) : Close()
    object TimedOut : Close() {
      override fun toString() = "TimedOut"
    }
  }

  sealed class Verdict {
    data class Applied(val phase: Phase) : Verdict()
    data class Ignored(val code: String) : Verdict()
  }

  val sid: String = sid.lowercase()
  var phase: Phase = when {
    side == QuicSide.MAC && iRequested -> Phase.AwaitingAccept(nowMs + acceptTimeoutMs)
    side == QuicSide.MAC -> Phase.MayOffer
    iRequested -> Phase.AwaitingOffer
    else -> Phase.AwaitingUser(nowMs + acceptTimeoutMs)
  }
    private set

  /** Moves a phase that is waiting for an answer to `Closed(TimedOut)` once its deadline has passed (`now >= deadline`). */
  fun tick(nowMs: Long): Phase {
    when (val p = phase) {
      is Phase.AwaitingAccept -> if (nowMs >= p.deadlineMs) phase = Phase.Closed(Close.TimedOut)
      is Phase.AwaitingUser -> if (nowMs >= p.deadlineMs) phase = Phase.Closed(Close.TimedOut)
      else -> {}
    }
    return phase
  }

  /** An action from the peer. */
  fun receive(action: QuicAction, nowMs: Long): Verdict {
    tick(nowMs)
    if (phase is Phase.Closed) return Verdict.Ignored("closed")
    if (action.sid.lowercase() != sid) return Verdict.Ignored("sid")
    val p = phase
    return when (action) {
      is QuicAction.Request -> Verdict.Ignored("unexpected-request")
      is QuicAction.End -> apply(Phase.Closed(Close.Ended))
      is QuicAction.Reject -> when {
        side == QuicSide.MAC && iRequested && p is Phase.AwaitingAccept -> apply(Phase.Closed(Close.Rejected(action.reason)))
        side == QuicSide.PHONE && iRequested && p is Phase.AwaitingOffer -> apply(Phase.Closed(Close.Rejected(action.reason)))
        else -> Verdict.Ignored("unexpected-reject")
      }
      is QuicAction.Accept ->
        if (side == QuicSide.MAC && iRequested && p is Phase.AwaitingAccept) apply(Phase.MayOffer) else Verdict.Ignored("unexpected-accept")
      is QuicAction.Offer -> when {
        side != QuicSide.PHONE -> Verdict.Ignored("unexpected-offer")
        p is Phase.AwaitingOffer -> apply(Phase.Offered(action.offer))
        p is Phase.AwaitingUser -> Verdict.Ignored("offer-before-accept")
        p is Phase.Offered -> Verdict.Ignored("duplicate-offer")
        else -> Verdict.Ignored("unexpected-offer")
      }
    }
  }

  /** An action this side wants to send; applied only when the rules allow it. */
  fun send(action: QuicAction, nowMs: Long): Verdict {
    tick(nowMs)
    if (phase is Phase.Closed) return Verdict.Ignored("closed")
    if (action.sid.lowercase() != sid) return Verdict.Ignored("sid")
    val p = phase
    return when (action) {
      is QuicAction.Request -> Verdict.Ignored("request-not-allowed")
      is QuicAction.End -> apply(Phase.Closed(Close.Ended))
      is QuicAction.Offer ->
        if (side == QuicSide.MAC && p is Phase.MayOffer) apply(Phase.Offered(action.offer)) else Verdict.Ignored("offer-not-allowed")
      is QuicAction.Reject -> when {
        side == QuicSide.MAC && !iRequested && p is Phase.MayOffer -> apply(Phase.Closed(Close.Rejected(action.reason)))
        side == QuicSide.PHONE && !iRequested && p is Phase.AwaitingUser -> apply(Phase.Closed(Close.Rejected(action.reason)))
        else -> Verdict.Ignored("reject-not-allowed")
      }
      is QuicAction.Accept ->
        if (side == QuicSide.PHONE && !iRequested && p is Phase.AwaitingUser) apply(Phase.AwaitingOffer) else Verdict.Ignored("accept-not-allowed")
    }
  }

  private fun apply(next: Phase): Verdict {
    phase = next
    return Verdict.Applied(next)
  }
}

// ---- stat.caps (stage 1.4) --------------------------------------------------------------------------------------------------

/**
 * `stat.caps`: how each side learns whether the other speaks the QUIC session protocol (`q1`). The field is optional and the `stat` frame
 * is additive, so a receiver only updates what is present: a stat WITHOUT `caps` (battery, proximity, media) never clobbers it. The
 * Swift twin is `QuicCaps` in `Quic/QuicControl.swift`; both run `protocol-vectors/quic-control.json` (section `stat`).
 */
object QuicCaps {
  /** The QUIC session protocol, version 1. */
  const val Q1 = "q1"

  /** The names this build understands; any other name in a peer's `caps` is ignored. */
  val KNOWN: Set<String> = setOf(Q1)

  sealed class Update {
    /** No usable `caps` in the stat: the receiver keeps what it has. */
    object Absent : Update() {
      override fun toString() = "Absent"
    }

    /** The peer's capabilities (the known ones), possibly empty: it says it supports none. */
    data class Known(val caps: Set<String>) : Update()
  }

  /**
   * What this side writes into its own `stat`: `["q1"]` once it can actually serve the protocol, nothing before. (Advertising a
   * capability that does not exist yet would make the peer offer sessions this side cannot answer.)
   */
  fun advertised(supportsQuic: Boolean): List<String> = if (supportsQuic) listOf(Q1) else emptyList()

  /**
   * Reads `caps` from a decoded stat object. Anything that is not an array (missing, a string, a number, an object, null) is [Update.Absent],
   * so a malformed field cannot wipe what is known. In an array, unknown names and non-string items are ignored.
   */
  fun parse(stat: JSONObject): Update {
    val raw = stat.opt("caps") as? org.json.JSONArray ?: return Update.Absent
    val names = (0 until raw.length()).mapNotNull { raw.opt(it) as? String }.filter { it in KNOWN }.toSet()
    return Update.Known(names)
  }

  /** QUIC is usable only on the LAN-direct link and only when the peer is known to speak `q1`. The one gate the UI will use (stage 1.8). */
  fun available(onLan: Boolean, caps: Set<String>): Boolean = onLan && Q1 in caps
}

/**
 * What a side knows about the peer's capabilities. Empty until a `stat` carrying `caps` arrives, so an old peer (no `caps` ever) is "not
 * supported", and emptied again when the peer goes offline so a stale answer cannot outlive the session it came from.
 */
class PeerCaps(caps: Set<String> = emptySet()) {
  @Volatile
  var caps: Set<String> = caps
    private set

  fun applyStat(stat: JSONObject) {
    val update = QuicCaps.parse(stat)
    if (update is QuicCaps.Update.Known) caps = update.caps
  }

  /** The peer is gone (the active link says so). */
  fun peerWentOffline() {
    caps = emptySet()
  }

  fun quicAvailable(onLan: Boolean): Boolean = QuicCaps.available(onLan, caps)
}
