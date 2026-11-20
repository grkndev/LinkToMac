import Foundation
import Network
import os
import Security

// The Mac's QUIC server (plan stage 1.6): Network.framework glue (`QuicListener`) and the driver that joins it to the pure rules
// (`QuicServer` + `QuicSession`).
//
// Everything below is shaped by what stages 0.3–0.5 measured; none of it is obvious from the API:
//  - the listener gets ONLY `newConnectionGroupHandler` (setting `newConnectionHandler` too makes it fail to start with EINVAL);
//    streams arrive through `group.newConnectionHandler`, and a stream's identifier is readable once it is `.ready`;
//  - `group.cancel()` does NOT make the peer see the connection close (it still looked open 45 s later), so a refusal or an end
//    is said in-band first (`NO\n` / `END\n` on the session stream) and the peer closes by itself; our own cancel only frees our side;
//  - datagrams come from `group.extract(connectionTo:using:)` with an `isDatagram` option, read with `receiveMessage`; the group-level
//    `send(content:to:message:)` / `setReceiveHandler` pair silently loses every packet;
//  - Network.framework never hands out new stream credit, so the limit is raised by hand as streams finish (`StreamCredit`), and every
//    finished stream must be `cancel()`led or its memory is never released.
//
// Logging: states and fixed words only. Never a token, fingerprint, port, session id or address.

private let quicLog = Logger(subsystem: "dev.grkn.LinkToMac", category: "quic")

/// Called on the listener's queue.
protocol QuicListenerDelegate: AnyObject {
    func quicListenerReady(port: Int)
    func quicListenerFailed()
    /// A QUIC connection reached the listener. False: it is closed at once.
    func quicConnectionArrived(_ conn: Int) -> Bool
    /// The first stream of `conn` produced its first bytes (up to 32 of them: the token).
    func quicSessionStream(_ conn: Int, token: [UInt8], isBidirectional: Bool)
    func quicConnectionLost(_ conn: Int)
    /// Bytes, a stream or a datagram moved on the authenticated session.
    func quicActivity()
    /// A complete line on the authenticated session stream.
    func quicSessionLine(_ conn: Int, _ line: String)
    func quicDatagram(_ conn: Int, _ data: Data)
}

final class QuicListener: @unchecked Sendable {
    struct Options: Sendable {
        /// Tried first; if the port is taken a free one is used and reported with the offer. 0 = any.
        var preferredPort: UInt16 = 53125
        /// Also the headroom of the credit raised as streams finish (`StreamCredit.limit`).
        var initialMaxStreamsUnidirectional = StreamCredit.headroom
        var initialMaxStreamsBidirectional = 100
        /// Off only to show what happens without it (stage 0.5 finding 14).
        var raiseStreamCredit = true
        /// Sets up the DATAGRAM flow of each authenticated connection (the debug echo; later the audio).
        var datagrams = false
    }

    /// One accepted connection group.
    private final class Peer: @unchecked Sendable {
        let id: Int
        let group: NWConnectionGroup
        var firstStream: NWConnection?
        var firstStreamIsBidirectional = false
        var sessionStream: NWConnection?
        var authenticated = false
        var gone = false
        var completedUni = 0
        var completedBi = 0
        var datagramFlow: NWConnection?
        /// Every stream connection that is not finished yet (cancelled together with the group: see `release`).
        var openStreams: [ObjectIdentifier: NWConnection] = [:]
        init(id: Int, group: NWConnectionGroup) {
            self.id = id
            self.group = group
        }
    }

    private enum Role { case pending, sessionCandidate, session, data, refused }

    /// The per-stream reading state, owned by that stream's receive loop.
    private final class StreamState: @unchecked Sendable {
        let conn: NWConnection
        var role: Role
        var isBidirectional = true
        var buffer = Data()
        var channelKnown = false
        var started = false
        var finished = false
        init(conn: NWConnection, role: Role) {
            self.conn = conn
            self.role = role
        }
    }

    private let queue: DispatchQueue
    private let identity: QuicIdentity
    private let options: Options
    weak var delegate: QuicListenerDelegate?

    private var listener: NWListener?
    private var announcedPort = false
    private var triedAnyPort = false
    private var peers: [Int: Peer] = [:]
    private var nextConnectionID = 1

    init(identity: QuicIdentity, options: Options = Options(), queue: DispatchQueue) {
        self.identity = identity
        self.options = options
        self.queue = queue
    }

    // Every method below must be called on `queue`.

    func start() {
        stop()
        triedAnyPort = false
        startListener(port: options.preferredPort)
    }

    /// Stops accepting new connections. Connections already open stay until they are closed with `close`.
    func stop() {
        listener?.cancel()
        listener = nil
        announcedPort = false
    }

    func markAuthenticated(_ conn: Int) {
        guard let peer = peers[conn] else { return }
        peer.authenticated = true
        peer.sessionStream = peer.firstStream
        if options.datagrams { setUpDatagrams(peer) }
    }

    /// One line (the newline is added) on the authenticated connection's session stream.
    func writeSession(_ line: String) {
        guard let stream = peers.values.first(where: { $0.authenticated })?.sessionStream else { return }
        stream.send(content: Data((line + "\n").utf8), contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { error in
            if error != nil { quicLog.error("session write failed") }
        })
    }

    /// Refuses the connection on its first stream: `NO\n` + FIN, or a cancel if that stream cannot be answered.
    func rejectInBand(_ conn: Int) {
        guard let peer = peers[conn], let stream = peer.firstStream else { return }
        if peer.firstStreamIsBidirectional {
            stream.send(content: Data("NO\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        } else {
            stream.cancel()
        }
    }

    /// Frees our side of the connection after `afterMs` (the peer closes by itself once it has been told in-band).
    func close(_ conn: Int, afterMs: Int64) {
        guard let peer = peers[conn] else { return }
        if afterMs <= 0 {
            release(peer)
        } else {
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(afterMs))) { [weak self, weak peer] in
                if let self, let peer { self.release(peer) }
            }
        }
    }

    /// Frees our side of a connection: its streams and datagram flow first, then the group.
    private func release(_ peer: Peer) {
        for stream in peer.openStreams.values { stream.cancel() }
        peer.openStreams.removeAll()
        peer.datagramFlow?.cancel()
        peer.group.cancel()
    }

    func sendDatagram(_ conn: Int, _ data: Data) {
        guard let flow = peers[conn]?.datagramFlow else { return }
        flow.send(content: data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Finished uni streams of this connection (the debug `COUNT` answer).
    func completedUniStreams(_ conn: Int) -> Int { peers[conn]?.completedUni ?? 0 }

    // MARK: listener

    private func makeParameters() -> NWParameters? {
        let quic = NWProtocolQUIC.Options(alpn: [QuicControl.alpn])
        let security = quic.securityProtocolOptions
        guard let secIdentity = sec_identity_create(identity.identity) else { return nil }
        sec_protocol_options_set_local_identity(security, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        quic.idleTimeout = 30_000
        quic.initialMaxData = 32 * 1024 * 1024
        quic.initialMaxStreamDataBidirectionalLocal = 8 * 1024 * 1024
        quic.initialMaxStreamDataBidirectionalRemote = 8 * 1024 * 1024
        quic.initialMaxStreamDataUnidirectional = 8 * 1024 * 1024
        quic.initialMaxStreamsBidirectional = options.initialMaxStreamsBidirectional
        quic.initialMaxStreamsUnidirectional = options.initialMaxStreamsUnidirectional
        if options.datagrams { quic.maxDatagramFrameSize = 1200 }
        return NWParameters(quic: quic)
    }

    private func startListener(port: UInt16) {
        let nwPort = port == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: port) ?? .any)
        guard let parameters = makeParameters(), let created = try? NWListener(using: parameters, on: nwPort) else {
            quicLog.error("listener could not be created")
            delegate?.quicListenerFailed()
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self, let created, self.listener === created else { return }
            switch state {
            case .ready:
                guard !self.announcedPort, let bound = created.port?.rawValue else { return }
                self.announcedPort = true
                quicLog.info("listener ready")
                self.delegate?.quicListenerReady(port: Int(bound))
            case let .failed(error):
                if port != 0, !self.triedAnyPort, case .posix(.EADDRINUSE) = error {
                    quicLog.info("preferred port busy, using a free one")
                    self.triedAnyPort = true
                    created.cancel()
                    self.listener = nil
                    self.startListener(port: 0)
                } else {
                    quicLog.error("listener failed")
                    self.listener = nil
                    self.delegate?.quicListenerFailed()
                }
            default:
                break
            }
        }
        // ONLY the group handler: assigning `newConnectionHandler` as well makes the listener fail with EINVAL (stage 0.3 finding 1).
        created.newConnectionGroupHandler = { [weak self] group in self?.accept(group) }
        created.start(queue: queue)
    }

    // MARK: connections

    private func accept(_ group: NWConnectionGroup) {
        let id = nextConnectionID
        nextConnectionID += 1
        guard delegate?.quicConnectionArrived(id) == true else {
            quicLog.info("connection refused")
            group.cancel()
            return
        }
        let peer = Peer(id: id, group: group)
        peers[id] = peer
        group.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.gone(peer)   // `failed(EINVAL)` is how a closed connection looks (stage 0.3 finding 2)
            default: break
            }
        }
        group.newConnectionHandler = { [weak self] stream in self?.accept(stream, of: peer) }
        group.start(queue: queue)
    }

    private func gone(_ peer: Peer) {
        guard !peer.gone else { return }
        peer.gone = true
        peers[peer.id] = nil
        peer.datagramFlow?.cancel()
        delegate?.quicConnectionLost(peer.id)
    }

    // MARK: streams

    private func accept(_ stream: NWConnection, of peer: Peer) {
        // What this "connection" is, and so its role, is only known once it is `.ready` (its metadata is not readable before).
        let state = StreamState(conn: stream, role: .pending)
        peer.openStreams[ObjectIdentifier(stream)] = stream
        stream.stateUpdateHandler = { [weak self] connState in
            switch connState {
            case .ready:
                guard !state.started, !state.finished else { return }
                state.started = true
                self?.streamReady(state, of: peer)
            case .failed:
                self?.finish(state, of: peer)
            default:
                break
            }
        }
        stream.start(queue: queue)
    }

    private func streamReady(_ state: StreamState, of peer: Peer) {
        let meta = state.conn.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
        // A datagram that arrives while no datagram flow is attached surfaces here as a "connection" too, with stream identifier 0 like the
        // session stream (stage 1.6 finding): only its datagram frame size gives it away. It is never a stream, so it must neither become
        // the session candidate nor be answered (a refusal written to it would go back as a datagram).
        if (meta?.usableDatagramFrameSize ?? 0) > 0 {
            state.finished = true
            state.conn.cancel()
            return
        }
        // Client-initiated streams count 0,4,8… (bidi) and 2,6,10… (uni): bit 1 of the identifier is the direction.
        state.isBidirectional = meta.map { ($0.streamIdentifier & 0x2) == 0 } ?? true
        // The first stream of a connection is the session candidate; before authentication nothing else is served; after it every
        // other stream is a data stream.
        if peer.authenticated {
            state.role = .data
        } else if peer.firstStream == nil {
            state.role = .sessionCandidate
            peer.firstStream = state.conn
            peer.firstStreamIsBidirectional = state.isBidirectional
        } else {
            state.finished = true
            state.conn.cancel()
            return
        }
        receive(state, of: peer)
    }

    private func receive(_ state: StreamState, of peer: Peer) {
        state.conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !state.finished else { return }
            if let data, !data.isEmpty {
                state.buffer.append(data)
                if peer.authenticated { self.delegate?.quicActivity() }
            }
            let ended = isComplete || error != nil
            self.process(state, of: peer, ended: ended)
            if !ended, !state.finished { self.receive(state, of: peer) }
        }
    }

    private func process(_ state: StreamState, of peer: Peer, ended: Bool) {
        switch state.role {
        case .sessionCandidate:
            guard state.buffer.count >= 32 || ended else { return }
            let token = [UInt8](state.buffer.prefix(32))
            state.buffer.removeFirst(min(32, state.buffer.count))
            state.role = .refused   // until the session accepts it (markAuthenticated flips the peer, below)
            delegate?.quicSessionStream(peer.id, token: token, isBidirectional: state.isBidirectional)
            if peer.authenticated, peer.firstStream === state.conn {
                state.role = .session
                drainLines(state, of: peer)
            } else {
                state.finished = true   // refused: the in-band `NO` was written by the delegate's effect; stop reading this stream
            }
        case .session:
            drainLines(state, of: peer)
            if ended { state.finished = true }
        case .data:
            drainData(state, of: peer, ended: ended)
        case .pending, .refused:
            state.finished = true
        }
    }

    private func drainLines(_ state: StreamState, of peer: Peer) {
        while let newline = state.buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: state.buffer[..<newline], as: UTF8.self)
            state.buffer.removeSubrange(...newline)
            delegate?.quicSessionLine(peer.id, line)
        }
    }

    private func drainData(_ state: StreamState, of peer: Peer, ended: Bool) {
        if !state.channelKnown, !state.buffer.isEmpty {
            switch QuicChannel.parse([UInt8](state.buffer.prefix(8))) {
            case .needMoreBytes:
                if !ended { return }
                finish(state, of: peer)
                return
            case .unknown:
                quicLog.info("stream with an unknown channel cancelled")
                finish(state, of: peer)
                return
            case let .channel(_, consumed):
                state.channelKnown = true
                state.buffer.removeFirst(consumed)
            }
        }
        // No handler exists yet (the real ones come with the file, screen and camera stages): the body is read to the end and dropped.
        state.buffer.removeAll(keepingCapacity: true)
        if ended { finish(state, of: peer) }
    }

    /// A data stream is done: release it and keep the peer's stream credit ahead of what it opens.
    private func finish(_ state: StreamState, of peer: Peer) {
        guard !state.finished else { return }
        state.finished = true
        peer.openStreams[ObjectIdentifier(state.conn)] = nil
        state.conn.cancel()   // without this Network.framework keeps every finished stream alive (stage 0.5 finding 15)
        guard state.role == .data else { return }   // the session stream and refused streams spend no credit that must be renewed
        let completed: Int
        if state.isBidirectional {
            peer.completedBi += 1
            completed = peer.completedBi
        } else {
            peer.completedUni += 1
            completed = peer.completedUni
        }
        guard options.raiseStreamCredit, StreamCredit.raiseDue(completed: completed),
              let meta = peer.group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else { return }
        if state.isBidirectional {
            meta.localMaxStreamsBidirectional = StreamCredit.limit(completed: completed, headroom: options.initialMaxStreamsBidirectional)
        } else {
            meta.localMaxStreamsUnidirectional = StreamCredit.limit(completed: completed, headroom: options.initialMaxStreamsUnidirectional)
        }
    }

    // MARK: datagrams

    private func setUpDatagrams(_ peer: Peer) {
        guard peer.datagramFlow == nil else { return }
        let datagram = NWProtocolQUIC.Options(alpn: [QuicControl.alpn])
        datagram.isDatagram = true
        datagram.maxDatagramFrameSize = 1200
        guard let flow = peer.group.extract(connectionTo: nil, using: datagram) else {
            quicLog.error("datagram flow unavailable")
            return
        }
        peer.datagramFlow = flow
        flow.start(queue: queue)
        receiveDatagrams(flow, of: peer)
    }

    private func receiveDatagrams(_ flow: NWConnection, of peer: Peer) {
        flow.receiveMessage { [weak self] data, _, _, error in
            guard let self, !peer.gone, error == nil else { return }   // a closed connection ends the flow with ENOTCONN: stop quietly
            if let data, !data.isEmpty, peer.authenticated {
                self.delegate?.quicActivity()
                self.delegate?.quicDatagram(peer.id, data)
            }
            if data != nil { self.receiveDatagrams(flow, of: peer) }
        }
    }
}

// MARK: - the driver

/// Joins the pure rules (`QuicSession`) to the listener: feeds events in, carries the effects out, and keeps the clock.
/// All of it runs on one serial queue; the public entry points hop onto it.
final class QuicServer: QuicListenerDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private let session: QuicSession
    private let listener: QuicListener
    private let send: @Sendable (QuicAction) -> Void
    private let now: @Sendable () -> Int64
    private var timer: DispatchSourceTimer?

    /// `send` delivers a `q.*` action to the phone (it is called on this server's queue).
    init(identity: QuicIdentity,
         config: QuicSession.Config,
         options: QuicListener.Options = QuicListener.Options(),
         queue: DispatchQueue = DispatchQueue(label: "dev.grkn.LinkToMac.quic"),
         now: @escaping @Sendable () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
         makeToken: @escaping () -> [UInt8]? = QuicServer.randomToken,
         send: @escaping @Sendable (QuicAction) -> Void) {
        self.queue = queue
        self.now = now
        self.send = send
        session = QuicSession(config: config, fingerprint: identity.fingerprint, makeToken: makeToken)
        var effective = options
        effective.datagrams = effective.datagrams || config.supportedKinds.contains(.echo)
        listener = QuicListener(identity: identity, options: effective, queue: queue)
        listener.delegate = self
        #if DEBUG
        // Also the marker `scripts/quic-it.sh --release` looks for: this sentence exists in a Debug binary only.
        if config.supportedKinds.contains(.echo) { quicLog.info("debug echo kind is enabled") }
        #endif
    }

    static func randomToken() -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 32)
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess ? bytes : nil
    }

    /// An action from the phone. `onLan`: the phone is connected over the LAN.
    func receive(_ action: QuicAction, onLan: Bool) {
        queue.async { [self] in perform(session.receive(action, onLan: onLan, nowMs: now())) }
    }

    /// The Mac ends the session (the user, Unpair, the phone's link going away).
    func end() {
        queue.async { [self] in perform(session.end(.localEnded, nowMs: now())) }
    }

    /// The LAN-direct link to the phone went away: the session ends and the listener closes.
    func linkLost() {
        queue.async { [self] in perform(session.linkLost(nowMs: now())) }
    }

    func state(_ completion: @escaping @Sendable (QuicSession.State) -> Void) {
        queue.async { [self] in completion(session.state) }
    }

    // MARK: effects

    private func perform(_ effects: [QuicEffect]) {
        for effect in effects {
            switch effect {
            case let .sendAction(action): send(action)
            case .openListener: listener.start()
            case .closeListener: listener.stop()
            case let .writeSession(line): listener.writeSession(line)
            case let .rejectInBand(conn): listener.rejectInBand(conn)
            case let .closeConnection(conn, grace): listener.close(conn, afterMs: grace)
            }
        }
        reschedule()
    }

    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard let deadline = session.nextDeadlineMs else { return }
        let delay = max(0, deadline - now())
        let fresh = DispatchSource.makeTimerSource(queue: queue)
        fresh.schedule(deadline: .now() + .milliseconds(Int(delay)))
        fresh.setEventHandler { [weak self] in
            guard let self else { return }
            perform(session.tick(nowMs: now()))
        }
        fresh.resume()
        timer = fresh
    }

    // MARK: QuicListenerDelegate

    func quicListenerReady(port: Int) { perform(session.listenerReady(port: port, nowMs: now())) }

    func quicListenerFailed() { perform(session.listenerFailed(nowMs: now())) }

    func quicConnectionArrived(_ conn: Int) -> Bool {
        let accepted = session.connectionArrived(conn, nowMs: now())
        reschedule()
        return accepted
    }

    func quicSessionStream(_ conn: Int, token: [UInt8], isBidirectional: Bool) {
        let effects = session.sessionStreamOpened(conn, token: token, isBidirectional: isBidirectional, nowMs: now())
        // The peer must be marked before `OK` is written: `writeSession` goes to the authenticated connection.
        if session.state == .connected { listener.markAuthenticated(conn) }
        perform(effects)
    }

    func quicConnectionLost(_ conn: Int) { perform(session.connectionLost(conn, nowMs: now())) }

    func quicActivity() { session.touch(nowMs: now()) }

    func quicSessionLine(_ conn: Int, _ line: String) {
        session.touch(nowMs: now())
        #if DEBUG
        // The debug `echo` kind: every line comes back; `COUNT` reports how many uni streams the Mac has read to the end.
        if session.config.supportedKinds.contains(.echo) {
            listener.writeSession(line == "COUNT" ? "COUNT \(listener.completedUniStreams(conn))" : line)
        }
        #endif
    }

    func quicDatagram(_ conn: Int, _ data: Data) {
        session.touch(nowMs: now())
        #if DEBUG
        if session.config.supportedKinds.contains(.echo) { listener.sendDatagram(conn, data) }
        #endif
    }
}
