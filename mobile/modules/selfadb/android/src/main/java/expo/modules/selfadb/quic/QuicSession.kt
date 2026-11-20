package expo.modules.selfadb.quic

// The phone's rules for ONE QUIC session (plan stage 1.7), as pure logic: no sockets, no JNI, no clock of its own (time comes in as
// milliseconds). The Rust client does the connecting and the token; this decides what a q.offer is worth, when to give up and what the
// Mac has to be told. The host (`QuicManager`) feeds events in and carries the returned effects out.
//
//   the phone asked:   idle --request--> awaitingOffer --q.offer + a LAN address--> connecting --client: Connected--> connected --> ended
//
// The control-phase rules (who may send what) are `QuicHandshake`'s (stage 1.3, phone side); this adds the address check, the clocks
// before the session opens, and the mapping of what the Rust client reports. The Swift twin of the Mac's side is `QuicSession.swift`.

class QuicSession(val config: Config = Config()) {
  data class Config(
    /** Kinds this phone asks for. Stage 1.7: only the debug `echo`. */
    val supportedKinds: Set<QuicKind> = emptySet(),
    /** How long the phone waits for the Mac's offer after asking. */
    val offerWaitMs: Long = 10_000,
    /** Backstop for a client that reports neither Connected nor Failed (its own timeouts are 5 s + 6 s). */
    val connectWatchdogMs: Long = 12_000,
  )

  sealed class State {
    object Idle : State() {
      override fun toString() = "Idle"
    }
    object AwaitingOffer : State() {
      override fun toString() = "AwaitingOffer"
    }
    object Connecting : State() {
      override fun toString() = "Connecting"
    }
    object Connected : State() {
      override fun toString() = "Connected"
    }
    data class Ended(val end: End) : State()
  }

  sealed class End {
    object PeerEnded : End() {
      override fun toString() = "PeerEnded"
    }
    data class PeerRejected(val reason: QuicRejectReason) : End()
    object LocalEnded : End() {
      override fun toString() = "LocalEnded"
    }
    object OfferTimeout : End() {
      override fun toString() = "OfferTimeout"
    }
    object ConnectTimeout : End() {
      override fun toString() = "ConnectTimeout"
    }
    object NoAddress : End() {
      override fun toString() = "NoAddress"
    }
    data class Failed(val error: QuicError) : End()
    object LinkLost : End() {
      override fun toString() = "LinkLost"
    }
  }

  /** What the host must do. */
  sealed class Effect {
    /** Send this `q.*` action to the Mac as a `cmd` (one link, the one that is up). */
    data class SendAction(val action: QuicAction) : Effect()

    /** Start the Rust client toward the Mac's LAN address. [host] lives in memory only: never logged, never stored. */
    data class Connect(val host: String, val port: Int, val fp: String, val tok: String) : Effect()

    /** Close and forget the client handle (idempotent; it also waits for the CONNECTION_CLOSE to leave). */
    data class Close(val code: Int) : Effect()
  }

  var state: State = State.Idle
    private set

  private var sid = ""
  private var handshake: QuicHandshake? = null
  private var offerDeadlineMs = 0L
  private var connectDeadlineMs = 0L

  private val active: Boolean
    get() = state == State.AwaitingOffer || state == State.Connecting || state == State.Connected

  // ---- asking ----

  /** Why a request of ours cannot be made right now, or null. */
  fun localRequestRefusal(kind: QuicKind, onLan: Boolean): QuicRejectReason? = when {
    active -> QuicRejectReason.BUSY
    !onLan -> QuicRejectReason.RELAY
    kind !in config.supportedKinds -> QuicRejectReason.UNSUPPORTED
    else -> null
  }

  /** The phone asks the Mac for a session. Nothing happens when it cannot be made ([localRequestRefusal]). */
  fun request(kind: QuicKind, sid: String, onLan: Boolean, nowMs: Long): List<Effect> {
    if (localRequestRefusal(kind, onLan) != null) return emptyList()
    this.sid = sid.lowercase()
    handshake = QuicHandshake(QuicSide.PHONE, iRequested = true, sid = this.sid, nowMs = nowMs)
    offerDeadlineMs = nowMs + config.offerWaitMs
    state = State.AwaitingOffer
    return listOf(Effect.SendAction(QuicAction.Request(this.sid, kind)))
  }

  // ---- control actions from the Mac ----

  /**
   * An action from the Mac. [hostAddress]: the Mac's LAN address while the LAN link is up (null otherwise); [onLan]: the active link is the
   * LAN. A session needs both: without them the offer is of no use.
   */
  fun receive(action: QuicAction, hostAddress: String?, onLan: Boolean, nowMs: Long): List<Effect> {
    val out = tick(nowMs).toMutableList()
    if (action is QuicAction.Request) {
      // The Mac asking us is a later stage (the file, screen and camera kinds). Until then it must not wait for an answer that never comes.
      val reason = if (active) QuicRejectReason.BUSY else QuicRejectReason.UNSUPPORTED
      return out + Effect.SendAction(QuicAction.Reject(action.sid, reason))
    }
    val hs = handshake
    if (!active || hs == null) return out
    val verdict = hs.receive(action, nowMs)
    if (verdict !is QuicHandshake.Verdict.Applied) return out
    return when (val phase = verdict.phase) {
      is QuicHandshake.Phase.Offered -> {
        val offer = phase.offer
        if (hostAddress == null || !onLan) {
          out + finish(End.NoAddress, tellMac = true, close = false)
        } else {
          state = State.Connecting
          connectDeadlineMs = nowMs + config.connectWatchdogMs
          out + Effect.Connect(hostAddress, offer.port, offer.fp, offer.tok)
        }
      }
      is QuicHandshake.Phase.Closed -> when (val reason = phase.reason) {
        is QuicHandshake.Close.Ended -> out + finish(End.PeerEnded, tellMac = false, close = state != State.AwaitingOffer)
        is QuicHandshake.Close.Rejected -> out + finish(End.PeerRejected(reason.reason), tellMac = false, close = false)
        is QuicHandshake.Close.TimedOut -> out + finish(End.OfferTimeout, tellMac = true, close = false)
      }
      else -> out
    }
  }

  // ---- what the Rust client reports ----

  /** The client got `OK`: the session is open. */
  fun connected(nowMs: Long): List<Effect> {
    if (state != State.Connecting) return emptyList()
    state = State.Connected
    return emptyList()
  }

  /** The client could not open the session (any [QuicError]); the Mac is told and the handle released. */
  fun failed(error: QuicError, nowMs: Long): List<Effect> {
    if (state != State.Connecting) return emptyList()
    return finish(End.Failed(error), tellMac = true, close = true)
  }

  /** The Mac said `END` on the session stream. */
  fun peerEnded(nowMs: Long): List<Effect> {
    if (state != State.Connected && state != State.Connecting) return emptyList()
    return finish(End.PeerEnded, tellMac = false, close = true)
  }

  /** The client is done: [code] 0 = clean (by us or the peer), otherwise a [QuicError] number. Only a lost connection ends a session here. */
  fun closed(code: Int, nowMs: Long): List<Effect> {
    if (code != QuicError.LinkLost.code) return emptyList()
    if (state != State.Connected && state != State.Connecting) return emptyList()
    return finish(End.LinkLost, tellMac = false, close = true)
  }

  /** The phone ends the session (the user, Unpair, the link going away). The Mac is told first. */
  fun end(nowMs: Long): List<Effect> {
    if (!active) return emptyList()
    return finish(End.LocalEnded, tellMac = true, close = state == State.Connecting || state == State.Connected)
  }

  // ---- the clock ----

  /** When the host should call [tick] next (null: nothing waits on a clock). */
  val nextDeadlineMs: Long?
    get() = when (state) {
      State.AwaitingOffer -> offerDeadlineMs
      State.Connecting -> connectDeadlineMs
      else -> null
    }

  /** Applies every limit that has passed (`now >= deadline`); each one is reported once. */
  fun tick(nowMs: Long): List<Effect> = when {
    state == State.AwaitingOffer && nowMs >= offerDeadlineMs -> finish(End.OfferTimeout, tellMac = true, close = false)
    state == State.Connecting && nowMs >= connectDeadlineMs -> finish(End.ConnectTimeout, tellMac = true, close = true)
    else -> emptyList()
  }

  private fun finish(end: End, tellMac: Boolean, close: Boolean): List<Effect> {
    val out = mutableListOf<Effect>()
    if (tellMac) out += Effect.SendAction(QuicAction.End(sid))
    if (close) out += Effect.Close(0)
    state = State.Ended(end)
    return out
  }
}
