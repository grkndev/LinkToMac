package expo.modules.selfadb.quic

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The on-device end-to-end check of stage 1.7, started from a debuggable build only (`adb`, see `mobile/scripts/quic-device-test.sh`):
 * ask the Mac for an `echo` session, connect, and run the echo (a session line, a datagram, a uni stream the Mac counts). With a tamper
 * the connection must be REFUSED the right way instead (`FpMismatch`, `TokenRejected`). The verdict goes to the log as one line of fixed
 * words (`quic-selftest: PASS echo`, `PASS FpMismatch`, `FAIL <reason>`); nothing about the Mac, the session or the data.
 */
class QuicSelfTest(private val manager: QuicManager, private val log: (String) -> Unit) : QuicEvents {
  /**
   * `None`: the echo check. `Fp`/`Tok`: one character flipped, the connection must be refused the right way. `Hold`: connect and stay (60 s)
   * until the session ends by itself, for the link-loss test. `Force`: ask even though the gate says no (off the LAN, or the Mac never
   * announced `q1`); passes when the Mac refuses (`Refused:<reason>`) or says nothing (`NoAnswer`, which is what an older Mac does).
   */
  enum class Mode { None, Fp, Tok, Hold, Force }

  private val timer = Executors.newSingleThreadScheduledExecutor { Thread(it, "quic-selftest").apply { isDaemon = true } }
  private var mode = Mode.None
  private var step = 0
  @Volatile private var done = false

  fun start(mode: Mode) {
    this.mode = mode
    step = 0
    done = false
    manager.tamper = { c ->
      when (mode) {
        Mode.Fp -> c.copy(fp = flip(c.fp))
        Mode.Tok -> c.copy(tok = flip(c.tok, at = 5))
        else -> c
      }
    }
    manager.tap = this
    if (mode == Mode.Hold || mode == Mode.Force) manager.onEnded = ::onEnded
    val limit = if (mode == Mode.Hold) 60L else 20L
    timer.schedule({ if (!done) fail("no verdict in time") }, limit, TimeUnit.SECONDS)
    manager.requestEcho(force = mode == Mode.Force)
  }

  private fun onEnded(end: QuicSession.End) {
    when (mode) {
      Mode.Hold -> pass("held until it ended")
      Mode.Force -> when (end) {
        QuicSession.End.OfferTimeout -> pass("NoAnswer")
        is QuicSession.End.PeerRejected -> pass("Refused:${end.reason.wire}")
        else -> fail("ended unexpectedly")
      }
      else -> Unit
    }
  }

  /**
   * Joins a session the MAC asked for (the Mac's debug "QUIC test session"): nothing to request and no tamper; once connected, the same echo
   * check runs and, when it passes, the phone ends the session, which is what the Mac's test waits for.
   */
  fun attach() {
    mode = Mode.None
    step = 0
    done = false
    manager.tap = this
    timer.schedule({ if (!done) fail("no verdict in time") }, 20, TimeUnit.SECONDS)
  }

  private fun flip(text: String, at: Int = 0): String {
    val replacement = if (text[at] == 'a') 'b' else 'a'
    return text.substring(0, at) + replacement + text.substring(at + 1)
  }

  private fun pass(what: String) {
    if (done) return
    done = true
    log("quic-selftest: PASS $what")
    manager.tamper = null
    manager.tap = null
    manager.onEnded = null
    manager.end()
  }

  private fun fail(why: String) {
    if (done) return
    done = true
    log("quic-selftest: FAIL $why")
    manager.tamper = null
    manager.tap = null
    manager.onEnded = null
    manager.end()
  }

  override fun onConnected() {
    if (mode == Mode.Hold) return log("quic-selftest: HOLDING")
    if (mode != Mode.None) return fail("connected although it should not have")
    step = 1
    manager.sendSessionLine("ping")
  }

  override fun onFailed(code: Int) {
    val error = QuicError.fromCode(code)
    when {
      mode == Mode.Fp && error == QuicError.FpMismatch -> pass("FpMismatch")
      mode == Mode.Tok && error == QuicError.TokenRejected -> pass("TokenRejected")
      else -> fail("failed ${error?.name ?: "Unknown"}")
    }
  }

  override fun onSessionLine(line: String) {
    when {
      step == 1 && line == "ping" -> {
        step = 2
        manager.sendDatagram(ByteArray(64) { it.toByte() })
      }
      step == 3 && line == "COUNT 1" -> pass("echo")
      step == 3 && line.startsWith("COUNT ") -> timer.schedule({ if (!done) manager.sendSessionLine("COUNT") }, 200, TimeUnit.MILLISECONDS)
    }
  }

  override fun onDatagram(bytes: ByteArray) {
    if (step != 2) return
    if (!bytes.contentEquals(ByteArray(64) { it.toByte() })) return fail("datagram came back different")
    val id = manager.openUni(QuicChannel.SCREEN) ?: return fail("could not open a uni stream")
    manager.streamWrite(id, byteArrayOf(1, 2, 3))
    manager.streamFinish(id)
    step = 3
    manager.sendSessionLine("COUNT")
  }

  override fun onPeerEnded() = Unit

  override fun onUniStream(id: Long, channel: Int) = Unit

  override fun onStreamData(id: Long, bytes: ByteArray, fin: Boolean) = Unit

  override fun onStats(rttMs: Long, cwnd: Long, lostPackets: Long, congestionEvents: Long) = Unit

  override fun onClosed(code: Int) {
    if (!done && code != 0) fail("closed ${QuicError.fromCode(code)?.name ?: "Unknown"}")
  }
}
