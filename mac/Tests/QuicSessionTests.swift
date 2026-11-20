import Foundation
import Testing

/// The rules of ONE QUIC session on the Mac (plan stage 1.6) as pure logic: an injected clock and an injected token source, so every time
/// limit is tested at its exact boundary and nothing here opens a socket. The Network.framework glue (`QuicListener`) is covered by the
/// integration tests; this file is what makes the rules themselves trustworthy.
@Suite struct QuicSessionTests {
    private let sid = "123e4567-e89b-12d3-a456-426614174000"
    private let otherSid = "223e4567-e89b-12d3-a456-426614174000"
    private let fp = String(repeating: "ab", count: 32)
    private let token: [UInt8] = Array(0 ..< 32)
    /// `token` as it travels in the offer (unpadded base64url).
    private let tokenText = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    private func make(kinds: Set<QuicKind> = [.echo], token: [UInt8]? = Array(0 ..< 32), config: QuicSession.Config = .init()) -> QuicSession {
        var config = config
        config.supportedKinds = kinds
        return QuicSession(config: config, fingerprint: fp, makeToken: { token })
    }

    private func request(_ kind: QuicKind = .echo, sid: String? = nil) -> QuicAction { .request(sid: sid ?? self.sid, kind: kind) }

    private func offer(port: Int) -> QuicAction {
        .offer(QuicOffer(sid: sid, port: port, fp: fp, tok: tokenText))
    }

    /// Phone asked, the listener is up, the Mac has offered: state `offered`.
    private func offered(at now: Int64 = 0, port: Int = 53125, kinds: Set<QuicKind> = [.echo], config: QuicSession.Config = .init()) -> QuicSession {
        let s = make(kinds: kinds, config: config)
        _ = s.receive(request(), onLan: true, nowMs: now)
        _ = s.listenerReady(port: port, nowMs: now)
        return s
    }

    /// `offered`, plus connection `conn` that presented the right token: state `connected`.
    private func connected(at now: Int64 = 0, conn: Int = 1) -> QuicSession {
        let s = offered(at: now)
        #expect(s.connectionArrived(conn, nowMs: now))
        _ = s.sessionStreamOpened(conn, token: token, isBidirectional: true, nowMs: now)
        return s
    }

    // MARK: the phone asks (the Mac answers)

    @Test func aRequestOpensTheListener() {
        let s = make()
        #expect(s.state == .idle)
        #expect(s.receive(request(), onLan: true, nowMs: 0) == [.openListener])
        #expect(s.state == .accepted)
    }

    @Test func theOfferCarriesThePortTheFingerprintAndAFreshToken() throws {
        let s = make()
        _ = s.receive(request(), onLan: true, nowMs: 0)
        let effects = s.listenerReady(port: 53126, nowMs: 100)
        #expect(effects == [.sendAction(offer(port: 53126))])
        #expect(s.state == .offered)
        // What goes on the wire must pass the very validation the phone applies.
        guard case let .sendAction(action) = try #require(effects.first) else { Issue.record("no action"); return }
        #expect(QuicControl.parse(QuicControl.encode(action), allowEcho: true) == .action(action))
    }

    @Test func aRequestOverTheRelayIsRefused() {
        let s = make()
        #expect(s.receive(request(), onLan: false, nowMs: 0) == [.sendAction(.reject(sid: sid, reason: .relay))])
        #expect(s.state == .idle)
    }

    @Test func aKindWeDoNotServeIsRefused() {
        let s = make(kinds: [.echo])
        #expect(s.receive(request(.cast), onLan: true, nowMs: 0) == [.sendAction(.reject(sid: sid, reason: .unsupported))])
        #expect(s.state == .idle)
        #expect(make(kinds: []).receive(request(.echo), onLan: true, nowMs: 0) == [.sendAction(.reject(sid: sid, reason: .unsupported))])
    }

    @Test func aSecondRequestWhileOneRunsIsBusyAndTheFirstIsUntouched() {
        let s = offered()
        let effects = s.receive(request(sid: otherSid), onLan: true, nowMs: 5)
        #expect(effects == [.sendAction(.reject(sid: otherSid, reason: .busy))])
        #expect(s.state == .offered)
        // The first session still works.
        #expect(s.connectionArrived(1, nowMs: 6))
        #expect(s.sessionStreamOpened(1, token: token, isBidirectional: true, nowMs: 6) == [.writeSession("OK")])
    }

    @Test func busyIsCheckedBeforeTheLink() {
        let s = offered()
        #expect(s.receive(request(sid: otherSid), onLan: false, nowMs: 5) == [.sendAction(.reject(sid: otherSid, reason: .busy))])
    }

    @Test func theSameRequestDeliveredTwiceIsIgnored() {
        let s = offered()
        #expect(s.receive(request(), onLan: true, nowMs: 5) == [])
        #expect(s.state == .offered)
    }

    @Test func aSessionIdInUpperCaseIsTheSameSession() {
        let s = offered()
        #expect(s.receive(request(sid: sid.uppercased()), onLan: true, nowMs: 5) == [])
    }

    @Test func aNewRequestIsServedOnceTheLastSessionEnded() {
        let s = offered()
        _ = s.end(.localEnded, nowMs: 10)
        #expect(s.state == .ended(.localEnded))
        #expect(s.receive(request(sid: otherSid), onLan: true, nowMs: 20) == [.openListener])
        #expect(s.state == .accepted)
    }

    @Test func aFailingTokenSourceRefusesTheRequestInsteadOfOfferingNothing() {
        let s = make(token: nil)
        _ = s.receive(request(), onLan: true, nowMs: 0)
        #expect(s.listenerReady(port: 53125, nowMs: 0) == [.sendAction(.reject(sid: sid, reason: .busy)), .closeListener])
        #expect(s.state == .ended(.listenerFailed))
    }

    @Test func aTokenOfTheWrongSizeIsNeverOffered() {
        let s = make(token: Array(0 ..< 31))
        _ = s.receive(request(), onLan: true, nowMs: 0)
        #expect(s.listenerReady(port: 53125, nowMs: 0) == [.sendAction(.reject(sid: sid, reason: .busy)), .closeListener])
    }

    @Test func actionsForAnotherSessionOrWithNoSessionAreIgnored() {
        let s = make()
        #expect(s.receive(.end(sid: sid), onLan: true, nowMs: 0) == [])
        #expect(s.receive(.accept(sid: sid), onLan: true, nowMs: 0) == [])
        #expect(s.receive(.reject(sid: sid, reason: .busy), onLan: true, nowMs: 0) == [])
        #expect(s.state == .idle)
        let running = offered()
        #expect(running.receive(.end(sid: otherSid), onLan: true, nowMs: 5) == [])
        #expect(running.state == .offered)
    }

    @Test func theMacNeverReceivesAnOfferOrAnAcceptInAPhoneRequestedSession() {
        let s = offered()
        #expect(s.receive(offer(port: 53125), onLan: true, nowMs: 5) == [])
        #expect(s.receive(.accept(sid: sid), onLan: true, nowMs: 5) == [])
        #expect(s.state == .offered)
    }

    // MARK: the token

    @Test func theRightTokenOpensTheSession() {
        let s = offered()
        #expect(s.connectionArrived(1, nowMs: 10))
        #expect(s.sessionStreamOpened(1, token: token, isBidirectional: true, nowMs: 20) == [.writeSession("OK")])
        #expect(s.state == .connected)
    }

    @Test func aWrongTokenIsRefusedInBandAndTheConnectionIsLetGoAfterAGrace() {
        let s = offered()
        #expect(s.connectionArrived(1, nowMs: 10))
        var wrong = token
        wrong[31] ^= 0x01
        #expect(s.sessionStreamOpened(1, token: wrong, isBidirectional: true, nowMs: 20)
            == [.rejectInBand(conn: 1), .closeConnection(conn: 1, graceMs: 5000)])
        // The offer stays valid for the real phone: a stranger on the LAN must not be able to cancel it.
        #expect(s.state == .offered)
        #expect(s.connectionArrived(2, nowMs: 30))
        #expect(s.sessionStreamOpened(2, token: token, isBidirectional: true, nowMs: 40) == [.writeSession("OK")])
    }

    @Test func aTokenThatIsTooShortOrTooLongIsWrong() {
        for bad in [Array(token.prefix(31)), token + [0], []] as [[UInt8]] {
            let s = offered()
            #expect(s.connectionArrived(1, nowMs: 0))
            #expect(s.sessionStreamOpened(1, token: bad, isBidirectional: true, nowMs: 1)
                == [.rejectInBand(conn: 1), .closeConnection(conn: 1, graceMs: 5000)], "\(bad.count) bytes")
        }
    }

    @Test func aFirstStreamThatIsNotBidirectionalIsRefusedEvenWithTheRightBytes() {
        let s = offered()
        #expect(s.connectionArrived(1, nowMs: 0))
        #expect(s.sessionStreamOpened(1, token: token, isBidirectional: false, nowMs: 1)
            == [.rejectInBand(conn: 1), .closeConnection(conn: 1, graceMs: 5000)])
        #expect(s.state == .offered)
    }

    @Test func theTokenWindowIsFiveSecondsFromTheConnection() {
        let s = offered()
        #expect(s.connectionArrived(1, nowMs: 1000))
        #expect(s.tick(nowMs: 5999) == [])
        #expect(s.tick(nowMs: 6000) == [.rejectInBand(conn: 1), .closeConnection(conn: 1, graceMs: 0)])
        #expect(s.state == .offered)
        #expect(s.tick(nowMs: 6001) == [])   // reported once
    }

    @Test func theTokenIsUsedOnce() {
        let s = connected(conn: 1)
        #expect(!s.connectionArrived(2, nowMs: 10))
        // Even a stream that slipped through is refused: the connection is not a candidate.
        #expect(s.sessionStreamOpened(2, token: token, isBidirectional: true, nowMs: 11)
            == [.rejectInBand(conn: 2), .closeConnection(conn: 2, graceMs: 5000)])
        #expect(s.state == .connected)
    }

    @Test func atMostFourConnectionsWaitForTheTokenAtOnce() {
        let s = offered()
        for conn in 1 ... 4 { #expect(s.connectionArrived(conn, nowMs: 0), "connection \(conn)") }
        #expect(!s.connectionArrived(5, nowMs: 0))
    }

    @Test func theConnectionThatAuthenticatesClosesTheOtherCandidates() {
        let s = offered()
        #expect(s.connectionArrived(1, nowMs: 0))
        #expect(s.connectionArrived(2, nowMs: 0))
        #expect(s.sessionStreamOpened(2, token: token, isBidirectional: true, nowMs: 1)
            == [.writeSession("OK"), .closeConnection(conn: 1, graceMs: 0)])
    }

    @Test func noConnectionIsAcceptedBeforeTheOffer() {
        let s = make()
        #expect(!s.connectionArrived(1, nowMs: 0))
        _ = s.receive(request(), onLan: true, nowMs: 0)
        #expect(!s.connectionArrived(1, nowMs: 0))   // listener still opening
    }

    // MARK: the clock

    @Test func anOfferNobodyAnswersExpiresAfterThirtySeconds() {
        let s = offered(at: 1000)
        #expect(s.tick(nowMs: 30_999) == [])
        #expect(s.tick(nowMs: 31_000) == [.sendAction(.end(sid: sid)), .closeListener])
        #expect(s.state == .ended(.offerTimeout))
    }

    @Test func anAuthenticatedSessionIsNotAffectedByTheOfferClock() {
        let s = connected(at: 0)
        #expect(s.tick(nowMs: 29_999) == [])
        #expect(s.state == .connected)
    }

    @Test func aSessionIdleForThirtySecondsEndsAndTellsThePeerFirst() {
        let s = connected(at: 1000)
        #expect(s.tick(nowMs: 30_999) == [])
        #expect(s.tick(nowMs: 31_000) == [
            .sendAction(.end(sid: sid)), .writeSession("END"), .closeConnection(conn: 1, graceMs: 1000), .closeListener,
        ])
        #expect(s.state == .ended(.idleTimeout))
    }

    @Test func activityRestartsTheIdleClock() {
        let s = connected(at: 0)
        s.touch(nowMs: 20_000)
        #expect(s.tick(nowMs: 49_999) == [])
        #expect(!s.tick(nowMs: 50_000).isEmpty)
    }

    @Test func theDeadlineTheHostShouldWakeUpFor() {
        let s = make()
        #expect(s.nextDeadlineMs == nil)
        _ = s.receive(request(), onLan: true, nowMs: 0)
        #expect(s.nextDeadlineMs == nil)                       // waiting for the listener, no clock yet
        _ = s.listenerReady(port: 53125, nowMs: 1000)
        #expect(s.nextDeadlineMs == 31_000)                    // the offer
        #expect(s.connectionArrived(1, nowMs: 2000))
        #expect(s.nextDeadlineMs == 7000)                      // that connection's token window
        _ = s.sessionStreamOpened(1, token: token, isBidirectional: true, nowMs: 3000)
        #expect(s.nextDeadlineMs == 33_000)                    // idle, from the last activity
        s.touch(nowMs: 10_000)
        #expect(s.nextDeadlineMs == 40_000)
        _ = s.end(.localEnded, nowMs: 11_000)
        #expect(s.nextDeadlineMs == nil)
    }

    @Test func customTimesAreHonoured() {
        var config = QuicSession.Config()
        config.tokenWindowMs = 100
        config.offerValidMs = 200
        config.idleMs = 300
        let waiting = offered(at: 0, config: config)
        #expect(waiting.connectionArrived(1, nowMs: 0))
        #expect(waiting.tick(nowMs: 99) == [])
        #expect(!waiting.tick(nowMs: 100).isEmpty)   // the token window
        #expect(waiting.tick(nowMs: 199) == [])
        #expect(!waiting.tick(nowMs: 200).isEmpty)   // the offer
        let idle = offered(at: 0, config: config)
        #expect(idle.connectionArrived(1, nowMs: 0))
        _ = idle.sessionStreamOpened(1, token: token, isBidirectional: true, nowMs: 0)
        #expect(idle.tick(nowMs: 299) == [])
        #expect(!idle.tick(nowMs: 300).isEmpty)      // the idle time
    }

    // MARK: ending

    @Test func thePeerEndingClosesWithoutEchoingTheEnd() {
        let s = connected()
        #expect(s.receive(.end(sid: sid), onLan: true, nowMs: 50) == [.closeConnection(conn: 1, graceMs: 0), .closeListener])
        #expect(s.state == .ended(.peerEnded))
    }

    @Test func endingLocallyTellsThePeerOnBothChannels() {
        let s = connected()
        #expect(s.end(.localEnded, nowMs: 50) == [
            .sendAction(.end(sid: sid)), .writeSession("END"), .closeConnection(conn: 1, graceMs: 1000), .closeListener,
        ])
        #expect(s.state == .ended(.localEnded))
    }

    @Test func endingBeforeAnyoneConnectedStillClosesTheListenerAndWaitingConnections() {
        let s = offered()
        #expect(s.connectionArrived(7, nowMs: 0))
        #expect(s.end(.localEnded, nowMs: 5) == [.sendAction(.end(sid: sid)), .closeConnection(conn: 7, graceMs: 0), .closeListener])
    }

    @Test func endingWhenThereIsNoSessionDoesNothing() {
        let s = make()
        #expect(s.end(.localEnded, nowMs: 0) == [])
        #expect(s.state == .idle)
        let done = offered()
        _ = done.end(.localEnded, nowMs: 1)
        #expect(done.end(.localEnded, nowMs: 2) == [])
    }

    @Test func aLostConnectionEndsTheSessionWithoutTellingAnyone() {
        let s = connected()
        #expect(s.connectionLost(1, nowMs: 60) == [.closeListener])
        #expect(s.state == .ended(.connectionLost))
    }

    @Test func aLostCandidateDoesNotEndTheSession() {
        let s = offered()
        #expect(s.connectionArrived(1, nowMs: 0))
        #expect(s.connectionLost(1, nowMs: 5) == [])
        #expect(s.state == .offered)
        #expect(s.nextDeadlineMs == 30_000)
    }

    @Test func aListenerThatFailsBeforeTheOfferRefusesAndAfterItEnds() {
        let early = make()
        _ = early.receive(request(), onLan: true, nowMs: 0)
        #expect(early.listenerFailed(nowMs: 1) == [.sendAction(.reject(sid: sid, reason: .busy)), .closeListener])
        #expect(early.state == .ended(.listenerFailed))
        let late = offered()
        #expect(late.listenerFailed(nowMs: 1) == [.sendAction(.end(sid: sid)), .closeListener])
        #expect(late.state == .ended(.listenerFailed))
    }

    // MARK: the link goes away (stage 1.8)

    @Test func theLinkGoingAwayWhileConnectedEndsLikeALocalEndAndTellsThePeerOnWhatIsLeft() {
        let s = connected()
        #expect(s.linkLost(nowMs: 50) == [
            .sendAction(.end(sid: sid)), .writeSession("END"), .closeConnection(conn: 1, graceMs: 1000), .closeListener,
        ])
        #expect(s.state == .ended(.linkLost))
        #expect(s.nextDeadlineMs == nil)
    }

    @Test func theLinkGoingAwayWhileOfferedClosesTheListenerAndWaitingConnections() {
        let s = offered()
        #expect(s.connectionArrived(7, nowMs: 0))
        #expect(s.linkLost(nowMs: 5) == [.sendAction(.end(sid: sid)), .closeConnection(conn: 7, graceMs: 0), .closeListener])
        #expect(s.state == .ended(.linkLost))
    }

    @Test func theLinkGoingAwayWhileTheListenerIsStillOpeningClosesIt() {
        let s = make()
        _ = s.receive(request(), onLan: true, nowMs: 0)
        #expect(s.linkLost(nowMs: 1) == [.sendAction(.end(sid: sid)), .closeListener])
        // The listener reports back later: nothing may come of it.
        #expect(s.listenerReady(port: 53125, nowMs: 2) == [])
        #expect(s.state == .ended(.linkLost))
    }

    @Test func theLinkGoingAwayWhileTheMacWaitsForTheAcceptCancelsTheRequest() {
        let s = make()
        _ = s.request(.echo, sid: sid, onLan: true, nowMs: 0)
        #expect(s.linkLost(nowMs: 5) == [.sendAction(.end(sid: sid))])
        #expect(s.state == .ended(.linkLost))
    }

    @Test func theLinkGoingAwayWithNoSessionDoesNothingAndDoesNotRepeat() {
        let s = make()
        #expect(s.linkLost(nowMs: 0) == [])
        #expect(s.state == .idle)
        let done = connected()
        _ = done.linkLost(nowMs: 1)
        #expect(done.linkLost(nowMs: 2) == [])
        let ended = connected()
        _ = ended.end(.localEnded, nowMs: 1)
        #expect(ended.linkLost(nowMs: 2) == [])
        #expect(ended.state == .ended(.localEnded))   // the first reason stays
    }

    @Test func aNewRequestIsServedAfterTheLinkCameBack() {
        let s = connected()
        _ = s.linkLost(nowMs: 5)
        #expect(s.receive(request(sid: otherSid), onLan: true, nowMs: 10) == [.openListener])
    }

    // MARK: the Mac asks (a later stage uses it; the rules are here)

    @Test func theMacAsksAndWaitsForTheAccept() {
        let s = make()
        #expect(s.localRequestRefusal(.echo, onLan: true) == nil)
        #expect(s.request(.echo, sid: sid, onLan: true, nowMs: 0) == [.sendAction(request())])
        #expect(s.state == .requested)
        #expect(s.nextDeadlineMs == 60_000)
        #expect(s.receive(.accept(sid: sid), onLan: true, nowMs: 100) == [.openListener])
        #expect(s.state == .accepted)
        #expect(s.listenerReady(port: 53125, nowMs: 110) == [.sendAction(offer(port: 53125))])
        #expect(s.state == .offered)
    }

    @Test func theMacDoesNotAskWhenItCannotBeServed() {
        let busy = offered()
        #expect(busy.localRequestRefusal(.echo, onLan: true) == .busy)
        #expect(busy.request(.echo, sid: otherSid, onLan: true, nowMs: 0) == [])
        let idle = make()
        #expect(idle.localRequestRefusal(.echo, onLan: false) == .relay)
        #expect(idle.localRequestRefusal(.cast, onLan: true) == .unsupported)
    }

    @Test func thePhoneRefusingEndsTheSessionWithItsReason() {
        let s = make()
        _ = s.request(.echo, sid: sid, onLan: true, nowMs: 0)
        #expect(s.receive(.reject(sid: sid, reason: .denied), onLan: true, nowMs: 10) == [])
        #expect(s.state == .ended(.peerRejected(.denied)))
    }

    @Test func noAcceptInSixtySecondsEndsTheRequestAndTellsThePhone() {
        let s = make()
        _ = s.request(.echo, sid: sid, onLan: true, nowMs: 1000)
        #expect(s.tick(nowMs: 60_999) == [])
        #expect(s.tick(nowMs: 61_000) == [.sendAction(.end(sid: sid))])
        #expect(s.state == .ended(.acceptTimeout))
    }

    @Test func anOfferFromThePhoneIsIgnoredWhileWaitingForTheAccept() {
        let s = make()
        _ = s.request(.echo, sid: sid, onLan: true, nowMs: 0)
        #expect(s.receive(offer(port: 53125), onLan: true, nowMs: 5) == [])
        #expect(s.state == .requested)
    }

    // MARK: helpers

    @Test func tokensTravelAsCanonicalUnpaddedBase64url() {
        #expect(QuicSession.encodeToken(token) == tokenText)
        #expect(QuicSession.encodeToken(Array(repeating: 0xFB, count: 32)) == "-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_v7-_s")
        #expect(QuicSession.encodeToken(token).count == 43)
    }

    @Test func comparingInConstantTimeStillComparesCorrectly() {
        #expect(QuicSession.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        #expect(!QuicSession.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        #expect(!QuicSession.constantTimeEqual([4, 2, 3], [1, 2, 3]))
        #expect(!QuicSession.constantTimeEqual([1, 2, 3], [1, 2]))
        #expect(!QuicSession.constantTimeEqual([], [1]))
        #expect(QuicSession.constantTimeEqual([], []))
    }

    // MARK: stream credit (stage 0.5 finding 14)

    @Test func theStreamLimitIsTheCompletedCountPlusTheHeadroom() {
        #expect(StreamCredit.limit(completed: 0, headroom: 1000) == 1000)
        #expect(StreamCredit.limit(completed: 9, headroom: 1000) == 1009)
        #expect(StreamCredit.limit(completed: 4096, headroom: 1000) == 5096)
        #expect(StreamCredit.limit(completed: 5000, headroom: 250) == 5250)
    }

    @Test func theLimitIsRaisedEveryTenCompletedStreams() {
        #expect(!StreamCredit.raiseDue(completed: 0, every: 10))
        #expect(!StreamCredit.raiseDue(completed: 9, every: 10))
        #expect(StreamCredit.raiseDue(completed: 10, every: 10))
        #expect(!StreamCredit.raiseDue(completed: 11, every: 10))
        #expect(StreamCredit.raiseDue(completed: 4090, every: 10))
        #expect(StreamCredit.raiseDue(completed: 5000, every: 10))
    }
}
