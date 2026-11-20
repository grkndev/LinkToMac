package expo.modules.selfadb.quic

import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** What the manager needs from the Rust client: [QuicCore] in the app, a fake in the JVM tests. */
interface QuicTransport {
  fun connect(host: String, port: Int, fpHex: String, tokB64: String, events: QuicEvents): ConnectResult
  fun sessionWrite(handle: Long, line: String): Boolean
  fun sendDatagram(handle: Long, bytes: ByteArray): Boolean
  fun openUni(handle: Long, channel: QuicChannel): Long?
  fun streamWrite(handle: Long, id: Long, bytes: ByteArray): Boolean
  fun streamFinish(handle: Long, id: Long): Boolean
  fun close(handle: Long, code: Int)
}

object QuicCoreTransport : QuicTransport {
  override fun connect(host: String, port: Int, fpHex: String, tokB64: String, events: QuicEvents) = QuicCore.connect(host, port, fpHex, tokB64, events)
  override fun sessionWrite(handle: Long, line: String) = QuicCore.sessionWrite(handle, line)
  override fun sendDatagram(handle: Long, bytes: ByteArray) = QuicCore.sendDatagram(handle, bytes)
  override fun openUni(handle: Long, channel: QuicChannel) = QuicCore.openUni(handle, channel)
  override fun streamWrite(handle: Long, id: Long, bytes: ByteArray) = QuicCore.streamWrite(handle, id, bytes)
  override fun streamFinish(handle: Long, id: Long) = QuicCore.streamFinish(handle, id)
  override fun close(handle: Long, code: Int) = QuicCore.close(handle, code)
}

/**
 * The host of the phone's QUIC session (plan stage 1.7): feeds the Mac's actions and the Rust client's events into the pure rules
 * ([QuicSession]) and carries the returned effects out (send a `cmd`, start or close the client). Everything runs on ONE thread
 * ([post]), which is also the thread the Rust client's events are handed to, so the session never sees two things at once.
 *
 * **Logging:** only fixed words and error names. The Mac's address, the port, the fingerprint, the token and the session id are in
 * memory for as long as they are needed and never in a log line (`QuicManagerTest` checks that).
 */
class QuicManager(
  private val transport: QuicTransport,
  private val sendAction: (QuicAction) -> Unit,
  /** The Mac's address while the LAN link is up, else null. In memory only. */
  private val lanHost: () -> String?,
  private val onLan: () -> Boolean,
  supportedKinds: Set<QuicKind>,
  private val log: (String) -> Unit,
  private val post: (Runnable) -> Unit,
  private val ticker: Ticker,
  private val now: () -> Long,
) : QuicEvents {
  interface Ticker {
    fun schedule(delayMs: Long, task: Runnable)
    fun cancel()
  }

  private val session = QuicSession(QuicSession.Config(supportedKinds = supportedKinds))

  @Volatile var state: QuicSession.State = QuicSession.State.Idle
    private set

  /** Sees every client event after the manager did (the debug self-test listens here). Called on the manager's thread. */
  @Volatile var tap: QuicEvents? = null

  /** Debug only: changes what is handed to the client (the device self-test flips one character of the fingerprint or the token). */
  @Volatile var tamper: ((QuicSession.Effect.Connect) -> QuicSession.Effect.Connect)? = null

  @Volatile private var handle = 0L

  private val tickTask = Runnable { post { run(session.tick(now())) } }

  // ---- from the app ----

  /** A parsed `q.*` action from the Mac. */
  fun handle(action: QuicAction) = post { run(session.receive(action, lanHost(), onLan(), now())) }

  /** Debug: ask the Mac for an `echo` session. */
  fun requestEcho() = post { run(session.request(QuicKind.ECHO, UUID.randomUUID().toString(), onLan(), now())) }

  /** The phone ends the session (the user, Unpair, the link going away). */
  fun end() = post { run(session.end(now())) }

  fun shutdown() {
    end()
    ticker.cancel()
  }

  // ---- on the open session (any thread; they only queue work) ----

  fun sendSessionLine(line: String): Boolean = handle != 0L && transport.sessionWrite(handle, line)

  fun sendDatagram(bytes: ByteArray): Boolean = handle != 0L && transport.sendDatagram(handle, bytes)

  fun openUni(channel: QuicChannel): Long? = if (handle != 0L) transport.openUni(handle, channel) else null

  fun streamWrite(id: Long, bytes: ByteArray): Boolean = handle != 0L && transport.streamWrite(handle, id, bytes)

  fun streamFinish(id: Long): Boolean = handle != 0L && transport.streamFinish(handle, id)

  // ---- carrying the effects out ----

  private fun run(effects: List<QuicSession.Effect>) {
    for (effect in effects) {
      when (effect) {
        is QuicSession.Effect.SendAction -> {
          sendAction(effect.action)
          log("quic: ${nameOf(effect.action)} sent")
        }
        is QuicSession.Effect.Connect -> connect(tamper?.invoke(effect) ?: effect)
        is QuicSession.Effect.Close -> {
          val open = handle
          handle = 0L
          if (open != 0L) transport.close(open, effect.code)
          log("quic: session closed")
        }
      }
    }
    state = session.state
    ticker.cancel()
    session.nextDeadlineMs?.let { ticker.schedule(maxOf(0L, it - now()), tickTask) }
  }

  private fun connect(c: QuicSession.Effect.Connect) {
    when (val result = transport.connect(c.host, c.port, c.fp, c.tok, this)) {
      is ConnectResult.Started -> {
        handle = result.handle
        log("quic: connecting")
      }
      is ConnectResult.Refused -> {
        log("quic: connect refused (${result.reason})")
        run(session.failed(QuicError.Internal, now()))
      }
    }
  }

  /** One fixed sentence per error code: a log line may name a state, never be built from data. */
  private fun failedLine(error: QuicError) = when (error) {
    QuicError.FpMismatch -> "quic: failed FpMismatch"
    QuicError.TokenRejected -> "quic: failed TokenRejected"
    QuicError.Timeout -> "quic: failed Timeout"
    QuicError.LinkLost -> "quic: failed LinkLost"
    QuicError.Protocol -> "quic: failed Protocol"
    QuicError.Internal -> "quic: failed Internal"
  }

  private fun nameOf(action: QuicAction) = when (action) {
    is QuicAction.Request -> "request"
    is QuicAction.Accept -> "accept"
    is QuicAction.Offer -> "offer"
    is QuicAction.Reject -> "reject"
    is QuicAction.End -> "end"
  }

  // ---- QuicEvents: the Rust client's thread hands them over here ----

  override fun onConnected() = post {
    log("quic: connected")
    run(session.connected(now()))
    tap?.onConnected()
  }

  override fun onFailed(code: Int) = post {
    val error = QuicError.fromCode(code) ?: QuicError.Internal
    log(failedLine(error))
    run(session.failed(error, now()))
    tap?.onFailed(code)
  }

  override fun onPeerEnded() = post {
    log("quic: peer ended")
    run(session.peerEnded(now()))
    tap?.onPeerEnded()
  }

  override fun onClosed(code: Int) = post {
    if (code == QuicError.LinkLost.code) log("quic: link lost")
    run(session.closed(code, now()))
    tap?.onClosed(code)
  }

  override fun onSessionLine(line: String) = post { tap?.onSessionLine(line) }

  override fun onDatagram(bytes: ByteArray) = post { tap?.onDatagram(bytes) }

  override fun onUniStream(id: Long, channel: Int) = post { tap?.onUniStream(id, channel) }

  override fun onStreamData(id: Long, bytes: ByteArray, fin: Boolean) = post { tap?.onStreamData(id, bytes, fin) }

  override fun onStats(rttMs: Long, cwnd: Long, lostPackets: Long, congestionEvents: Long) = post { tap?.onStats(rttMs, cwnd, lostPackets, congestionEvents) }

  companion object {
    /** The manager as the app runs it: one worker thread for everything, a scheduler for the clock. */
    fun create(
      sendAction: (QuicAction) -> Unit,
      lanHost: () -> String?,
      onLan: () -> Boolean,
      supportedKinds: Set<QuicKind>,
      log: (String) -> Unit,
    ): QuicManager {
      val worker = Executors.newSingleThreadExecutor { Thread(it, "quic-manager").apply { isDaemon = true } }
      val scheduler = Executors.newSingleThreadScheduledExecutor { Thread(it, "quic-timer").apply { isDaemon = true } }
      val ticker = object : Ticker {
        private var future: ScheduledFuture<*>? = null
        override fun schedule(delayMs: Long, task: Runnable) {
          future = scheduler.schedule(task, delayMs, TimeUnit.MILLISECONDS)
        }
        override fun cancel() {
          future?.cancel(false)
          future = null
        }
      }
      return QuicManager(
        transport = QuicCoreTransport,
        sendAction = sendAction,
        lanHost = lanHost,
        onLan = onLan,
        supportedKinds = supportedKinds,
        log = log,
        post = { worker.execute(it) },
        ticker = ticker,
        now = { System.nanoTime() / 1_000_000 },
      )
    }
  }
}
