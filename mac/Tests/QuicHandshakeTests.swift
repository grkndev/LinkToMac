import Foundation
import Testing

/// The rules of the `q.*` handshake as pure logic (plan stage 1.3): who may send what, when, and the accept timeout. One `QuicHandshake`
/// per session, four views: the Mac or the phone, as the side that asked or the side that was asked. The Kotlin mirror
/// (`QuicHandshakeTest`) runs the same table. The offer is always the Mac's (it is the QUIC server).
@Suite struct QuicHandshakeTests {
    private let sid = "123e4567-e89b-12d3-a456-426614174000"
    private let other = "223e4567-e89b-12d3-a456-426614174000"
    private let fp = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private let tok = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private var offer: QuicOffer { QuicOffer(sid: sid, port: 53125, fp: fp, tok: tok) }

    private func make(_ side: QuicSide, asker: Bool, at now: Int64 = 0, timeout: Int64 = 60_000) -> QuicHandshake {
        QuicHandshake(side: side, iRequested: asker, sid: sid, nowMs: now, acceptTimeoutMs: timeout)
    }

    // MARK: Mac asked (cast, cam, audio ...): req -> phone accepts -> Mac offers

    @Test func theMacWaitsForAnAcceptWhenItAsked() {
        let h = make(.mac, asker: true, at: 1_000)
        #expect(h.phase == .awaitingAccept(deadlineMs: 61_000))
    }

    @Test func theMacMustNotOfferBeforeTheAccept() {
        var h = make(.mac, asker: true)
        #expect(h.send(.offer(offer), nowMs: 10) == .ignored("offer-not-allowed"))
        #expect(h.phase == .awaitingAccept(deadlineMs: 60_000))
    }

    @Test func theAcceptOpensTheWayToTheOfferAndTheOfferIsSent() {
        var h = make(.mac, asker: true)
        #expect(h.receive(.accept(sid: sid), nowMs: 5_000) == .applied(.mayOffer))
        #expect(h.send(.offer(offer), nowMs: 5_001) == .applied(.offered(offer)))
    }

    @Test func aRejectFromThePhoneClosesTheMacsRequestWithItsReason() {
        var h = make(.mac, asker: true)
        #expect(h.receive(.reject(sid: sid, reason: .denied), nowMs: 100) == .applied(.closed(.rejected(.denied))))
    }

    @Test func theMacGivesUpWhenNoAcceptArrivesWithinTheTimeout() {
        var h = make(.mac, asker: true)
        #expect(h.tick(nowMs: 59_999) == .awaitingAccept(deadlineMs: 60_000))
        #expect(h.tick(nowMs: 60_000) == .closed(.timedOut))
    }

    @Test func anAcceptThatArrivesAfterTheDeadlineIsTooLate() {
        var h = make(.mac, asker: true)
        #expect(h.receive(.accept(sid: sid), nowMs: 60_000) == .ignored("closed"))
        #expect(h.phase == .closed(.timedOut))
    }

    @Test func theMacNeverReceivesAnOfferOrARequestInItsOwnSession() {
        var h = make(.mac, asker: true)
        #expect(h.receive(.offer(offer), nowMs: 1) == .ignored("unexpected-offer"))
        #expect(h.receive(.request(sid: sid, kind: .cast), nowMs: 1) == .ignored("unexpected-request"))
        #expect(h.phase == .awaitingAccept(deadlineMs: 60_000))
    }

    // MARK: phone asked (file): req -> Mac offers at once, no accept step

    @Test func whenThePhoneAsksTheMacMayOfferAtOnce() {
        var h = make(.mac, asker: false)
        #expect(h.phase == .mayOffer)
        #expect(h.send(.offer(offer), nowMs: 1) == .applied(.offered(offer)))
    }

    @Test func theMacCanRefuseAPhoneRequest() {
        var h = make(.mac, asker: false)
        #expect(h.send(.reject(sid: sid, reason: .busy), nowMs: 1) == .applied(.closed(.rejected(.busy))))
    }

    @Test func thereIsNoAcceptStepWhenThePhoneAsked() {
        var h = make(.mac, asker: false)
        #expect(h.receive(.accept(sid: sid), nowMs: 1) == .ignored("unexpected-accept"))
        #expect(h.phase == .mayOffer)
    }

    @Test func theMacDoesNotTimeOutWaitingForNothing() {
        var h = make(.mac, asker: false)
        #expect(h.tick(nowMs: 10_000_000) == .mayOffer)
    }

    // MARK: phone asked the Mac (file): the phone waits for the offer

    @Test func aPhoneThatAskedWaitsForTheOffer() {
        var h = make(.phone, asker: true)
        #expect(h.phase == .awaitingOffer)
        #expect(h.receive(.offer(offer), nowMs: 1) == .applied(.offered(offer)))
    }

    @Test func aRejectFromTheMacClosesThePhonesRequest() {
        var h = make(.phone, asker: true)
        #expect(h.receive(.reject(sid: sid, reason: .relay), nowMs: 1) == .applied(.closed(.rejected(.relay))))
    }

    @Test func aPhoneThatAskedIgnoresAnAcceptAndCannotSendOne() {
        var h = make(.phone, asker: true)
        #expect(h.receive(.accept(sid: sid), nowMs: 1) == .ignored("unexpected-accept"))
        #expect(h.send(.accept(sid: sid), nowMs: 1) == .ignored("accept-not-allowed"))
        #expect(h.phase == .awaitingOffer)
    }

    @Test func aPhoneThatAskedHasNoAcceptTimeoutHere() {
        var h = make(.phone, asker: true)
        #expect(h.tick(nowMs: 10_000_000) == .awaitingOffer)
    }

    // MARK: Mac asked the phone: the phone asks its user

    @Test func aPhoneThatWasAskedWaitsForItsUser() {
        let h = make(.phone, asker: false, at: 500)
        #expect(h.phase == .awaitingUser(deadlineMs: 60_500))
    }

    @Test func theUserSaysYesThenTheOfferArrives() {
        var h = make(.phone, asker: false)
        #expect(h.send(.accept(sid: sid), nowMs: 2_000) == .applied(.awaitingOffer))
        #expect(h.receive(.offer(offer), nowMs: 2_100) == .applied(.offered(offer)))
    }

    @Test func anOfferBeforeTheAcceptIsIgnored() {
        var h = make(.phone, asker: false)
        #expect(h.receive(.offer(offer), nowMs: 1) == .ignored("offer-before-accept"))
        #expect(h.phase == .awaitingUser(deadlineMs: 60_000))
    }

    @Test func theUserSaysNo() {
        var h = make(.phone, asker: false)
        #expect(h.send(.reject(sid: sid, reason: .denied), nowMs: 1) == .applied(.closed(.rejected(.denied))))
    }

    @Test func theUserDoesNotAnswerInTime() {
        var h = make(.phone, asker: false)
        #expect(h.tick(nowMs: 59_999) == .awaitingUser(deadlineMs: 60_000))
        #expect(h.tick(nowMs: 60_000) == .closed(.timedOut))
        #expect(h.send(.accept(sid: sid), nowMs: 60_001) == .ignored("closed"))
    }

    @Test func theAcceptTimeoutIsConfigurable() {
        var h = make(.phone, asker: false, at: 0, timeout: 5_000)
        #expect(h.tick(nowMs: 4_999) == .awaitingUser(deadlineMs: 5_000))
        #expect(h.tick(nowMs: 5_000) == .closed(.timedOut))
    }

    // MARK: rules that hold in every view

    @Test func anActionForAnotherSessionIsIgnored() {
        var h = make(.mac, asker: true)
        #expect(h.receive(.accept(sid: other), nowMs: 1) == .ignored("sid"))
        #expect(h.phase == .awaitingAccept(deadlineMs: 60_000))
        var p = make(.phone, asker: false)
        #expect(p.send(.accept(sid: other), nowMs: 1) == .ignored("sid"))
    }

    @Test func aSessionIdInUpperCaseIsTheSameSession() {
        var h = make(.mac, asker: true)
        #expect(h.receive(.accept(sid: sid.uppercased()), nowMs: 1) == .applied(.mayOffer))
    }

    @Test func aSecondOfferIsIgnored() {
        var h = make(.phone, asker: true)
        _ = h.receive(.offer(offer), nowMs: 1)
        #expect(h.receive(.offer(offer), nowMs: 2) == .ignored("duplicate-offer"))
        #expect(h.phase == .offered(offer))
        var m = make(.mac, asker: false)
        _ = m.send(.offer(offer), nowMs: 1)
        #expect(m.send(.offer(offer), nowMs: 2) == .ignored("offer-not-allowed"))
    }

    @Test func anEndClosesAnyOpenPhaseFromEitherSide() {
        for (side, asker) in [(QuicSide.mac, true), (.mac, false), (.phone, true), (.phone, false)] {
            var received = make(side, asker: asker)
            #expect(received.receive(.end(sid: sid), nowMs: 1) == .applied(.closed(.ended)), "\(side) asker=\(asker) receive")
            var sent = make(side, asker: asker)
            #expect(sent.send(.end(sid: sid), nowMs: 1) == .applied(.closed(.ended)), "\(side) asker=\(asker) send")
        }
    }

    @Test func anEndAfterAnOfferStillClosesTheSession() {
        var h = make(.phone, asker: true)
        _ = h.receive(.offer(offer), nowMs: 1)
        #expect(h.receive(.end(sid: sid), nowMs: 2) == .applied(.closed(.ended)))
    }

    @Test func nothingHappensAfterTheSessionClosed() {
        var h = make(.mac, asker: true)
        _ = h.receive(.end(sid: sid), nowMs: 1)
        #expect(h.receive(.accept(sid: sid), nowMs: 2) == .ignored("closed"))
        #expect(h.send(.offer(offer), nowMs: 2) == .ignored("closed"))
        #expect(h.send(.end(sid: sid), nowMs: 2) == .ignored("closed"))
        #expect(h.phase == .closed(.ended))
    }

    @Test func aRejectOnlyMeansSomethingToTheSideThatAsked() {
        var macAnswering = make(.mac, asker: false)
        #expect(macAnswering.receive(.reject(sid: sid, reason: .busy), nowMs: 1) == .ignored("unexpected-reject"))
        var phoneAnswering = make(.phone, asker: false)
        #expect(phoneAnswering.receive(.reject(sid: sid, reason: .busy), nowMs: 1) == .ignored("unexpected-reject"))
    }

    @Test func aRejectCannotBeSentByTheSideThatAsked() {
        var macAsking = make(.mac, asker: true)
        #expect(macAsking.send(.reject(sid: sid, reason: .busy), nowMs: 1) == .ignored("reject-not-allowed"))
        var phoneAsking = make(.phone, asker: true)
        #expect(phoneAsking.send(.reject(sid: sid, reason: .busy), nowMs: 1) == .ignored("reject-not-allowed"))
    }
}
