package expo.modules.selfadb

import expo.modules.selfadb.quic.QuicAction
import expo.modules.selfadb.quic.QuicHandshake
import expo.modules.selfadb.quic.QuicHandshake.Close
import expo.modules.selfadb.quic.QuicHandshake.Phase
import expo.modules.selfadb.quic.QuicHandshake.Verdict
import expo.modules.selfadb.quic.QuicOffer
import expo.modules.selfadb.quic.QuicRejectReason
import expo.modules.selfadb.quic.QuicSide
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The rules of the `q.*` handshake as pure logic (plan stage 1.3): who may send what, when, and the accept timeout. One [QuicHandshake]
 * per session, four views: the Mac or the phone, as the side that asked or the side that was asked. The Swift twin
 * (`QuicHandshakeTests`) runs the same table. The offer is always the Mac's (it is the QUIC server).
 */
class QuicHandshakeTest {
  private val sid = "123e4567-e89b-12d3-a456-426614174000"
  private val other = "223e4567-e89b-12d3-a456-426614174000"
  private val fp = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  private val tok = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
  private val offer = QuicOffer(sid, 53125, fp, tok)

  private fun make(side: QuicSide, asker: Boolean, now: Long = 0, timeout: Long = 60_000) =
    QuicHandshake(side, asker, sid, now, timeout)

  private fun applied(p: Phase) = Verdict.Applied(p)
  private fun ignored(code: String) = Verdict.Ignored(code)

  // ---- Mac asked (cast, cam, audio ...): req -> phone accepts -> Mac offers ----------------------------------------------

  @Test fun theMacWaitsForAnAcceptWhenItAsked() {
    assertEquals(Phase.AwaitingAccept(61_000), make(QuicSide.MAC, true, now = 1_000).phase)
  }

  @Test fun theMacMustNotOfferBeforeTheAccept() {
    val h = make(QuicSide.MAC, true)
    assertEquals(ignored("offer-not-allowed"), h.send(QuicAction.Offer(offer), 10))
    assertEquals(Phase.AwaitingAccept(60_000), h.phase)
  }

  @Test fun theAcceptOpensTheWayToTheOfferAndTheOfferIsSent() {
    val h = make(QuicSide.MAC, true)
    assertEquals(applied(Phase.MayOffer), h.receive(QuicAction.Accept(sid), 5_000))
    assertEquals(applied(Phase.Offered(offer)), h.send(QuicAction.Offer(offer), 5_001))
  }

  @Test fun aRejectFromThePhoneClosesTheMacsRequestWithItsReason() {
    val h = make(QuicSide.MAC, true)
    assertEquals(applied(Phase.Closed(Close.Rejected(QuicRejectReason.DENIED))), h.receive(QuicAction.Reject(sid, QuicRejectReason.DENIED), 100))
  }

  @Test fun theMacGivesUpWhenNoAcceptArrivesWithinTheTimeout() {
    val h = make(QuicSide.MAC, true)
    assertEquals(Phase.AwaitingAccept(60_000), h.tick(59_999))
    assertEquals(Phase.Closed(Close.TimedOut), h.tick(60_000))
  }

  @Test fun anAcceptThatArrivesAfterTheDeadlineIsTooLate() {
    val h = make(QuicSide.MAC, true)
    assertEquals(ignored("closed"), h.receive(QuicAction.Accept(sid), 60_000))
    assertEquals(Phase.Closed(Close.TimedOut), h.phase)
  }

  @Test fun theMacNeverReceivesAnOfferOrARequestInItsOwnSession() {
    val h = make(QuicSide.MAC, true)
    assertEquals(ignored("unexpected-offer"), h.receive(QuicAction.Offer(offer), 1))
    assertEquals(ignored("unexpected-request"), h.receive(QuicAction.Request(sid, expo.modules.selfadb.quic.QuicKind.CAST), 1))
    assertEquals(Phase.AwaitingAccept(60_000), h.phase)
  }

  // ---- phone asked (file): req -> Mac offers at once, no accept step --------------------------------------------------------

  @Test fun whenThePhoneAsksTheMacMayOfferAtOnce() {
    val h = make(QuicSide.MAC, false)
    assertEquals(Phase.MayOffer, h.phase)
    assertEquals(applied(Phase.Offered(offer)), h.send(QuicAction.Offer(offer), 1))
  }

  @Test fun theMacCanRefuseAPhoneRequest() {
    val h = make(QuicSide.MAC, false)
    assertEquals(applied(Phase.Closed(Close.Rejected(QuicRejectReason.BUSY))), h.send(QuicAction.Reject(sid, QuicRejectReason.BUSY), 1))
  }

  @Test fun thereIsNoAcceptStepWhenThePhoneAsked() {
    val h = make(QuicSide.MAC, false)
    assertEquals(ignored("unexpected-accept"), h.receive(QuicAction.Accept(sid), 1))
    assertEquals(Phase.MayOffer, h.phase)
  }

  @Test fun theMacDoesNotTimeOutWaitingForNothing() {
    assertEquals(Phase.MayOffer, make(QuicSide.MAC, false).tick(10_000_000))
  }

  // ---- phone asked the Mac (file): the phone waits for the offer ------------------------------------------------------------

  @Test fun aPhoneThatAskedWaitsForTheOffer() {
    val h = make(QuicSide.PHONE, true)
    assertEquals(Phase.AwaitingOffer, h.phase)
    assertEquals(applied(Phase.Offered(offer)), h.receive(QuicAction.Offer(offer), 1))
  }

  @Test fun aRejectFromTheMacClosesThePhonesRequest() {
    val h = make(QuicSide.PHONE, true)
    assertEquals(applied(Phase.Closed(Close.Rejected(QuicRejectReason.RELAY))), h.receive(QuicAction.Reject(sid, QuicRejectReason.RELAY), 1))
  }

  @Test fun aPhoneThatAskedIgnoresAnAcceptAndCannotSendOne() {
    val h = make(QuicSide.PHONE, true)
    assertEquals(ignored("unexpected-accept"), h.receive(QuicAction.Accept(sid), 1))
    assertEquals(ignored("accept-not-allowed"), h.send(QuicAction.Accept(sid), 1))
    assertEquals(Phase.AwaitingOffer, h.phase)
  }

  @Test fun aPhoneThatAskedHasNoAcceptTimeoutHere() {
    assertEquals(Phase.AwaitingOffer, make(QuicSide.PHONE, true).tick(10_000_000))
  }

  // ---- Mac asked the phone: the phone asks its user -------------------------------------------------------------------------

  @Test fun aPhoneThatWasAskedWaitsForItsUser() {
    assertEquals(Phase.AwaitingUser(60_500), make(QuicSide.PHONE, false, now = 500).phase)
  }

  @Test fun theUserSaysYesThenTheOfferArrives() {
    val h = make(QuicSide.PHONE, false)
    assertEquals(applied(Phase.AwaitingOffer), h.send(QuicAction.Accept(sid), 2_000))
    assertEquals(applied(Phase.Offered(offer)), h.receive(QuicAction.Offer(offer), 2_100))
  }

  @Test fun anOfferBeforeTheAcceptIsIgnored() {
    val h = make(QuicSide.PHONE, false)
    assertEquals(ignored("offer-before-accept"), h.receive(QuicAction.Offer(offer), 1))
    assertEquals(Phase.AwaitingUser(60_000), h.phase)
  }

  @Test fun theUserSaysNo() {
    val h = make(QuicSide.PHONE, false)
    assertEquals(applied(Phase.Closed(Close.Rejected(QuicRejectReason.DENIED))), h.send(QuicAction.Reject(sid, QuicRejectReason.DENIED), 1))
  }

  @Test fun theUserDoesNotAnswerInTime() {
    val h = make(QuicSide.PHONE, false)
    assertEquals(Phase.AwaitingUser(60_000), h.tick(59_999))
    assertEquals(Phase.Closed(Close.TimedOut), h.tick(60_000))
    assertEquals(ignored("closed"), h.send(QuicAction.Accept(sid), 60_001))
  }

  @Test fun theAcceptTimeoutIsConfigurable() {
    val h = make(QuicSide.PHONE, false, now = 0, timeout = 5_000)
    assertEquals(Phase.AwaitingUser(5_000), h.tick(4_999))
    assertEquals(Phase.Closed(Close.TimedOut), h.tick(5_000))
  }

  // ---- rules that hold in every view ----------------------------------------------------------------------------------------

  @Test fun anActionForAnotherSessionIsIgnored() {
    val h = make(QuicSide.MAC, true)
    assertEquals(ignored("sid"), h.receive(QuicAction.Accept(other), 1))
    assertEquals(Phase.AwaitingAccept(60_000), h.phase)
    assertEquals(ignored("sid"), make(QuicSide.PHONE, false).send(QuicAction.Accept(other), 1))
  }

  @Test fun aSessionIdInUpperCaseIsTheSameSession() {
    assertEquals(applied(Phase.MayOffer), make(QuicSide.MAC, true).receive(QuicAction.Accept(sid.uppercase()), 1))
  }

  @Test fun aSecondOfferIsIgnored() {
    val h = make(QuicSide.PHONE, true)
    h.receive(QuicAction.Offer(offer), 1)
    assertEquals(ignored("duplicate-offer"), h.receive(QuicAction.Offer(offer), 2))
    assertEquals(Phase.Offered(offer), h.phase)
    val m = make(QuicSide.MAC, false)
    m.send(QuicAction.Offer(offer), 1)
    assertEquals(ignored("offer-not-allowed"), m.send(QuicAction.Offer(offer), 2))
  }

  @Test fun anEndClosesAnyOpenPhaseFromEitherSide() {
    for ((side, asker) in listOf(QuicSide.MAC to true, QuicSide.MAC to false, QuicSide.PHONE to true, QuicSide.PHONE to false)) {
      assertEquals("$side asker=$asker receive", applied(Phase.Closed(Close.Ended)), make(side, asker).receive(QuicAction.End(sid), 1))
      assertEquals("$side asker=$asker send", applied(Phase.Closed(Close.Ended)), make(side, asker).send(QuicAction.End(sid), 1))
    }
  }

  @Test fun anEndAfterAnOfferStillClosesTheSession() {
    val h = make(QuicSide.PHONE, true)
    h.receive(QuicAction.Offer(offer), 1)
    assertEquals(applied(Phase.Closed(Close.Ended)), h.receive(QuicAction.End(sid), 2))
  }

  @Test fun nothingHappensAfterTheSessionClosed() {
    val h = make(QuicSide.MAC, true)
    h.receive(QuicAction.End(sid), 1)
    assertEquals(ignored("closed"), h.receive(QuicAction.Accept(sid), 2))
    assertEquals(ignored("closed"), h.send(QuicAction.Offer(offer), 2))
    assertEquals(ignored("closed"), h.send(QuicAction.End(sid), 2))
    assertEquals(Phase.Closed(Close.Ended), h.phase)
  }

  @Test fun aRejectOnlyMeansSomethingToTheSideThatAsked() {
    assertEquals(ignored("unexpected-reject"), make(QuicSide.MAC, false).receive(QuicAction.Reject(sid, QuicRejectReason.BUSY), 1))
    assertEquals(ignored("unexpected-reject"), make(QuicSide.PHONE, false).receive(QuicAction.Reject(sid, QuicRejectReason.BUSY), 1))
  }

  @Test fun aRejectCannotBeSentByTheSideThatAsked() {
    assertEquals(ignored("reject-not-allowed"), make(QuicSide.MAC, true).send(QuicAction.Reject(sid, QuicRejectReason.BUSY), 1))
    assertEquals(ignored("reject-not-allowed"), make(QuicSide.PHONE, true).send(QuicAction.Reject(sid, QuicRejectReason.BUSY), 1))
  }
}
