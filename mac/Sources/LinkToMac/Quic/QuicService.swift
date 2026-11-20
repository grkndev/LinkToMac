import Foundation

/// The app's end of the QUIC session protocol (plan stage 1.6): turns a phone's `q.*` action into the server's work and the server's
/// answers back into `cmd` frames. Everything with rules lives in `QuicSession`, everything with sockets in `QuicListener`; this is
/// only the wiring to `RelayClient`, which is why it is the one QUIC file the unit tests do not compile.
///
/// The server (and with it the Keychain identity) is created on the first request, not at launch: an app that is never asked for a
/// session never opens a port or touches the Keychain.
@MainActor
final class QuicService {
    private weak var client: RelayClient?
    private var server: QuicServer?

    /// Kinds this Mac serves. Stage 1.6: only the debug `echo`; the file, screen and camera stages add theirs.
    private static var supportedKinds: Set<QuicKind> {
        #if DEBUG
        return [.echo]
        #else
        return []
        #endif
    }

    init(client: RelayClient) {
        self.client = client
        // A QUIC session needs the LAN-direct link: when it goes away the session ends and the listener closes (stage 1.8).
        client.onLanPeerLost = { [weak self] in self?.server?.linkLost() }
    }

    /// A parsed `q.*` action from the phone (`RelayClient.onQuicControl`).
    func handle(_ action: QuicAction) {
        guard let client else { return }
        guard let server = ensureServer() else {
            // No identity, no session: say so instead of leaving the phone waiting for an offer.
            if case let .request(sid, _) = action { client.sendCommand(QuicControl.encode(.reject(sid: sid, reason: .busy))) }
            return
        }
        server.receive(action, onLan: client.lanPeerConnected)
    }

    /// The pairing changed (Unpair): the session ends and the identity is replaced next time.
    func pairingChanged() {
        server?.end()
        server = nil
        QuicIdentity.reset()
    }

    private func ensureServer() -> QuicServer? {
        if let server { return server }
        guard let identity = try? QuicIdentity.loadOrCreate() else { return nil }
        var config = QuicSession.Config()
        config.supportedKinds = Self.supportedKinds
        let created = QuicServer(identity: identity, config: config, send: { [weak self] action in
            Task { @MainActor in self?.deliver(action) }
        })
        server = created
        return created
    }

    private func deliver(_ action: QuicAction) {
        client?.sendCommand(QuicControl.encode(action))
    }
}
