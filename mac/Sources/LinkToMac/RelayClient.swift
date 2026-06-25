import Foundation
import Observation
import AppKit

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

    /// Whether a phone is connected over the **LAN-direct** server (set by the app from
    /// `LanServer.onPeerChange`). Independent of `peerOnline` (the relay peer); the menu reflects
    /// whichever transport is live, and this is a real connection even when the relay is unset.
    var lanPeerConnected = false

    /// Most recent clipboard text received from the peer (decrypted via `ClipCodec`).
    private(set) var lastClip: String?

    /// One received clip with the time it arrived. `id` lets SwiftUI lists diff stably.
    struct ClipEntry: Identifiable {
        let id = UUID()
        let text: String
        let date: Date
    }

    /// Mac-local history of clips received from the phone (newest first, capped). Feeds the
    /// dashboard's Clipboard screen. In-memory only — cleared on quit / unpair.
    private(set) var clipHistory: [ClipEntry] = []
    private static let clipHistoryCap = 50

    /// Inbound phone telemetry from `stat` frames (nil until the first one arrives). The phone
    /// sends `{"level":N,"charging":bool,"name":"…"}`.
    private(set) var phoneBatteryLevel: Int?
    private(set) var phoneCharging: Bool?
    private(set) var phoneName: String?

    /// One mirrored phone notification. `key` is the Android `sbn.key` — stable across an update of
    /// the same notification, so it drives dedup/update/removal. `id` lets SwiftUI lists diff stably.
    struct NotificationEntry: Identifiable {
        let id = UUID()
        let key: String
        let pkg: String
        let app: String
        let title: String
        let text: String
        let category: String?
        let date: Date
        let icon: NSImage?
    }

    /// Mirrored phone notifications (newest first, capped, deduped by `key`). Feeds the dashboard's
    /// Notifications tab. In-memory only — cleared on quit / unpair.
    private(set) var notifications: [NotificationEntry] = []
    private static let notificationsCap = 100
    /// App-icon cache keyed by package, so a `note` that omits an icon still renders the app's badge.
    private var iconCache: [String: NSImage] = [:]

    /// Whether an inbound notification also raises a native macOS banner (the dashboard tab is always
    /// updated). Persisted; defaults on. `@Observable` makes the Settings toggle reflect changes live.
    var showNotificationBanners: Bool = UserDefaults.standard.object(forKey: "showNotificationBanners") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNotificationBanners, forKey: "showNotificationBanners") }
    }

    /// Generated once and persisted; the room we join and show as a QR for the phone.
    private(set) var pairing: Pairing = PairingStore.loadOrCreate()

    /// Outbound gate: when off, local copies are not forwarded to the phone (inbound still
    /// works). Persisted across launches; defaults to on so existing behaviour is preserved.
    /// `@Observable` makes the menu Toggle reflect changes live.
    var sendToAndroid: Bool = UserDefaults.standard.object(forKey: "sendCopiesToAndroid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sendToAndroid, forKey: "sendCopiesToAndroid") }
    }

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

    /// Watches this Mac's battery; created on first connect, forwards level/charging to the peer.
    private var battery: BatteryMonitor?

    /// Fan-out hook for a second transport (the LAN-direct server). Called with every local
    /// copy that passes the `sendToAndroid` gate, so a phone on the LAN gets clips too.
    var onLocalClip: ((String) -> Void)?

    /// Fan-out hook for telemetry (battery) onto the LAN-direct server, mirroring `onLocalClip`.
    var onLocalStat: ((String) -> Void)?

    /// Fired when the pairing (room/key) changes — e.g. after `unpair()`. Lets the LAN server
    /// re-advertise under the new pairing id and invalidate any stale authenticated socket.
    var onPairingChanged: (() -> Void)?

    private static let heartbeatInterval: Duration = .seconds(25)
    private static let maxBackoff = 30.0

    // MARK: - Public control

    func connect() {
        guard !shouldStay else { return }
        shouldStay = true
        reconnectAttempt = 0
        if pasteboard == nil {
            // Read the gate at call time so toggling "Send copies to Android" takes effect live.
            pasteboard = PasteboardWatcher { [weak self] text in
                guard let self, self.sendToAndroid else { return }
                self.sendClip(text)
                self.onLocalClip?(text) // fan out to the LAN-direct transport too
            }
        }
        pasteboard?.start()
        if battery == nil {
            battery = BatteryMonitor { [weak self] payload in
                guard let self else { return }
                self.sendStat(payload)              // report this Mac's battery to the phone
                self.onLocalStat?(payload)          // fan out to the LAN-direct transport too
            }
        }
        battery?.start()
        openSocket()
    }

    func disconnect() {
        shouldStay = false
        pasteboard?.stop()
        battery?.stop()
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        status = .disconnected
        peerOnline = false
        lastError = nil
    }

    /// Encrypt + send local clipboard text to the peer. No-op if the socket isn't open or the
    /// pairing key is malformed (fail closed — never fall back to sending plaintext).
    func sendClip(_ text: String) {
        guard !text.isEmpty else { return }
        guard let (nonce, ct) = ClipCodec.encode(text, keyBase64: pairing.key) else {
            log("encrypt failed (bad pairing key); not sending")
            return
        }
        Task { [weak self] in try? await self?.send(.clip(nonce: nonce, ct: ct)) }
    }

    /// Encrypt + send a telemetry payload (e.g. battery) to the peer. Same fail-closed AEAD as
    /// `sendClip`: never falls back to plaintext if the pairing key is malformed.
    func sendStat(_ payload: String) {
        guard !payload.isEmpty else { return }
        guard let (nonce, ct) = ClipCodec.encode(payload, keyBase64: pairing.key) else {
            log("encrypt failed (bad pairing key); not sending stat")
            return
        }
        Task { [weak self] in try? await self?.send(.stat(nonce: nonce, ct: ct)) }
    }

    /// Current battery as the wire payload, or nil if this Mac has no internal battery. Lets the
    /// owner push a fresh value to a transport the moment its peer connects (see `LinkToMacApp`).
    func currentBatteryPayload() -> String? {
        battery?.currentPayload()
    }

    /// Send the current battery over the relay now (no-op on a desktop Mac / before the monitor starts).
    private func pushBatteryNow() {
        if let payload = battery?.currentPayload() { sendStat(payload) }
    }

    /// Write a clip that arrived over the LAN-direct transport. Reuses the same echo-suppressed
    /// pasteboard writer as relay clips, so a local re-copy isn't bounced back to the phone.
    func writeRemoteClip(_ text: String) {
        pasteboard?.write(text)
        lastClip = text
        recordClip(text)
        log("lan clip received (\(text.count) chars)")
    }

    /// Run a remote action that arrived over the LAN-direct transport (e.g. "lock").
    func runRemoteCommand(_ action: String) {
        handleCommand(action)
    }

    /// Apply a phone `stat` that arrived over the LAN-direct transport (already decrypted by `LanServer`).
    func writeRemoteStat(_ json: String) {
        applyPhoneStat(json)
    }

    /// Apply a phone `note` that arrived over the LAN-direct transport (already decrypted by `LanServer`).
    func writeRemoteNote(_ json: String) {
        applyNotification(json)
    }

    /// Re-copy a clip-history entry to the pasteboard. Echo-suppressed (same writer as inbound
    /// clips), so it doesn't bounce back to the phone.
    func recopy(_ text: String) {
        guard !text.isEmpty else { return }
        pasteboard?.write(text)
        lastClip = text
    }

    func clearClipHistory() { clipHistory.removeAll() }

    func clearNotifications() { notifications.removeAll() }

    /// Append a received clip to the in-memory history (newest first, capped, skip consecutive dupes).
    private func recordClip(_ text: String) {
        guard !text.isEmpty, clipHistory.first?.text != text else { return }
        clipHistory.insert(ClipEntry(text: text, date: Date()), at: 0)
        if clipHistory.count > Self.clipHistoryCap {
            clipHistory.removeLast(clipHistory.count - Self.clipHistoryCap)
        }
    }

    /// Parse + apply a decrypted phone `stat` payload (`{"level":N,"charging":bool,"name":"…"}`).
    private func applyPhoneStat(_ json: String) {
        guard let stat = Self.decodeStat(json) else { log("stat parse failed"); return }
        if let level = stat.level { phoneBatteryLevel = min(max(level, 0), 100) }
        if let charging = stat.charging { phoneCharging = charging }
        if let name = stat.name, !name.isEmpty { phoneName = name }
    }

    private struct StatPayload: Decodable {
        let level: Int?
        let charging: Bool?
        let name: String?
    }

    private static func decodeStat(_ json: String) -> StatPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StatPayload.self, from: data)
    }

    /// Parse + apply a decrypted phone `note` payload. `op:"remove"` drops the entry with that `key`
    /// (a phone dismissal); `op:"post"` (default) upserts by `key` — same key replaces in place and
    /// moves to the front (an update), else inserts newest-first and trims to the cap. A post also
    /// raises a native banner when enabled.
    private func applyNotification(_ json: String) {
        guard let n = Self.decodeNote(json) else { log("note parse failed"); return }
        if n.op == "remove" {
            notifications.removeAll { $0.key == n.key }
            return
        }
        let pkg = n.pkg ?? ""
        // Raw PNG bytes (for the banner attachment) decoded once from the same base64 the icon uses.
        let iconPNG = n.icon.flatMap { Data(base64Encoded: $0) }
        let icon = resolveIcon(pkg: pkg, png: iconPNG)
        let entry = NotificationEntry(
            key: n.key,
            pkg: pkg,
            app: n.app ?? (pkg.isEmpty ? "App" : pkg),
            title: n.title ?? "",
            text: n.text ?? "",
            category: n.category,
            date: n.time.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date(),
            icon: icon
        )
        notifications.removeAll { $0.key == entry.key }
        notifications.insert(entry, at: 0)
        if notifications.count > Self.notificationsCap {
            notifications.removeLast(notifications.count - Self.notificationsCap)
        }
        log("note: \(entry.app) (\(entry.text.count) chars)")
        if showNotificationBanners {
            let bannerTitle = entry.title.isEmpty ? entry.app : "\(entry.app) · \(entry.title)"
            // The phone sends the icon on every post, so iconPNG is normally present; the banner
            // attachment surfaces the source app's icon (WhatsApp, Discord, …).
            MacNotifier.post(title: bannerTitle, body: entry.text, iconPNG: iconPNG)
        }
    }

    /// Build an `NSImage` from decoded PNG bytes, caching it per package. Falls back to the cached
    /// icon (or nil) when the payload carries no icon, so an update without an icon keeps the app badge.
    private func resolveIcon(pkg: String, png: Data?) -> NSImage? {
        if let png, let image = NSImage(data: png) {
            if !pkg.isEmpty { iconCache[pkg] = image }
            return image
        }
        return iconCache[pkg]
    }

    private struct NotePayload: Decodable {
        let op: String?
        let key: String
        let pkg: String?
        let app: String?
        let title: String?
        let text: String?
        let category: String?
        let time: Int64?
        let icon: String?
    }

    private static func decodeNote(_ json: String) -> NotePayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NotePayload.self, from: data)
    }

    func toggle() {
        shouldStay ? disconnect() : connect()
    }

    /// Re-open the socket to pick up changed Server Settings (host/port/secure/token). No-op if
    /// the user isn't currently connected; otherwise tears down and reconnects with fresh config.
    func reconnect() {
        guard shouldStay else { return }
        reconnectAttempt = 0
        openSocket()
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
        clipHistory.removeAll()
        notifications.removeAll()
        iconCache.removeAll()
        phoneBatteryLevel = nil
        phoneCharging = nil
        phoneName = nil
        onPairingChanged?()
        if wasActive { connect() }
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        // No relay endpoint set: stay idle (no reconnect loop). This is a normal LAN-only setup,
        // not an error — the LAN-direct server still carries the connection, so don't flag it red.
        guard !Config.host.isEmpty else {
            reconnectTask?.cancel()
            reconnectTask = nil
            teardown()
            status = .disconnected
            lastError = nil
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        generation &+= 1
        let gen = generation

        status = .connecting
        lastError = nil

        var request = URLRequest(url: Config.relayURL)
        request.setValue("Bearer \(Config.authToken)", forHTTPHeaderField: "Authorization")

        // `wss://` with a publicly-trusted (Let's Encrypt) cert works out of the box. For the
        // future LAN-direct mode (self-signed cert on the Mac), pin it via a URLSessionDelegate
        // `urlSession(_:didReceive:completionHandler:)` trust callback built from the QR fingerprint.
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
            if peerOnline { pushBatteryNow() } // give the phone a fresh value without waiting for the poll
        case let .peer(state, device):
            if device == Config.peerDevice {
                let cameOnline = (state == "online") && !peerOnline
                peerOnline = (state == "online")
                if cameOnline { pushBatteryNow() }
            }
            log("peer \(device) \(state)")
        case let .error(code, message):
            // Per-frame validation errors (e.g. an older relay that doesn't know `stat`) are not
            // connection failures — log them but don't sour the menu status.
            if code == "bad-message" {
                log("relay rejected a frame: \(message)")
                return
            }
            status = .error(code)
            lastError = message
            log("relay error: \(code) \(message)")
        case let .clip(nonce, ct):
            // ChaCha20-Poly1305, keyed by the pairing secret. Drops anything that fails to
            // authenticate (corrupt, tampered, or a key mismatch after a re-pair).
            if let text = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key) {
                pasteboard?.write(text)
                lastClip = text
                recordClip(text)
                log("clip received (\(text.count) chars)")
            } else {
                log("clip decrypt failed (key mismatch or corrupt)")
            }
        case let .cmd(nonce, ct):
            // Same AEAD as clips: drop anything that fails to authenticate (corrupt, tampered,
            // a key mismatch after re-pair, or a forged command from a LAN/relay attacker).
            if let action = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key) {
                handleCommand(action)
            } else {
                log("cmd decrypt failed (key mismatch or corrupt)")
            }
        case let .stat(nonce, ct):
            // Phone telemetry (battery + name). Same AEAD as clips; drop anything unauthenticated.
            if let json = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key) {
                applyPhoneStat(json)
            } else {
                log("stat decrypt failed (key mismatch or corrupt)")
            }
        case let .note(nonce, ct):
            // A mirrored phone notification. Same AEAD as clips; drop anything unauthenticated.
            if let json = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key) {
                applyNotification(json)
            } else {
                log("note decrypt failed (key mismatch or corrupt)")
            }
        case .pong:
            break
        }
    }

    /// Run a remote action requested by the phone. Kept off the clipboard path entirely.
    private func handleCommand(_ action: String) {
        switch action {
        case "lock":
            log("cmd: lock screen")
            ScreenLock.lock()
        default:
            log("cmd: ignoring unknown action \(action)")
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

    /// Whether a relay endpoint is configured. When false the app is LAN-only — the relay being
    /// "down" is expected, not an error, so the UI presents it as such.
    var isRelayConfigured: Bool { !Config.host.isEmpty }

    /// Whether the phone is reachable on *either* transport (relay peer online or a LAN peer).
    /// Drives the menu-bar icon's brightness (full when linked, dimmed when not).
    var isLinked: Bool { peerOnline || lanPeerConnected }

    /// JSON payload encoded into the pairing QR shown to the phone.
    var pairingQRPayload: String { PairingStore.qrPayload(pairing) }

    /// Short, human-readable form of the room id for the pairing window.
    var pairingRoomShort: String { String(pairing.room.prefix(12)) + "…" }

    var statusText: String {
        if lanPeerConnected { return "LAN: connected" }
        switch status {
        case .disconnected: return isRelayConfigured ? "Relay: disconnected" : "LAN-only — waiting"
        case .connecting: return "Relay: connecting…"
        case .connected: return "Relay: connected"
        case .joined: return "Relay: joined"
        case let .error(code): return isRelayConfigured ? "Relay: error (\(code))" : "LAN-only — waiting"
        }
    }

    var peerText: String {
        "Android: \((peerOnline || lanPeerConnected) ? "online" : "offline")"
    }
}
