import Foundation
import Observation

/// Drives a single WebSocket connection to the relay: connect, `join`, app-level
/// ping/pong, presence tracking, and auto-reconnect with exponential backoff.
///
/// Main-actor isolated so all observable state mutates on the main thread; the async
/// receive/heartbeat loops hop back here on every step. A monotonic `generation`
/// counter lets stale loops (from a replaced socket) bail out instead of corrupting
/// the current connection's state.
@MainActor
@Observable
final class RelayClient {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected   // socket open, join sent, awaiting `joined`
        case joined
        case error(String)
    }

    private(set) var status: Status = .disconnected
    private(set) var peerOnline = false
    private(set) var lastError: String?

    /// Most recent clipboard text received from the peer (decoded; no crypto yet).
    private(set) var lastClip: String?

    /// Generated once and persisted; the room we join and show as a QR for the phone.
    private(set) var pairing: Pairing = PairingStore.loadOrCreate()

    /// Whether the user wants to be connected; drives reconnect behaviour.
    private var shouldStay = false

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var generation = 0

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Watches the Mac clipboard; created on first connect, forwards copies to the peer.
    private var pasteboard: PasteboardWatcher?

    private static let heartbeatInterval: Duration = .seconds(25)
    private static let maxBackoff = 30.0

    // MARK: - Public control

    func connect() {
        guard !shouldStay else { return }
        shouldStay = true
        reconnectAttempt = 0
        if pasteboard == nil {
            pasteboard = PasteboardWatcher { [weak self] text in self?.sendClip(text) }
        }
        pasteboard?.start()
        openSocket()
    }

    func disconnect() {
        shouldStay = false
        pasteboard?.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        status = .disconnected
        peerOnline = false
        lastError = nil
    }

    /// Encode + send local clipboard text to the peer. No-op if the socket isn't open.
    func sendClip(_ text: String) {
        guard !text.isEmpty else { return }
        let (nonce, ct) = ClipCodec.encode(text)
        Task { [weak self] in try? await self?.send(.clip(nonce: nonce, ct: ct)) }
    }

    func toggle() {
        shouldStay ? disconnect() : connect()
    }

    /// Forget the current pairing: drop the connection, delete the Keychain secret, and
    /// mint a fresh room/key. Reconnects into the new (empty) room if we were active, so
    /// the next "Pairing QR" scan links up immediately; the old phone is left behind in
    /// the abandoned room.
    func unpair() {
        let wasActive = shouldStay
        disconnect()
        PairingStore.clear()
        pairing = PairingStore.loadOrCreate()
        lastClip = nil
        if wasActive { connect() }
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        generation &+= 1
        let gen = generation

        status = .connecting
        lastError = nil

        var request = URLRequest(url: Config.relayURL)
        request.setValue("Bearer \(Config.authToken)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()

        startReceiveLoop(generation: gen)
        startHeartbeat(generation: gen)
        Task { [weak self] in await self?.sendJoin(generation: gen) }
    }

    /// Cancels the active socket and its loops, but leaves `reconnectTask` alone.
    private func teardown() {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - Sending

    private func send(_ message: ClientMessage) async throws {
        guard let task else { throw RelayError.notConnected }
        let data = try encoder.encode(message)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func sendJoin(generation gen: Int) async {
        guard gen == generation else { return }
        do {
            try await send(.join(room: pairing.room, device: Config.device))
            guard gen == generation else { return }
            if status == .connecting { status = .connected }
        } catch {
            if gen == generation { handleFailure("join send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Receiving

    private func startReceiveLoop(generation gen: Int) {
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: gen)
        }
    }

    private func receiveLoop(generation gen: Int) async {
        while !Task.isCancelled, gen == generation, let socket = task {
            do {
                let message = try await socket.receive()
                guard gen == generation else { return }
                handle(message)
            } catch {
                // Cancelled (intentional disconnect tears the socket down under us) or
                // stale socket failure; both expected, not an error.
                guard !Task.isCancelled, gen == generation else { return }
                handleFailure("receive failed: \(error.localizedDescription)")
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            apply(text)
        case let .data(data):
            if let text = String(data: data, encoding: .utf8) {
                apply(text)
            } else {
                log("ignoring binary frame (\(data.count) bytes)")
            }
        @unknown default:
            break
        }
    }

    private func apply(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let msg = try? decoder.decode(ServerMessage.self, from: data)
        else {
            log("ignoring undecodable frame: \(text)")
            return
        }
        switch msg {
        case let .joined(peers):
            status = .joined
            reconnectAttempt = 0
            peerOnline = peers.contains(Config.peerDevice)
            log("joined; peers=\(peers)")
        case let .peer(state, device):
            if device == Config.peerDevice { peerOnline = (state == "online") }
            log("peer \(device) \(state)")
        case let .error(code, message):
            status = .error(code)
            lastError = message
            log("relay error: \(code) \(message)")
        case let .clip(_, ct):
            // Placeholder codec: ct is base64(utf8(text)); nonce ignored until crypto lands.
            if let text = ClipCodec.decode(ct: ct) {
                pasteboard?.write(text)
                lastClip = text
                log("clip received (\(text.count) chars)")
            } else {
                log("clip with undecodable ct")
            }
        case .pong:
            break
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat(generation gen: Int) {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RelayClient.heartbeatInterval)
                if Task.isCancelled { return }
                let keepGoing = await self?.heartbeatTick(generation: gen) ?? false
                if !keepGoing { return }
            }
        }
    }

    private func heartbeatTick(generation gen: Int) async -> Bool {
        guard !Task.isCancelled, gen == generation else { return false }
        do {
            try await send(.ping)
            return true
        } catch {
            if !Task.isCancelled, gen == generation {
                handleFailure("ping failed: \(error.localizedDescription)")
            }
            return false
        }
    }

    // MARK: - Failure / reconnect

    private func handleFailure(_ reason: String) {
        log(reason)
        lastError = reason
        guard shouldStay else {
            teardown()
            status = .disconnected
            return
        }
        if reconnectTask != nil { return } // a reconnect is already scheduled
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        teardown()
        status = .connecting
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(attempt)), RelayClient.maxBackoff)
        log("reconnecting in \(Int(delay))s (attempt \(attempt + 1))")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.performReconnect()
        }
    }

    private func performReconnect() {
        reconnectTask = nil
        if shouldStay { openSocket() }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        #if DEBUG
        print("[RelayClient] \(message)")
        #endif
    }
}

// MARK: - UI-facing derived state

extension RelayClient {
    var isActive: Bool { shouldStay }

    /// JSON payload encoded into the pairing QR shown to the phone.
    var pairingQRPayload: String { PairingStore.qrPayload(pairing) }

    /// Short, human-readable form of the room id for the pairing window.
    var pairingRoomShort: String { String(pairing.room.prefix(12)) + "…" }

    var statusText: String {
        switch status {
        case .disconnected: return "Relay: disconnected"
        case .connecting: return "Relay: connecting…"
        case .connected: return "Relay: connected"
        case .joined: return "Relay: joined"
        case let .error(code): return "Relay: error (\(code))"
        }
    }

    var peerText: String {
        "Android: \(peerOnline ? "online" : "offline")"
    }

    var menuBarSymbol: String {
        switch status {
        case .joined: return "antenna.radiowaves.left.and.right"
        case .connecting, .connected: return "antenna.radiowaves.left.and.right"
        case .disconnected, .error: return "antenna.radiowaves.left.and.right.slash"
        }
    }
}
