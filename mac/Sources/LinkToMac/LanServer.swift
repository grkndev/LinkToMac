import Foundation
import Network
import CryptoKit

/// Relay-less **LAN-direct** transport: the Mac is the WebSocket *server* and the phone
/// connects straight to it over the local network (no relay, no TLS). It advertises itself
/// over Bonjour (`_linktomac._tcp`) so the phone can find it after a DHCP address change.
///
/// Security without TLS:
///  - Every content frame is still E2E-encrypted with the pairing key (`ClipCodec`,
///    ChaCha20-Poly1305) — exactly like the relay path — so a LAN sniffer learns nothing and
///    can't forge a `clip`/`cmd`.
///  - A **challenge-response handshake** gates the socket: on connect the Mac sends a random
///    `nonce`; the phone must reply with `HMAC-SHA256(key, nonce)`. Unauthenticated sockets are
///    dropped, so a stranger on the LAN can't occupy the peer slot.
///
/// Concurrency: this is **not** `@MainActor`. All Network.framework objects and mutable state
/// live on a private serial `queue` (which sidesteps the `NWConnection`/Swift-6 `Sendable`
/// friction). Inbound clips/commands are handed back through `@Sendable` callbacks that the
/// owner marshals to the main actor (the pasteboard write + screen lock run there).
final class LanServer: @unchecked Sendable {
    /// Default LAN WebSocket port. Distinct from the daemon's 53123 localhost bridge.
    static let defaultPort: UInt16 = 53124
    static let serviceType = "_linktomac._tcp"

    /// Called (off the main actor) with a decrypted clip received from the phone.
    var onRemoteClip: (@Sendable (String) -> Void)?
    /// Called (off the main actor) with a decrypted remote action (e.g. "lock").
    var onRemoteCommand: (@Sendable (String) -> Void)?
    /// Called when the authenticated peer connects/disconnects (for UI/status aggregation).
    var onPeerChange: (@Sendable (Bool) -> Void)?

    private let port: UInt16
    /// Re-read on every handshake so an unpair (fresh key/room) is picked up without a restart.
    private let pairingProvider: @Sendable () -> Pairing?

    private let queue = DispatchQueue(label: "dev.grkn.LinkToMac.lan")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var authed = false
    private var challenge: Data?
    private var running = false

    init(port: UInt16 = LanServer.defaultPort, pairingProvider: @escaping @Sendable () -> Pairing?) {
        self.port = port
        self.pairingProvider = pairingProvider
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startListener()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            connection?.cancel()
            connection = nil
            authed = false
            listener?.cancel()
            listener = nil
        }
    }

    /// Restart to re-advertise under a (possibly) new pairing-derived service id after a re-pair.
    func reload() {
        queue.async { [self] in
            guard running else { return }
            connection?.cancel()
            connection = nil
            authed = false
            listener?.cancel()
            listener = nil
            startListener()
        }
    }

    private func startListener() {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options(.version13)
        ws.autoReplyPing = true // answer the phone's keepalive pings at the protocol layer
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            log("failed to create listener on :\(port)")
            return
        }
        listener.service = NWListener.Service(
            type: LanServer.serviceType,
            txtRecord: txtRecord()
        )
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log("listening on :\(self?.port ?? 0), advertising \(LanServer.serviceType)")
            case let .failed(error): self?.log("listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Bonjour TXT: `rid` lets the phone pick *its* paired Mac on a multi-Mac LAN; `name` is shown in UI.
    private func txtRecord() -> NWTXTRecord {
        var txt = NWTXTRecord()
        if let room = pairingProvider()?.room { txt["rid"] = LanServer.serviceId(room: room) }
        txt["name"] = Host.current().localizedName ?? "Mac"
        return txt
    }

    /// Stable per-pairing id = base64url(SHA256(room))[:16]. The phone derives the same from its
    /// stored room and only connects to a matching advertisement.
    static func serviceId(room: String) -> String {
        let digest = SHA256.hash(data: Data(room.utf8))
        let b64 = Data(digest).base64EncodedString()
        let urlSafe = b64.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return String(urlSafe.prefix(16))
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        // Single peer, newest-wins: a fresh connection replaces a stale one.
        connection?.cancel()
        connection = conn
        authed = false
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.sendHello(conn)
            case .failed, .cancelled: self.dropIfCurrent(conn)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func dropIfCurrent(_ conn: NWConnection) {
        guard conn === connection else { return }
        connection = nil
        if authed { onPeerChange?(false) }
        authed = false
    }

    private func sendHello(_ conn: NWConnection) {
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        challenge = nonce
        send(["t": "hello", "nonce": nonce.base64EncodedString()], on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if error != nil { self.dropIfCurrent(conn); return }
            let isText = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode == .text
            if isText, let data = content { self.handle(data, on: conn) }
            // Keep receiving while this connection is the live one.
            if conn === self.connection { self.receive(on: conn) }
        }
    }

    private func handle(_ data: Data, on conn: NWConnection) {
        guard conn === connection,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = obj["t"] as? String else { return }

        switch t {
        case "auth":
            verifyAuth(proof: obj["proof"] as? String, on: conn)
        case "clip":
            guard authed, let key = pairingProvider()?.key,
                  let nonce = obj["nonce"] as? String, let ct = obj["ct"] as? String,
                  let text = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: key) else { return }
            onRemoteClip?(text)
        case "cmd":
            guard authed, let key = pairingProvider()?.key,
                  let nonce = obj["nonce"] as? String, let ct = obj["ct"] as? String,
                  let action = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: key) else { return }
            onRemoteCommand?(action)
        case "ping":
            if authed { send(["t": "pong"], on: conn) }
        default:
            break
        }
    }

    private func verifyAuth(proof: String?, on conn: NWConnection) {
        guard let proof, let proofData = Data(base64Encoded: proof),
              let nonce = challenge, let keyB64 = pairingProvider()?.key,
              let keyData = Data(base64Encoded: keyB64), keyData.count == 32 else {
            log("auth rejected (malformed)"); conn.cancel(); return
        }
        let key = SymmetricKey(data: keyData)
        // Constant-time verification.
        guard HMAC<SHA256>.isValidAuthenticationCode(proofData, authenticating: nonce, using: key) else {
            log("auth rejected (bad proof)"); conn.cancel(); return
        }
        authed = true
        log("peer authenticated")
        send(["t": "ready"], on: conn)
        onPeerChange?(true)
    }

    // MARK: - Sending

    /// Encrypt + send a local clip to the authenticated phone. No-op if no peer / bad key.
    func sendClip(_ text: String) {
        queue.async { [self] in
            guard authed, let conn = connection, !text.isEmpty,
                  let key = pairingProvider()?.key,
                  let (nonce, ct) = ClipCodec.encode(text, keyBase64: key) else { return }
            send(["t": "clip", "nonce": nonce, "ct": ct], on: conn)
        }
    }

    /// Encrypt + send a telemetry payload (e.g. battery) to the authenticated phone. Mirrors
    /// `sendClip`; no-op if no peer / bad key.
    func sendStat(_ payload: String) {
        queue.async { [self] in
            guard authed, let conn = connection, !payload.isEmpty,
                  let key = pairingProvider()?.key,
                  let (nonce, ct) = ClipCodec.encode(payload, keyBase64: key) else { return }
            send(["t": "stat", "nonce": nonce, "ct": ct], on: conn)
        }
    }

    private func send(_ message: [String: Any], on conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[LanServer] \(message)")
        #endif
    }
}
