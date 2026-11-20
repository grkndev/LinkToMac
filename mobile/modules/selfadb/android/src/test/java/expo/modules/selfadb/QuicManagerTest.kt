package expo.modules.selfadb

import expo.modules.selfadb.quic.ConnectRefusal
import expo.modules.selfadb.quic.ConnectResult
import expo.modules.selfadb.quic.QuicAction
import expo.modules.selfadb.quic.QuicChannel
import expo.modules.selfadb.quic.QuicError
import expo.modules.selfadb.quic.QuicEvents
import expo.modules.selfadb.quic.QuicKind
import expo.modules.selfadb.quic.QuicManager
import expo.modules.selfadb.quic.QuicOffer
import expo.modules.selfadb.quic.QuicRejectReason
import expo.modules.selfadb.quic.QuicSession
import expo.modules.selfadb.quic.QuicTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The host of the phone's QUIC session (stage 1.7): it carries out what the pure rules ([QuicSession]) decide, over a fake transport,
 * a manual clock and a manual timer, so no JNI, no thread and no wall clock is involved. The most important check is the last group:
 * nothing it logs may contain an address, a port, a fingerprint, a token or a session id.
 */
class QuicManagerTest {
  private val host = "192.168.1.10"
  private val fp = "ab".repeat(32)
  private val tok = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
  private val port = 53125

  private class FakeTransport : QuicTransport {
    val calls = mutableListOf<String>()
    var connectArgs: List<Any>? = null
    var result: ConnectResult = ConnectResult.Started(7)
    var events: QuicEvents? = null
    override fun connect(host: String, port: Int, fpHex: String, tokB64: String, events: QuicEvents): ConnectResult {
      calls += "connect"
      connectArgs = listOf(host, port, fpHex, tokB64)
      this.events = events
      return result
    }
    override fun sessionWrite(handle: Long, line: String): Boolean { calls += "write:$handle:$line"; return true }
    override fun sendDatagram(handle: Long, bytes: ByteArray): Boolean { calls += "datagram:$handle:${bytes.size}"; return true }
    override fun openUni(handle: Long, channel: QuicChannel): Long? { calls += "openUni:$handle:${channel.typeId}"; return 11L }
    override fun streamWrite(handle: Long, id: Long, bytes: ByteArray): Boolean { calls += "streamWrite:$handle:$id"; return true }
    override fun streamFinish(handle: Long, id: Long): Boolean { calls += "streamFinish:$handle:$id"; return true }
    override fun close(handle: Long, code: Int) { calls += "close:$handle:$code" }
  }

  private class ManualTicker : QuicManager.Ticker {
    var scheduledDelay: Long? = null
    var task: Runnable? = null
    override fun schedule(delayMs: Long, task: Runnable) { scheduledDelay = delayMs; this.task = task }
    override fun cancel() { scheduledDelay = null; task = null }
  }

  private class Rig(val transport: FakeTransport = FakeTransport()) {
    var clock = 1_000L
    var lanHost: String? = "192.168.1.10"
    var onLan = true
    val sent = mutableListOf<QuicAction>()
    val logs = mutableListOf<String>()
    val ticker = ManualTicker()
    val manager = QuicManager(
      transport = transport,
      sendAction = { sent += it },
      lanHost = { lanHost },
      onLan = { onLan },
      supportedKinds = setOf(QuicKind.ECHO),
      log = { logs += it },
      post = { it.run() },
      ticker = ticker,
      now = { clock },
    )
  }

  private fun requestedSid(rig: Rig): String = (rig.sent.first() as QuicAction.Request).sid

  private fun offerFor(sid: String, p: Int = port) = QuicAction.Offer(QuicOffer(sid, p, fp, tok))

  private fun connecting(rig: Rig = Rig()): Rig {
    rig.manager.requestEcho()
    rig.manager.handle(offerFor(requestedSid(rig)))
    return rig
  }

  private fun connected(rig: Rig = connecting()): Rig {
    rig.transport.events!!.onConnected()
    return rig
  }

  // ---- the happy path ----

  @Test fun requestingEchoSendsAQuicRequestAndWaits() {
    val rig = Rig()
    rig.manager.requestEcho()
    val request = rig.sent.single() as QuicAction.Request
    assertEquals(QuicKind.ECHO, request.kind)
    assertEquals(QuicSession.State.AwaitingOffer, rig.manager.state)
  }

  @Test fun anOfferMakesTheClientConnectToTheLanAddressWithTheOfferedValues() {
    val rig = connecting()
    assertEquals(listOf<Any>(host, port, fp, tok), rig.transport.connectArgs)
    assertEquals(QuicSession.State.Connecting, rig.manager.state)
  }

  @Test fun theClientReportingConnectedOpensTheSession() {
    val rig = connected()
    assertEquals(QuicSession.State.Connected, rig.manager.state)
  }

  @Test fun sessionLinesDatagramsAndStreamsGoToTheCurrentHandle() {
    val rig = connected()
    assertTrue(rig.manager.sendSessionLine("hello"))
    assertTrue(rig.manager.sendDatagram(byteArrayOf(1, 2, 3)))
    val id = rig.manager.openUni(QuicChannel.SCREEN)
    assertEquals(11L, id)
    assertTrue(rig.manager.streamWrite(11, byteArrayOf(1)))
    assertTrue(rig.manager.streamFinish(11))
    assertEquals(listOf("connect", "write:7:hello", "datagram:7:3", "openUni:7:2", "streamWrite:7:11", "streamFinish:7:11"), rig.transport.calls)
  }

  @Test fun withNoSessionThereIsNothingToSendOn() {
    val rig = Rig()
    assertFalse(rig.manager.sendSessionLine("x"))
    assertFalse(rig.manager.sendDatagram(byteArrayOf(1)))
    assertEquals(null, rig.manager.openUni(QuicChannel.FILE))
    assertTrue(rig.transport.calls.isEmpty())
  }

  // ---- the refusals ----

  @Test fun withoutALanAddressNoClientIsStartedAndTheMacIsTold() {
    val rig = Rig().also { it.lanHost = null }
    rig.manager.requestEcho()
    rig.manager.handle(offerFor(requestedSid(rig)))
    assertFalse("connect" in rig.transport.calls)
    assertEquals(QuicAction.End(requestedSid(rig)), rig.sent.last())
    assertEquals(QuicSession.State.Ended(QuicSession.End.NoAddress), rig.manager.state)
  }

  @Test fun aTransportThatCannotStartEndsTheSessionAsInternal() {
    val rig = Rig(FakeTransport().also { it.result = ConnectResult.Refused(ConnectRefusal.Unavailable) })
    rig.manager.requestEcho()
    rig.manager.handle(offerFor(requestedSid(rig)))
    assertEquals(QuicSession.State.Ended(QuicSession.End.Failed(QuicError.Internal)), rig.manager.state)
    assertEquals(QuicAction.End(requestedSid(rig)), rig.sent.last())
  }

  @Test fun theMacRefusingEndsTheRequest() {
    val rig = Rig()
    rig.manager.requestEcho()
    rig.manager.handle(QuicAction.Reject(requestedSid(rig), QuicRejectReason.UNSUPPORTED))
    assertEquals(QuicSession.State.Ended(QuicSession.End.PeerRejected(QuicRejectReason.UNSUPPORTED)), rig.manager.state)
  }

  @Test fun aRequestFromTheMacIsAnsweredUnsupported() {
    val rig = Rig()
    val other = "223e4567-e89b-12d3-a456-426614174000"
    rig.manager.handle(QuicAction.Request(other, QuicKind.FILE))
    assertEquals(listOf<QuicAction>(QuicAction.Reject(other, QuicRejectReason.UNSUPPORTED)), rig.sent)
  }

  // ---- what the client reports ----

  @Test fun everyFailureTellsTheMacAndReleasesTheHandle() {
    for (error in QuicError.entries) {
      val rig = connecting()
      rig.transport.events!!.onFailed(error.code)
      assertEquals("$error", QuicSession.State.Ended(QuicSession.End.Failed(error)), rig.manager.state)
      assertEquals("$error", QuicAction.End(requestedSid(rig)), rig.sent.last())
      assertEquals("$error", "close:7:0", rig.transport.calls.last())
    }
  }

  @Test fun anUnknownFailureCodeIsInternal() {
    val rig = connecting()
    rig.transport.events!!.onFailed(99)
    assertEquals(QuicSession.State.Ended(QuicSession.End.Failed(QuicError.Internal)), rig.manager.state)
  }

  @Test fun theMacEndingTheSessionReleasesTheHandleWithoutAnotherEnd() {
    val rig = connected()
    val before = rig.sent.size
    rig.transport.events!!.onPeerEnded()
    assertEquals(QuicSession.State.Ended(QuicSession.End.PeerEnded), rig.manager.state)
    assertEquals(before, rig.sent.size)
    assertEquals("close:7:0", rig.transport.calls.last())
  }

  @Test fun aLostConnectionEndsTheSession() {
    val rig = connected()
    rig.transport.events!!.onClosed(QuicError.LinkLost.code)
    assertEquals(QuicSession.State.Ended(QuicSession.End.LinkLost), rig.manager.state)
  }

  @Test fun endingLocallyTellsTheMacAndClosesTheClient() {
    val rig = connected()
    rig.manager.end()
    assertEquals(QuicSession.State.Ended(QuicSession.End.LocalEnded), rig.manager.state)
    assertEquals(QuicAction.End(requestedSid(rig)), rig.sent.last())
    assertEquals("close:7:0", rig.transport.calls.last())
  }

  @Test fun nothingCanBeSentOnceTheSessionIsClosed() {
    val rig = connected()
    rig.manager.end()
    assertFalse(rig.manager.sendSessionLine("late"))
    assertFalse(rig.manager.sendDatagram(byteArrayOf(1)))
    assertEquals(null, rig.manager.openUni(QuicChannel.SCREEN))
    assertFalse(rig.transport.calls.any { it.startsWith("write") || it.startsWith("datagram") || it.startsWith("openUni") })
  }

  @Test fun closingTwiceDoesNotTouchAHandleThatIsGone() {
    val rig = connected()
    rig.manager.end()
    val closes = rig.transport.calls.count { it.startsWith("close") }
    rig.manager.end()
    assertEquals(closes, rig.transport.calls.count { it.startsWith("close") })
  }

  // ---- the link goes away (stage 1.8) ----

  @Test fun theLanLinkGoingAwayEndsTheSessionTellsTheMacAndClosesTheClient() {
    val rig = connected()
    rig.manager.linkLost()
    assertEquals(QuicSession.State.Ended(QuicSession.End.LinkChanged), rig.manager.state)
    assertEquals(QuicAction.End(requestedSid(rig)), rig.sent.last())
    assertEquals("close:7:0", rig.transport.calls.last())
    assertFalse(rig.manager.sendSessionLine("late"))
  }

  @Test fun theLinkGoingAwayWhileWaitingForAnOfferEndsTheRequest() {
    val rig = Rig()
    rig.manager.requestEcho()
    rig.manager.linkLost()
    assertEquals(QuicSession.State.Ended(QuicSession.End.LinkChanged), rig.manager.state)
    assertEquals(QuicAction.End(requestedSid(rig)), rig.sent.last())
    assertEquals(null, rig.ticker.scheduledDelay)
  }

  @Test fun theLinkGoingAwayWithNoSessionDoesNothing() {
    val rig = Rig()
    rig.manager.linkLost()
    assertTrue(rig.sent.isEmpty() && rig.transport.calls.isEmpty())
  }

  // ---- the clock ----

  @Test fun theHostAsksTheTimerForTheNextDeadlineAndTicksTheRules() {
    val rig = Rig()
    rig.manager.requestEcho()
    assertEquals(10_000L, rig.ticker.scheduledDelay)
    rig.clock += 10_000
    rig.ticker.task!!.run()
    assertEquals(QuicSession.State.Ended(QuicSession.End.OfferTimeout), rig.manager.state)
    assertEquals(QuicAction.End(requestedSid(rig)), rig.sent.last())
    assertEquals(null, rig.ticker.scheduledDelay)
  }

  @Test fun anOpenSessionNeedsNoTimer() {
    val rig = connected()
    assertEquals(null, rig.ticker.scheduledDelay)
  }

  // ---- tapping the events (the debug self-test uses it) ----

  @Test fun everyClientEventIsForwardedToTheTap() {
    val rig = connected()
    val seen = mutableListOf<String>()
    rig.manager.tap = object : QuicEvents {
      override fun onConnected() { seen += "connected" }
      override fun onFailed(code: Int) { seen += "failed" }
      override fun onSessionLine(line: String) { seen += "line:$line" }
      override fun onPeerEnded() { seen += "peerEnded" }
      override fun onDatagram(bytes: ByteArray) { seen += "datagram:${bytes.size}" }
      override fun onUniStream(id: Long, channel: Int) { seen += "uni:$id:$channel" }
      override fun onStreamData(id: Long, bytes: ByteArray, fin: Boolean) { seen += "data:$id:${bytes.size}:$fin" }
      override fun onStats(rttMs: Long, cwnd: Long, lostPackets: Long, congestionEvents: Long) { seen += "stats:$rttMs" }
      override fun onClosed(code: Int) { seen += "closed:$code" }
    }
    val e = rig.transport.events!!
    e.onSessionLine("hi"); e.onDatagram(byteArrayOf(1, 2)); e.onUniStream(5, 2); e.onStreamData(5, byteArrayOf(1), true); e.onStats(3, 4, 5, 6)
    assertEquals(listOf("line:hi", "datagram:2", "uni:5:2", "data:5:1:true", "stats:3"), seen)
  }

  @Test fun theConnectArgumentsCanBeTamperedWithForTheDeviceSelfTest() {
    val rig = Rig()
    rig.manager.tamper = { it.copy(fp = "00".repeat(32)) }
    rig.manager.requestEcho()
    rig.manager.handle(offerFor(requestedSid(rig)))
    assertEquals("00".repeat(32), rig.transport.connectArgs!![2])
  }

  // ---- privacy: the one thing a log must never do ----

  @Test fun nothingIsLoggedThatNamesTheAddressThePortTheFingerprintTheTokenOrTheSession() {
    val rig = Rig()
    rig.manager.requestEcho()
    val sid = requestedSid(rig)
    rig.manager.handle(offerFor(sid))
    rig.transport.events!!.onConnected()
    rig.transport.events!!.onSessionLine("something the Mac said")
    rig.transport.events!!.onFailed(QuicError.TokenRejected.code)
    rig.manager.requestEcho()
    rig.manager.end()
    assertTrue(rig.logs.isNotEmpty())
    val everything = rig.logs.joinToString("\n")
    for (secret in listOf(host, port.toString(), fp, tok, sid, sid.take(8), "something the Mac said")) {
      assertFalse("a log line contains $secret", everything.contains(secret))
    }
    assertNotNull(rig.logs.firstOrNull { it.contains("TokenRejected") })
  }
}
