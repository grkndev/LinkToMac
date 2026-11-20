package expo.modules.selfadb

import expo.modules.selfadb.quic.QuicAction
import expo.modules.selfadb.quic.QuicError
import expo.modules.selfadb.quic.QuicKind
import expo.modules.selfadb.quic.QuicOffer
import expo.modules.selfadb.quic.QuicRejectReason
import expo.modules.selfadb.quic.QuicSession
import expo.modules.selfadb.quic.QuicSession.Effect
import expo.modules.selfadb.quic.QuicSession.End
import expo.modules.selfadb.quic.QuicSession.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone's rules for ONE QUIC session (plan stage 1.7) as pure logic with an injected clock. The Rust client does the connecting and
 * the token; this decides what a q.offer is worth, when to give up and what to tell the Mac. Nothing here touches the network or JNI.
 */
class QuicSessionStateTest {
  private val sid = "123e4567-e89b-12d3-a456-426614174000"
  private val otherSid = "223e4567-e89b-12d3-a456-426614174000"
  private val fp = "ab".repeat(32)
  private val tok = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
  private val host = "192.168.1.10"

  private fun session(kinds: Set<QuicKind> = setOf(QuicKind.ECHO), config: QuicSession.Config = QuicSession.Config()) =
    QuicSession(config.copy(supportedKinds = kinds))

  private fun offer(port: Int = 53125, forSid: String = sid) = QuicAction.Offer(QuicOffer(forSid, port, fp, tok))

  private fun asked(now: Long = 0): QuicSession = session().also { it.request(QuicKind.ECHO, sid, onLan = true, nowMs = now) }

  private fun connecting(now: Long = 0): QuicSession = asked(now).also { it.receive(offer(), host, true, now) }

  private fun connected(now: Long = 0): QuicSession = connecting(now).also { it.connected(now) }

  // ---- asking ----

  @Test fun askingSendsTheRequestAndWaitsForTheOffer() {
    val s = session()
    assertEquals(State.Idle, s.state)
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.Request(sid, QuicKind.ECHO))), s.request(QuicKind.ECHO, sid, onLan = true, nowMs = 0))
    assertEquals(State.AwaitingOffer, s.state)
  }

  @Test fun aRequestIsNotMadeOverTheRelayOrForAKindWeDoNotServeOrWhileBusy() {
    val s = session()
    assertEquals(QuicRejectReason.RELAY, s.localRequestRefusal(QuicKind.ECHO, onLan = false))
    assertEquals(QuicRejectReason.UNSUPPORTED, s.localRequestRefusal(QuicKind.CAST, onLan = true))
    assertNull(s.localRequestRefusal(QuicKind.ECHO, onLan = true))
    assertEquals(emptyList<Effect>(), s.request(QuicKind.ECHO, sid, onLan = false, nowMs = 0))
    assertEquals(State.Idle, s.state)
    val busy = asked()
    assertEquals(QuicRejectReason.BUSY, busy.localRequestRefusal(QuicKind.ECHO, onLan = true))
    assertEquals(emptyList<Effect>(), busy.request(QuicKind.ECHO, otherSid, onLan = true, nowMs = 1))
  }

  // ---- the offer ----

  @Test fun anOfferForTheSessionWeAskedForMakesTheClientConnect() {
    val s = asked()
    val effects = s.receive(offer(port = 53126), hostAddress = host, onLan = true, nowMs = 100)
    assertEquals(listOf<Effect>(Effect.Connect(host, 53126, fp, tok)), effects)
    assertEquals(State.Connecting, s.state)
  }

  @Test fun withoutALanAddressThereIsNothingToConnectToAndTheMacIsTold() {
    val s = asked()
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid))), s.receive(offer(), hostAddress = null, onLan = true, nowMs = 5))
    assertEquals(State.Ended(End.NoAddress), s.state)
  }

  @Test fun anOfferWhileTheLinkIsNotTheLanIsTreatedAsNoAddress() {
    val s = asked()
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid))), s.receive(offer(), hostAddress = host, onLan = false, nowMs = 5))
    assertEquals(State.Ended(End.NoAddress), s.state)
  }

  @Test fun anOfferForAnotherSessionOrWithNoSessionIsIgnored() {
    val s = asked()
    assertEquals(emptyList<Effect>(), s.receive(offer(forSid = otherSid), host, true, 5))
    assertEquals(State.AwaitingOffer, s.state)
    val idle = session()
    assertEquals(emptyList<Effect>(), idle.receive(offer(), host, true, 5))
    assertEquals(State.Idle, idle.state)
  }

  @Test fun aSecondOfferIsIgnored() {
    val s = connecting()
    assertEquals(emptyList<Effect>(), s.receive(offer(port = 60000), host, true, 5))
    assertEquals(State.Connecting, s.state)
  }

  @Test fun aSessionIdInUpperCaseIsTheSameSession() {
    val s = asked()
    assertEquals(listOf<Effect>(Effect.Connect(host, 53125, fp, tok)), s.receive(offer(forSid = sid.uppercase()), host, true, 5))
  }

  @Test fun theMacRefusingEndsTheRequestWithItsReasonAndSaysNothingBack() {
    val s = asked()
    assertEquals(emptyList<Effect>(), s.receive(QuicAction.Reject(sid, QuicRejectReason.UNSUPPORTED), host, true, 5))
    assertEquals(State.Ended(End.PeerRejected(QuicRejectReason.UNSUPPORTED)), s.state)
  }

  @Test fun theMacEndingWhileWeWaitEndsTheRequest() {
    val s = asked()
    assertEquals(emptyList<Effect>(), s.receive(QuicAction.End(sid), host, true, 5))
    assertEquals(State.Ended(End.PeerEnded), s.state)
  }

  @Test fun anAcceptFromTheMacMeansNothingToTheAsker() {
    val s = asked()
    assertEquals(emptyList<Effect>(), s.receive(QuicAction.Accept(sid), host, true, 5))
    assertEquals(State.AwaitingOffer, s.state)
  }

  // ---- the clock ----

  @Test fun anOfferThatNeverComesEndsTheRequestAfterTenSeconds() {
    val s = asked(now = 1000)
    assertEquals(11_000L, s.nextDeadlineMs)
    assertEquals(emptyList<Effect>(), s.tick(10_999))
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid))), s.tick(11_000))
    assertEquals(State.Ended(End.OfferTimeout), s.state)
    assertEquals(emptyList<Effect>(), s.tick(11_001)) // once
  }

  @Test fun aClientThatNeverReportsIsGivenUpAfterTwelveSeconds() {
    val s = connecting(now = 1000)
    assertEquals(13_000L, s.nextDeadlineMs)
    assertEquals(emptyList<Effect>(), s.tick(12_999))
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid)), Effect.Close(0)), s.tick(13_000))
    assertEquals(State.Ended(End.ConnectTimeout), s.state)
  }

  @Test fun anOpenSessionHasNoClockOfItsOwn() {
    val s = connected(now = 0)
    assertNull(s.nextDeadlineMs)
    assertEquals(emptyList<Effect>(), s.tick(10_000_000))
    assertEquals(State.Connected, s.state)
  }

  @Test fun customTimesAreHonoured() {
    val config = QuicSession.Config(offerWaitMs = 100, connectWatchdogMs = 200)
    val s = session(config = config)
    s.request(QuicKind.ECHO, sid, true, 0)
    assertEquals(emptyList<Effect>(), s.tick(99))
    assertTrue(s.tick(100).isNotEmpty())
    val t = session(config = config)
    t.request(QuicKind.ECHO, sid, true, 0)
    t.receive(offer(), host, true, 0)
    assertEquals(emptyList<Effect>(), t.tick(199))
    assertTrue(t.tick(200).isNotEmpty())
  }

  // ---- what the Rust client reports ----

  @Test fun theClientConnectingOpensTheSession() {
    val s = connecting()
    assertEquals(emptyList<Effect>(), s.connected(50))
    assertEquals(State.Connected, s.state)
    assertNull(s.nextDeadlineMs)
  }

  @Test fun everyFailureEndsTheSessionTellsTheMacAndReleasesTheHandle() {
    for (error in QuicError.entries) {
      val s = connecting()
      assertEquals(
        "$error",
        listOf<Effect>(Effect.SendAction(QuicAction.End(sid)), Effect.Close(0)),
        s.failed(error, 50),
      )
      assertEquals(State.Ended(End.Failed(error)), s.state)
    }
  }

  @Test fun aFailureOutsideConnectingChangesNothing() {
    val idle = session()
    assertEquals(emptyList<Effect>(), idle.failed(QuicError.Timeout, 5))
    val open = connected()
    assertEquals(emptyList<Effect>(), open.failed(QuicError.Timeout, 5))
    assertEquals(State.Connected, open.state)
  }

  @Test fun theMacEndingAnOpenSessionClosesOurSideWithoutAnotherEnd() {
    val s = connected()
    assertEquals(listOf<Effect>(Effect.Close(0)), s.peerEnded(60))
    assertEquals(State.Ended(End.PeerEnded), s.state)
  }

  @Test fun aEndFromTheMacOverTheControlChannelClosesAnOpenSession() {
    val s = connected()
    assertEquals(listOf<Effect>(Effect.Close(0)), s.receive(QuicAction.End(sid), host, true, 60))
    assertEquals(State.Ended(End.PeerEnded), s.state)
  }

  @Test fun aLostConnectionEndsTheSessionWithoutTellingAnyone() {
    val s = connected()
    assertEquals(listOf<Effect>(Effect.Close(0)), s.closed(QuicError.LinkLost.code, 70))
    assertEquals(State.Ended(End.LinkLost), s.state)
  }

  @Test fun aCleanCloseAfterWeEndedChangesNothing() {
    val s = connected()
    s.end(80)
    assertEquals(emptyList<Effect>(), s.closed(0, 81))
    assertEquals(State.Ended(End.LocalEnded), s.state)
  }

  @Test fun aCleanCloseWhileStillConnectedChangesNothing() {
    // Only a LOST connection ends a session through `closed`: a clean close (0) is either our own end or the peer's END, and both
    // already ended the session through their own calls.
    val s = connected()
    assertEquals(emptyList<Effect>(), s.closed(0, 70))
    assertEquals(State.Connected, s.state)
  }

  @Test fun theClientConnectingMeansNothingOutsideConnecting() {
    val idle = session()
    assertEquals(emptyList<Effect>(), idle.connected(1))
    assertEquals(State.Idle, idle.state)
    val waiting = asked()
    assertEquals(emptyList<Effect>(), waiting.connected(1))
    assertEquals(State.AwaitingOffer, waiting.state)
    val done = connected()
    done.end(2)
    assertEquals(emptyList<Effect>(), done.connected(3))
    assertEquals(State.Ended(End.LocalEnded), done.state)
  }

  // ---- ending ourselves ----

  @Test fun endingAnOpenSessionTellsTheMacThenCloses() {
    val s = connected()
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid)), Effect.Close(0)), s.end(90))
    assertEquals(State.Ended(End.LocalEnded), s.state)
  }

  @Test fun endingWhileWaitingForTheOfferJustTellsTheMac() {
    val s = asked()
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid))), s.end(90))
  }

  @Test fun endingWithNoSessionDoesNothing() {
    val s = session()
    assertEquals(emptyList<Effect>(), s.end(0))
    assertEquals(State.Idle, s.state)
    val done = connected()
    done.end(1)
    assertEquals(emptyList<Effect>(), done.end(2))
  }

  @Test fun aNewRequestIsMadeOnceTheLastSessionEnded() {
    val s = connected()
    s.end(5)
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.Request(otherSid, QuicKind.ECHO))), s.request(QuicKind.ECHO, otherSid, true, 10))
    assertEquals(State.AwaitingOffer, s.state)
  }

  // ---- the link goes away (stage 1.8) ----

  @Test fun theLinkGoingAwayWhileWaitingForTheOfferJustTellsTheMac() {
    val s = asked()
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid))), s.linkLost(5))
    assertEquals(State.Ended(End.LinkChanged), s.state)
    assertNull(s.nextDeadlineMs)
  }

  @Test fun theLinkGoingAwayWhileConnectingOrConnectedTellsTheMacAndClosesTheClient() {
    for (build in listOf({ connecting() }, { connected() })) {
      val s = build()
      assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid)), Effect.Close(0)), s.linkLost(5))
      assertEquals(State.Ended(End.LinkChanged), s.state)
    }
  }

  @Test fun theLinkGoingAwayWithNoSessionDoesNothingAndDoesNotRepeat() {
    val idle = session()
    assertEquals(emptyList<Effect>(), idle.linkLost(0))
    assertEquals(State.Idle, idle.state)
    val s = connected()
    s.linkLost(1)
    assertEquals(emptyList<Effect>(), s.linkLost(2))
    val ended = connected()
    ended.end(1)
    assertEquals(emptyList<Effect>(), ended.linkLost(2))
    assertEquals(State.Ended(End.LocalEnded), ended.state) // the first reason stays
  }

  @Test fun aLateReportFromTheClientAfterTheLinkWentAwayChangesNothing() {
    val s = connecting()
    s.linkLost(5)
    assertEquals(emptyList<Effect>(), s.connected(6))
    assertEquals(emptyList<Effect>(), s.failed(QuicError.Timeout, 7))
    assertEquals(State.Ended(End.LinkChanged), s.state)
  }

  // ---- the Mac asks (a later stage serves it) ----

  @Test fun aRequestFromTheMacIsRefusedAsUnsupportedSoItNeverWaitsForUs() {
    val s = session()
    assertEquals(
      listOf<Effect>(Effect.SendAction(QuicAction.Reject(otherSid, QuicRejectReason.UNSUPPORTED))),
      s.receive(QuicAction.Request(otherSid, QuicKind.FILE), host, true, 0),
    )
    assertEquals(State.Idle, s.state)
  }

  @Test fun aRequestFromTheMacWhileBusyIsBusy() {
    val s = asked()
    assertEquals(
      listOf<Effect>(Effect.SendAction(QuicAction.Reject(otherSid, QuicRejectReason.BUSY))),
      s.receive(QuicAction.Request(otherSid, QuicKind.FILE), host, true, 5),
    )
    assertEquals(State.AwaitingOffer, s.state)
  }

  // ---- the Mac asks, the phone accepts (debug kinds only; the real approval UI is stage 2) ----

  private fun macAsked(now: Long = 0): QuicSession =
    QuicSession(QuicSession.Config(supportedKinds = setOf(QuicKind.ECHO), autoAcceptKinds = setOf(QuicKind.ECHO))).also {
      it.receive(QuicAction.Request(sid, QuicKind.ECHO), host, true, now)
    }

  @Test fun aRequestForAKindWeAcceptAutomaticallyIsAcceptedAndWeWaitForTheOffer() {
    val s = QuicSession(QuicSession.Config(autoAcceptKinds = setOf(QuicKind.ECHO)))
    assertEquals(
      listOf<Effect>(Effect.SendAction(QuicAction.Accept(sid))),
      s.receive(QuicAction.Request(sid, QuicKind.ECHO), host, true, 1000),
    )
    assertEquals(State.AwaitingOffer, s.state)
    assertEquals(QuicKind.ECHO, s.requestedByMac)
    assertEquals(11_000L, s.nextDeadlineMs)
  }

  @Test fun theOfferThatFollowsAnAcceptedRequestMakesTheClientConnect() {
    val s = macAsked()
    assertEquals(listOf<Effect>(Effect.Connect(host, 53125, fp, tok)), s.receive(offer(), host, true, 100))
    assertEquals(State.Connecting, s.state)
    assertEquals(emptyList<Effect>(), s.connected(150))
    assertEquals(State.Connected, s.state)
  }

  @Test fun anAcceptedRequestWhoseOfferNeverComesTimesOutAndTellsTheMac() {
    val s = macAsked(now = 500)
    assertEquals(emptyList<Effect>(), s.tick(10_499))
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.End(sid))), s.tick(10_500))
    assertEquals(State.Ended(End.OfferTimeout), s.state)
  }

  @Test fun theMacEndingBeforeTheOfferEndsTheSession() {
    val s = macAsked()
    assertEquals(emptyList<Effect>(), s.receive(QuicAction.End(sid), host, true, 5))
    assertEquals(State.Ended(End.PeerEnded), s.state)
  }

  @Test fun aRequestWeDoNotAcceptAutomaticallyOrOffTheLanOrWhileBusyIsRefusedWithTheGatesReason() {
    val auto = QuicSession(QuicSession.Config(autoAcceptKinds = setOf(QuicKind.ECHO)))
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.Reject(otherSid, QuicRejectReason.UNSUPPORTED))), auto.receive(QuicAction.Request(otherSid, QuicKind.FILE), host, true, 0))
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.Reject(otherSid, QuicRejectReason.RELAY))), auto.receive(QuicAction.Request(otherSid, QuicKind.ECHO), null, false, 0))
    assertEquals(State.Idle, auto.state)
    val busy = macAsked()
    assertEquals(listOf<Effect>(Effect.SendAction(QuicAction.Reject(otherSid, QuicRejectReason.BUSY))), busy.receive(QuicAction.Request(otherSid, QuicKind.ECHO), host, true, 5))
    assertEquals(State.AwaitingOffer, busy.state)
  }

  @Test fun theSameRequestDeliveredTwiceIsIgnored() {
    val s = macAsked()
    assertEquals(emptyList<Effect>(), s.receive(QuicAction.Request(sid, QuicKind.ECHO), host, true, 5))
    assertEquals(State.AwaitingOffer, s.state)
  }

  @Test fun aSessionWeAskedForIsNotOneTheMacAskedFor() {
    val s = asked()
    assertNull(s.requestedByMac)
  }

  // ---- error codes ----

  @Test fun errorCodesKeepTheirNumbersAndNames() {
    // Rust's `ErrorCode` (tests/params.rs) pins the same table: the numbers cross JNI, the names go to logs.
    val table = listOf(1 to "FpMismatch", 2 to "TokenRejected", 3 to "Timeout", 4 to "LinkLost", 5 to "Protocol", 6 to "Internal")
    for ((number, name) in table) {
      assertEquals(name, QuicError.fromCode(number)?.name)
      assertEquals(number, QuicError.fromCode(number)?.code)
    }
    assertNull(QuicError.fromCode(0))
    assertNull(QuicError.fromCode(7))
  }
}
