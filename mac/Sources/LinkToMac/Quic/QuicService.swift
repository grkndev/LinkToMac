import Foundation
import Observation

/// The app's end of the QUIC session protocol (plan stage 1.6): turns a phone's `q.*` action into the server's work and the server's
/// answers back into `cmd` frames. Everything with rules lives in `QuicSession`, everything with sockets in `QuicListener`; this is
/// only the wiring to `RelayClient`, which is why it is the one QUIC file the unit tests do not compile.
///
/// The server (and with it the Keychain identity) is created on the first request, not at launch: an app that is never asked for a
/// session never opens a port or touches the Keychain.
@MainActor
@Observable
final class QuicService {
    @ObservationIgnored private weak var client: RelayClient?
    @ObservationIgnored private var server: QuicServer?

    #if DEBUG
    /// What the debug "QUIC test session" (Settings ▸ General, debug builds only) shows.
    private(set) var testStatus = "Not run"
    @ObservationIgnored private var reachedConnected = false
    #endif

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

    #if DEBUG
    /// Debug builds only: the Mac asks the phone for an `echo` session. The phone (a debug build) accepts on its own, connects, runs its echo
    /// check and ends the session, which is what this waits for. The gate decides whether it is worth asking at all.
    func startTestSession() {
        guard let client else { return }
        guard let server = ensureServer() else {
            report("No QUIC identity could be made")
            return
        }
        switch QuicGate.outgoing(active: false, onLan: client.lanPeerConnected, caps: client.peerCaps.caps, kindSupported: Self.supportedKinds.contains(.echo)) {
        case .hidden:
            report("The phone does not offer QUIC (an older app, or it has not said so yet)")
        case .refused(.relay):
            report("Needs the phone on the same Wi-Fi (LAN-direct)")
        case let .refused(reason):
            report("Not possible right now (\(reason.rawValue))")
        case .proceed:
            reachedConnected = false
            report("Asking the phone…")
            server.onStateChange = { [weak self] state in
                Task { @MainActor in self?.testStateChanged(state) }
            }
            server.request(.echo, onLan: true)
        }
    }

    /// Sets the status the Settings row shows and prints it (a script can read it from the log: `[QuicTest] …`; fixed sentences only).
    private func report(_ text: String) {
        testStatus = text
        print("[QuicTest] \(text)")
    }

    private func testStateChanged(_ state: QuicSession.State) {
        switch state {
        case .idle: break
        case .requested: report("Asking the phone…")
        case .accepted: report("The phone accepted, opening a listener…")
        case .offered: report("Offer sent, waiting for the phone to connect…")
        case .connected:
            reachedConnected = true
            report("Connected, the phone is checking the echo…")
        case let .ended(end):
            switch end {
            case .peerEnded where reachedConnected: report("Completed: the phone's echo check passed and it ended the session")
            case .peerEnded: report("The phone ended the session before it opened")
            case let .peerRejected(reason): report("The phone refused (\(reason.rawValue))")
            case .acceptTimeout: report("No answer from the phone in time (an older app?)")
            case .offerTimeout: report("The phone never connected")
            case .idleTimeout: report("Ended: nothing happened for 30 s")
            case .linkLost: report("Ended: the LAN link went away")
            case .connectionLost: report("Ended: the connection was lost")
            case .localEnded: report("Ended here")
            case .listenerFailed: report("Ended: the listener could not start")
            }
        }
    }
    #endif

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
