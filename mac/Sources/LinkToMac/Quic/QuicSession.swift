import Foundation

// The Mac's rules for ONE QUIC session (plan stage 1.6), as pure logic: no sockets, no timers, no Network.framework. Time comes in as
// milliseconds and randomness as a closure, so every limit is tested at its exact boundary (QuicSessionTests). The host (`QuicListener`
// + `QuicService`) feeds events in and carries out the returned effects.
//
// Why effects instead of calling the listener directly: Network.framework's QUIC server behaves in ways that took eight findings to
// pin down (stage 0.3), and none of the rules here — who may open a session, how long an unanswered offer lives, what counts as a
// wrong token — depends on them. Keeping the rules apart means they can be tested without a network.
//
//   the phone asked:  idle --q.req--> accepted (listener opening) --listener ready: q.offer--> offered --token ok--> connected --> ended
//   the Mac asked:    idle --request--> requested --q.accept--> accepted --...as above
//
// The control-phase rules (who may send what, the accept timeout) are `QuicHandshake`'s (stage 1.3); this adds what is specific to
// the server: one session at a time, the token, and the clocks after the offer.

/// What the host must do. Every effect is idempotent for the host (closing a listener that is already closed is fine).
enum QuicEffect: Equatable, Sendable {
    /// Send this `q.*` action to the phone as a `cmd` (one link, `RelayClient.sendCommand`).
    case sendAction(QuicAction)
    /// Start the UDP listener (the host picks the port: 53125, else a free one) and report it with `listenerReady(port:)`.
    case openListener
    case closeListener
    /// One line (without the newline) on the authenticated connection's session stream: `OK`, `END`.
    case writeSession(String)
    /// Refuse this connection on its session stream: `NO\n` + FIN (a uni first stream can't be answered: just cancel it).
    case rejectInBand(conn: Int)
    /// Release this connection locally after `graceMs`. Network.framework cannot make the peer see a close (stage 0.3 finding 5), so the
    /// peer is told in-band first; this only frees the Mac's own resources.
    case closeConnection(conn: Int, graceMs: Int64)
}

/// A class on purpose: the host owns exactly one, and its state is what every event reads and changes.
final class QuicSession {
    struct Config: Equatable, Sendable {
        /// Kinds this Mac serves. Anything else is refused with `unsupported`. Stage 1.6: only the debug `echo`.
        var supportedKinds: Set<QuicKind> = []
        /// From a connection's arrival to its session stream carrying the token.
        var tokenWindowMs: Int64 = 5_000
        /// How long an offer stays valid while nobody has authenticated.
        var offerValidMs: Int64 = 30_000
        /// No activity on an authenticated session for this long ends it (later stages add a real heartbeat).
        var idleMs: Int64 = 30_000
        var acceptTimeoutMs: Int64 = QuicHandshake.defaultAcceptTimeoutMs
        /// Connections that may wait for the token at once (a stranger on the LAN must not be able to lock the real phone out).
        var maxCandidates = 4
        var rejectGraceMs: Int64 = 5_000
        var endGraceMs: Int64 = 1_000
    }

    enum State: Equatable, Sendable {
        case idle, requested, accepted, offered, connected
        case ended(End)
    }

    enum End: Equatable, Sendable {
        case peerEnded
        case peerRejected(QuicRejectReason)
        case localEnded
        case acceptTimeout
        case offerTimeout
        case idleTimeout
        case connectionLost
        case listenerFailed
        /// The LAN-direct link to the phone went away (stage 1.8): a session needs it, so the session ends.
        case linkLost

        /// Whether the peer still has to be told (it is the side that does not know yet).
        fileprivate var tellsPeer: Bool {
            switch self {
            case .localEnded, .acceptTimeout, .offerTimeout, .idleTimeout, .listenerFailed, .linkLost: return true
            case .peerEnded, .peerRejected, .connectionLost: return false
            }
        }
    }

    private(set) var state: State = .idle
    let config: Config
    private let fingerprint: String
    private let makeToken: () -> [UInt8]?

    private var handshake: QuicHandshake?
    private var sid = ""
    private var token: [UInt8] = []
    private var listenerWanted = false
    private var offerDeadlineMs: Int64?
    private var candidates: [Int: Int64] = [:]     // connection -> the end of its token window
    private var authenticated: Int?
    private var lastActivityMs: Int64 = 0

    /// `fingerprint`: the 64 lower-case hex of the Mac's QUIC certificate (what the phone pins). `makeToken`: 32 fresh random bytes
    /// (nil if the system random source failed).
    init(config: Config = Config(), fingerprint: String, makeToken: @escaping () -> [UInt8]?) {
        self.config = config
        self.fingerprint = fingerprint
        self.makeToken = makeToken
    }

    private var isActive: Bool {
        switch state {
        case .requested, .accepted, .offered, .connected: return true
        case .idle, .ended: return false
        }
    }

    // MARK: control actions

    /// An action from the phone (it arrived over the E2E `cmd` path). `onLan`: the phone is connected to us over the LAN (a QUIC
    /// session needs the same network).
    func receive(_ action: QuicAction, onLan: Bool, nowMs: Int64) -> [QuicEffect] {
        let out = tick(nowMs: nowMs)
        if case let .request(requestSid, kind) = action {
            if isActive, requestSid.lowercased() == sid { return out }   // the same request delivered twice
            if let reason = QuicGate.refusal(active: isActive, onLan: onLan, kindSupported: config.supportedKinds.contains(kind)) {
                return out + [.sendAction(.reject(sid: requestSid, reason: reason))]
            }
            begin(sid: requestSid, asker: false, nowMs: nowMs)
            state = .accepted
            listenerWanted = true
            return out + [.openListener]
        }
        guard isActive, var hs = handshake else { return out }
        let verdict = hs.receive(action, nowMs: nowMs)
        handshake = hs
        guard case let .applied(phase) = verdict else { return out }
        switch phase {
        case .closed(.ended): return out + finish(.peerEnded)
        case let .closed(.rejected(reason)): return out + finish(.peerRejected(reason))
        case .closed(.timedOut): return out + finish(.acceptTimeout)
        case .mayOffer:                                       // the phone accepted the Mac's request
            state = .accepted
            listenerWanted = true
            return out + [.openListener]
        default: return out
        }
    }

    /// Why a request of our own could not be made right now, or nil.
    func localRequestRefusal(_ kind: QuicKind, onLan: Bool) -> QuicRejectReason? {
        QuicGate.refusal(active: isActive, onLan: onLan, kindSupported: config.supportedKinds.contains(kind))
    }

    /// The Mac asks the phone for a session (a later stage uses it). Nothing happens when it cannot be made (`localRequestRefusal`).
    func request(_ kind: QuicKind, sid requestSid: String, onLan: Bool, nowMs: Int64) -> [QuicEffect] {
        guard localRequestRefusal(kind, onLan: onLan) == nil else { return [] }
        begin(sid: requestSid, asker: true, nowMs: nowMs)
        state = .requested
        return [.sendAction(.request(sid: sid, kind: kind))]
    }

    private func begin(sid requestSid: String, asker: Bool, nowMs: Int64) {
        sid = requestSid.lowercased()
        handshake = QuicHandshake(side: .mac, iRequested: asker, sid: sid, nowMs: nowMs, acceptTimeoutMs: config.acceptTimeoutMs)
        token = []
        offerDeadlineMs = nil
        candidates = [:]
        authenticated = nil
        lastActivityMs = nowMs
    }

    // MARK: listener and connections

    /// The listener is up on `port`: offer the session.
    func listenerReady(port: Int, nowMs: Int64) -> [QuicEffect] {
        let out = tick(nowMs: nowMs)
        guard state == .accepted, var hs = handshake else { return out }
        guard let fresh = makeToken(), fresh.count == 32 else {
            return out + finish(.listenerFailed, refusing: .busy)
        }
        let offer = QuicOffer(sid: sid, port: port, fp: fingerprint, tok: Self.encodeToken(fresh))
        guard case .applied = hs.send(.offer(offer), nowMs: nowMs) else { return out }
        handshake = hs
        token = fresh
        state = .offered
        offerDeadlineMs = nowMs + config.offerValidMs
        return out + [.sendAction(.offer(offer))]
    }

    /// The listener could not start or died.
    func listenerFailed(nowMs: Int64) -> [QuicEffect] {
        let out = tick(nowMs: nowMs)
        guard isActive else { return out }
        if state == .accepted { return out + finish(.listenerFailed, refusing: .busy) }
        return out + finish(.listenerFailed)
    }

    /// A QUIC connection reached the listener. True: let it wait for the token. False: close it now.
    func connectionArrived(_ conn: Int, nowMs: Int64) -> Bool {
        guard state == .offered, authenticated == nil, candidates[conn] == nil, candidates.count < config.maxCandidates else { return false }
        candidates[conn] = nowMs + config.tokenWindowMs
        return true
    }

    /// The first stream of `conn` delivered its first bytes. The session stream must be bidirectional (the Mac answers on it) and start
    /// with exactly the 32 token bytes; the comparison does not stop at the first difference.
    func sessionStreamOpened(_ conn: Int, token presented: [UInt8], isBidirectional: Bool, nowMs: Int64) -> [QuicEffect] {
        let out = tick(nowMs: nowMs)
        guard state == .offered, candidates[conn] != nil else { return out + refuse(conn) }
        candidates[conn] = nil
        guard isBidirectional, Self.constantTimeEqual(presented, token) else { return out + refuse(conn) }
        authenticated = conn
        state = .connected
        offerDeadlineMs = nil
        lastActivityMs = nowMs
        var effects: [QuicEffect] = [.writeSession("OK")]
        for other in candidates.keys.sorted() { effects.append(.closeConnection(conn: other, graceMs: 0)) }
        candidates = [:]
        return out + effects
    }

    /// Bytes, a stream or a datagram moved on the authenticated session.
    func touch(nowMs: Int64) {
        if state == .connected { lastActivityMs = nowMs }
    }

    func connectionLost(_ conn: Int, nowMs: Int64) -> [QuicEffect] {
        let out = tick(nowMs: nowMs)
        if conn == authenticated {
            authenticated = nil
            return out + finish(.connectionLost)
        }
        candidates[conn] = nil
        return out
    }

    /// The Mac ends the session (the user, Unpair, the phone's link going away). The peer is told first, in both channels.
    func end(_ reason: End, nowMs: Int64) -> [QuicEffect] {
        let out = tick(nowMs: nowMs)
        guard isActive else { return out }
        return out + finish(reason)
    }

    /// The LAN-direct link to the phone is gone. The peer is still told, best effort, over whatever link is left (`q.end` goes out through
    /// `RelayClient.sendCommand`, which uses the relay when the LAN is down and does nothing when there is no link at all).
    func linkLost(nowMs: Int64) -> [QuicEffect] { end(.linkLost, nowMs: nowMs) }

    // MARK: the clock

    /// When the host should call `tick` next (nil: nothing is waiting on a clock).
    var nextDeadlineMs: Int64? {
        switch state {
        case .requested:
            if case let .awaitingAccept(deadline)? = handshake?.phase { return deadline }
            return nil
        case .offered:
            return ([offerDeadlineMs].compactMap { $0 } + candidates.values).min()
        case .connected:
            return lastActivityMs + config.idleMs
        case .idle, .accepted, .ended:
            return nil
        }
    }

    /// Applies every limit that has passed (`now >= deadline`); each one is reported once.
    func tick(nowMs: Int64) -> [QuicEffect] {
        switch state {
        case .idle, .accepted, .ended:
            return []
        case .requested:
            guard var hs = handshake else { return [] }
            hs.tick(nowMs: nowMs)
            handshake = hs
            if case .closed(.timedOut) = hs.phase { return finish(.acceptTimeout) }
            return []
        case .offered:
            var out: [QuicEffect] = []
            for (conn, deadline) in candidates.sorted(by: { $0.key < $1.key }) where nowMs >= deadline {
                out += [.rejectInBand(conn: conn), .closeConnection(conn: conn, graceMs: 0)]
                candidates[conn] = nil
            }
            if let deadline = offerDeadlineMs, nowMs >= deadline { out += finish(.offerTimeout) }
            return out
        case .connected:
            return nowMs >= lastActivityMs + config.idleMs ? finish(.idleTimeout) : []
        }
    }

    // MARK: endings

    private func refuse(_ conn: Int) -> [QuicEffect] {
        [.rejectInBand(conn: conn), .closeConnection(conn: conn, graceMs: config.rejectGraceMs)]
    }

    /// Ends the session. `refusing`: the phone's request was never served, so it gets a `q.reject` instead of a `q.end`.
    private func finish(_ reason: End, refusing: QuicRejectReason? = nil) -> [QuicEffect] {
        var out: [QuicEffect] = []
        if let refusing {
            out.append(.sendAction(.reject(sid: sid, reason: refusing)))
        } else if reason.tellsPeer {
            out.append(.sendAction(.end(sid: sid)))
        }
        if let conn = authenticated {
            if reason.tellsPeer && refusing == nil {
                out.append(.writeSession("END"))
                out.append(.closeConnection(conn: conn, graceMs: config.endGraceMs))
            } else {
                out.append(.closeConnection(conn: conn, graceMs: 0))
            }
        }
        for conn in candidates.keys.sorted() { out.append(.closeConnection(conn: conn, graceMs: 0)) }
        if listenerWanted { out.append(.closeListener) }
        listenerWanted = false
        authenticated = nil
        candidates = [:]
        offerDeadlineMs = nil
        state = .ended(reason)
        return out
    }

    // MARK: helpers

    /// The token as it travels in `q.offer`: unpadded base64url (32 bytes make exactly 43 characters).
    static func encodeToken(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares without stopping at the first difference, so how long it takes says nothing about how much of a guess was right.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for i in 0 ..< min(a.count, b.count) { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

/// Network.framework never hands out new stream credit by itself (stage 0.5 finding 14): with a limit of N the sender stalls after
/// exactly N streams even if every one was read and released, and a huge initial limit is clipped at 4096. So the receiver keeps
/// raising the limit as streams finish: every `every` completed streams, to `completed + headroom`.
enum StreamCredit {
    static let headroom = 1000
    static let every = 10

    static func limit(completed: Int, headroom: Int = StreamCredit.headroom) -> Int { completed + headroom }

    static func raiseDue(completed: Int, every: Int = StreamCredit.every) -> Bool { completed > 0 && completed % every == 0 }
}
