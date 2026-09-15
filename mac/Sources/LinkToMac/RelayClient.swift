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
        var isImage = false
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
    /// the same notification, so it drives dedup/update/removal AND the SwiftUI identity: a fresh
    /// `UUID()` per upsert made every in-place update diff as delete+insert (row rebuilt, state lost).
    struct NotificationEntry: Identifiable {
        var id: String { key }
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

    /// One mirrored SMS message. `id` is the Android `_id` (stable → drives upsert/dedup). `threadKey`
    /// groups messages into a conversation (Android `thread_id`, falling back to the address).
    /// Send-state of an outgoing reply composed on the Mac. Mirrored messages (read from the
    /// phone's SMS store) are always `.sent`; only a Mac-composed placeholder starts `.sending`.
    enum SendStatus: Equatable {
        case sending
        case sent
        case failed(String)

        var isFailed: Bool { if case .failed = self { return true } else { return false } }
    }

    struct MessageEntry: Identifiable {
        var id: Int64
        let threadKey: String
        let addr: String
        let name: String?
        let body: String
        let date: Date
        let outgoing: Bool
        let read: Bool
        var status: SendStatus = .sent

        /// Contact name when known, else the raw address.
        var display: String {
            guard let name, !name.isEmpty else { return addr }
            return name
        }
    }

    /// A conversation: all messages sharing a `threadKey`, chronological (oldest → newest). Derived
    /// on demand from `messages` by `conversations`.
    struct Conversation: Identifiable {
        let id: String
        let display: String
        let messages: [MessageEntry]
        /// `nil` only if `messages` is empty — `rebuildConversations()`'s `Dictionary(grouping:)`
        /// never produces that today, but callers still handle it rather than force-unwrapping.
        var latest: MessageEntry? { messages.last }
        var unread: Int { messages.lazy.filter { !$0.read && !$0.outgoing }.count }
    }

    /// Mirrored phone SMS (deduped/upserted by `id`, capped). Feeds the dashboard's Messages tab via
    /// the `conversations` grouping. In-memory only — cleared on quit / unpair.
    private(set) var messages: [MessageEntry] = []
    private static let messagesCap = 500

    /// Placeholder ids for in-flight replies composed on the Mac (always negative — real SMS-store
    /// ids from the phone are always ≥0, so the two id spaces can never collide).
    private var nextPendingId: Int64 = -1

    /// In-flight replies awaiting a phone ack, keyed by the `corr` sent in the `sms` "send" op, to
    /// the placeholder `MessageEntry.id` they correspond to. Cleared on ack (success rewrites the
    /// id to the real one; failure just clears the tracking, the entry stays `.failed`) or timeout.
    private var pendingReplies: [String: Int64] = [:]
    private static let pendingReplyTimeout: Duration = .seconds(15)

    /// Messages grouped into conversations, newest activity first. Rebuilt eagerly on every
    /// `messages` mutation — as a computed property it re-grouped and re-sorted up to 500
    /// messages on every FeaturePanel body evaluation.
    private(set) var conversations: [Conversation] = []

    private func rebuildConversations() {
        conversations = Dictionary(grouping: messages, by: { $0.threadKey }).map { key, msgs in
            let sorted = msgs.sorted { $0.date < $1.date }
            // Prefer a contact-name label if any message in the thread resolved one.
            let display = sorted.last(where: { $0.name?.isEmpty == false })?.display ?? sorted.last?.display ?? key
            return Conversation(id: key, display: display, messages: sorted)
        }
        .sorted { ($0.latest?.date ?? .distantPast) > ($1.latest?.date ?? .distantPast) }
    }

    /// Strip formatting noise from a phone-number address so the thread fallback key is stable.
    private static func normalizeAddr(_ addr: String) -> String {
        let stripped = addr.filter { !$0.isWhitespace && !"-().".contains($0) }
        return stripped.isEmpty ? addr : stripped
    }

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

    /// Outbound gate for image copies specifically (a screenshot copy can be ~700 KB over the
    /// relay, so it gets its own kill switch under the `sendToAndroid` master). Defaults on.
    var syncImages: Bool = UserDefaults.standard.object(forKey: "syncImagesToAndroid") as? Bool ?? true {
        didSet { UserDefaults.standard.set(syncImages, forKey: "syncImagesToAndroid") }
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

    /// Reassembles chunked inbound `file` transfers (the phone's "Send as a File" share target).
    /// `@ObservationIgnored` because `@Observable` rewrites plain stored properties into computed
    /// ones, which `lazy` (needed here for the `self` capture) can't be.
    @ObservationIgnored private lazy var fileInbox = FileInbox { [weak self] msg in self?.log(msg) }

    /// Streams a local file to the phone in chunks. Not `@MainActor` — it blocks on an ack window.
    let fileSender = FileSender()

    /// The file currently arriving from the phone, or nil. Counted in chunks — the receiver only
    /// learns the real size when the last one lands.
    var incomingFile: TransferProgress?

    /// The file currently being sent to the phone, or nil. Drives the drop-zone progress UI.
    var outgoingFile: TransferProgress?

    /// Where a `disp: save` file lands. Owned here rather than injected so the LAN-direct path,
    /// which reaches `receiveRemoteFile` without going through any view, writes to the same place.
    let fileDrop = FileDropStore()

    /// Watches this Mac's battery; created on first connect, forwards level/charging to the peer.
    private var battery: BatteryMonitor?

    /// Latest BLE proximity (measured by this Mac scanning the phone's beacon), embedded in the
    /// outbound `stat` so the phone can show the Mac's distance — it can't measure that itself, it
    /// only advertises. `state` is `"near"|"away"|"unseen"|"off"`; `rssi` is the smoothed dBm.
    private var proxState: String?
    private var proxRSSI: Int?

    /// Fan-out hook for a second transport (the LAN-direct server). Called with every local
    /// copy that passes the `sendToAndroid` gate, so a phone on the LAN gets clips too.
    var onLocalClip: ((String) -> Void)?

    /// Fan-out hook for telemetry (battery) onto the LAN-direct server, mirroring `onLocalClip`.
    var onLocalStat: ((String) -> Void)?

    /// Fan-out hook for an image copy onto the LAN-direct server, mirroring `onLocalClip`.
    /// Carries the assembled `file` plaintext (header + raw bytes); each transport seals it.
    var onLocalFile: ((Data) -> Void)?

    /// Fan-out hook for an outbound SMS reply onto the LAN-direct server, mirroring `onLocalStat`.
    /// Carries the plaintext `{"op":"send",…}` payload; each transport seals it.
    var onLocalSms: ((String) -> Void)?

    /// Fired when the pairing (room/key) changes — e.g. after `unpair()`. Lets the LAN server
    /// re-advertise under the new pairing id and invalidate any stale authenticated socket.
    var onPairingChanged: (() -> Void)?

    private static let heartbeatInterval: Duration = .seconds(25)
    /// Declare the link dead when nothing has been received for two heartbeat intervals.
    private static let pongTimeout: TimeInterval = 50
    private static let maxBackoff = 30.0

    /// Last proof of relay liveness: the `pong` reply to our app-level ping, or any inbound
    /// frame. On a half-open socket (Wi-Fi drop, NAT timeout, sleep/wake) `send` keeps
    /// succeeding into the kernel buffer, so *sending* proves nothing — only receiving does.
    private var lastLiveness = Date()

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
            } onImage: { [weak self] data in
                guard let self, self.sendToAndroid, self.syncImages else { return }
                guard let (bytes, mime) = ImagePrep.prepare(data) else {
                    self.log("image copy skipped (can't fit under the frame budget)")
                    Task { await MacNotifier.post(title: "Image not synced", body: "The copied image couldn't be compressed under the transfer limit.") }
                    return
                }
                let payload = FileFrame.payload(mime: mime, bytes: bytes)
                self.sendFile(payload)
                self.onLocalFile?(payload) // fan out to the LAN-direct transport too
            }
        }
        pasteboard?.start()
        if battery == nil {
            battery = BatteryMonitor { [weak self] _ in
                // Battery changed → resend the merged telemetry (battery + current proximity) on
                // both transports. The payload is rebuilt from the live monitors in `pushStatNow`.
                self?.pushStatNow()
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
        guard let (nonce, ct) = ClipCodec.encode(text, keyBase64: pairing.key, type: "clip") else {
            log("encrypt failed (bad pairing key); not sending")
            return
        }
        Task { [weak self] in try? await self?.send(.clip(nonce: nonce, ct: ct)) }
    }

    /// Encrypt + send an assembled `file` plaintext (header + image bytes) to the peer. Same
    /// fail-closed AEAD as `sendClip`.
    func sendFile(_ payload: Data) {
        guard !payload.isEmpty else { return }
        guard let (nonce, ct) = ClipCodec.encodeData(payload, keyBase64: pairing.key, type: "file") else {
            log("encrypt failed (bad pairing key); not sending file")
            return
        }
        Task { [weak self] in try? await self?.send(.file(nonce: nonce, ct: ct)) }
    }

    /// Encrypt + send a telemetry payload (e.g. battery) to the peer. Same fail-closed AEAD as
    /// `sendClip`: never falls back to plaintext if the pairing key is malformed.
    func sendStat(_ payload: String) {
        guard !payload.isEmpty else { return }
        guard let (nonce, ct) = ClipCodec.encode(payload, keyBase64: pairing.key, type: "stat") else {
            log("encrypt failed (bad pairing key); not sending stat")
            return
        }
        Task { [weak self] in try? await self?.send(.stat(nonce: nonce, ct: ct)) }
    }

    /// Compose + send an SMS reply to `addr` (a 1:1 thread's address). Appends an optimistic
    /// `.sending` placeholder to `messages` immediately for instant feedback; the placeholder's
    /// `id` is rewritten to the real SMS-store id (and `status` flips to `.sent`) once the phone
    /// acks, so the later genuine `SmsMirror` delta upserts over it instead of duplicating. Flips
    /// to `.failed` after `pendingReplyTimeout` with no ack. No-op (returns nil) if the pairing key
    /// is malformed — fail closed, same as every other outbound frame.
    @discardableResult
    func sendReply(addr: String, body: String) -> String? {
        guard !addr.isEmpty, !body.isEmpty else { return nil }
        let corr = UUID().uuidString
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let escapedAddr = addr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let payload = "{\"op\":\"send\",\"corr\":\"\(corr)\",\"addr\":\"\(escapedAddr)\",\"body\":\"\(escapedBody)\"}"
        guard let (nonce, ct) = ClipCodec.encode(payload, keyBase64: pairing.key, type: "sms") else {
            log("encrypt failed (bad pairing key); not sending reply")
            return nil
        }

        let placeholderId = nextPendingId
        nextPendingId -= 1
        let threadKey: String = {
            if let existing = messages.last(where: { Self.normalizeAddr($0.addr) == Self.normalizeAddr(addr) }) {
                return existing.threadKey
            }
            return Self.normalizeAddr(addr)
        }()
        let placeholder = MessageEntry(
            id: placeholderId, threadKey: threadKey, addr: addr, name: nil, body: body,
            date: Date(), outgoing: true, read: true, status: .sending
        )
        messages.append(placeholder)
        rebuildConversations()
        pendingReplies[corr] = placeholderId

        Task { [weak self] in try? await self?.send(.sms(nonce: nonce, ct: ct)) }
        onLocalSms?(payload)

        Task { [weak self] in
            try? await Task.sleep(for: Self.pendingReplyTimeout)
            self?.timeoutPendingReply(corr: corr)
        }
        return corr
    }

    private func timeoutPendingReply(corr: String) {
        guard let placeholderId = pendingReplies.removeValue(forKey: corr) else { return }
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        messages[idx].status = .failed("timeout")
        rebuildConversations()
    }

    /// This Mac's battery + BLE proximity merged into one `stat` payload, omitting whichever isn't
    /// available (no battery on a desktop Mac; no proximity until the user enables auto-lock). `nil`
    /// when there's nothing to report. The peer updates only the fields present, so a battery-only
    /// frame and a proximity-only frame never clobber each other. Lets the owner push a fresh value
    /// to a transport the moment its peer connects (see `LinkToMacApp`).
    func currentStatPayload() -> String? {
        var parts: [String] = []
        // This Mac's name. The phone uses it to label its Direct Share entries ("Save on <Mac>"),
        // the way Quick Share names a device — it has no other way to learn what this Mac is called.
        if let name = Self.macName { parts.append("\"name\":\(Self.jsonString(name))") }
        if let s = battery?.currentState() {
            parts.append("\"level\":\(s.level)")
            parts.append("\"charging\":\(s.charging)")
        }
        if let state = proxState {
            parts.append("\"prox\":\"\(state)\"")
            if let r = proxRSSI { parts.append("\"rssi\":\(r)") }
        }
        guard !parts.isEmpty else { return nil }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// This Mac's user-visible name, as System Settings ▸ General ▸ About shows it. Computed once:
    /// it can only change via a relaunch-worthy system setting.
    private static let macName: String? = {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.isEmpty ? nil : name
    }()

    /// JSON-escape a string for the hand-built `stat` payload (a Mac can be named `Ben"s`).
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast()) // strip the [ ] JSONSerialization insists on
    }

    /// Record the latest BLE proximity reading (from `ProximityMonitor`, which scans the phone's
    /// beacon) and forward it to the phone — the phone can't measure distance itself, it only
    /// advertises, so it relies on the value this Mac measured. Deduped upstream + here.
    func updateProximity(_ reading: ProximityMonitor.Reading) {
        guard proxState != reading.state || proxRSSI != reading.rssi else { return }
        proxState = reading.state
        proxRSSI = reading.rssi
        pushStatNow()
    }

    /// Send the current merged telemetry over both transports now (no-op when there's nothing to
    /// report or before the monitors start). Used on a peer-online edge and on any telemetry change.
    private func pushStatNow() {
        guard let payload = currentStatPayload() else { return }
        sendStat(payload)          // → the relay peer
        onLocalStat?(payload)      // → the LAN-direct transport
    }

    /// Write a clip that arrived over the LAN-direct transport. Reuses the same echo-suppressed
    /// pasteboard writer as relay clips, so a local re-copy isn't bounced back to the phone.
    func writeRemoteClip(_ text: String) {
        pasteboard?.write(text)
        lastClip = text
        recordClip(text)
        log("lan clip received (\(text.count) chars)")
    }

    /// Handle a `file` frame that arrived from the phone (relay or LAN — both call here).
    ///
    /// Three shapes land on this one entry point, because `file` carries them all the way the
    /// `sms` channel carries replies: a whole clipboard image (the original shape), one chunk of a
    /// larger file, and an ack for a chunk we sent. Chunks are acked as they are stored — that ack
    /// is the sender's flow control, and without it the phone would outrun the relay's 8 MiB
    /// per-peer buffer and get this Mac disconnected mid-transfer.
    func receiveRemoteFile(_ payload: Data) {
        guard let frame = FileFrame.parse(payload) else {
            log("file frame malformed")
            return
        }
        // An ack advances the transfer this Mac is sending (`sendFileToPhone`).
        if frame.op == FileFrame.opAck {
            if let id = frame.id { fileSender.ack(id: id) }
            return
        }

        // Ack on `id` alone, not on chunk count: a one-chunk "Send as a File" carries an id too,
        // and the sender blocks on its receipt before reporting success.
        if let id = frame.id { sendFileAck(id: id, seq: frame.seq) }
        let assembled = fileInbox.accept(frame)
        // Republish whatever the inbox now reports: a partial transfer drives the dashboard's
        // "receiving" row, and a completed or rejected one clears it.
        incomingFile = fileInbox.progress.map {
            TransferProgress(name: $0.name, done: $0.received, total: $0.total)
        }
        guard let file = assembled else { return }

        switch file.disp {
        case FileFrame.dispSave:
            saveIncomingFile(file)
        default:
            // Echo-suppressed writer, so the image isn't immediately re-sent to the phone.
            pasteboard?.writeImage(file.bytes, mime: file.mime)
            recordClip("[Image]", isImage: true)
            log("image received (\(file.mime), \(file.bytes.count) bytes)")
        }
    }

    /// Write a completed `disp: save` transfer into the configured download folder and tell the
    /// user where it went — nothing about this arrives on the pasteboard, so a banner is the only
    /// thing that makes the file discoverable.
    private func saveIncomingFile(_ file: FileInbox.Assembled) {
        do {
            let url = try fileDrop.save(bytes: file.bytes, preferredName: file.name, mime: file.mime)
            log("file saved: \(url.path) (\(file.bytes.count) bytes)")
            Task { await MacNotifier.post(title: "Saved from your phone", body: url.lastPathComponent) }
        } catch {
            log("file save failed: \(error.localizedDescription)")
            Task {
                await MacNotifier.post(
                    title: "Couldn't save file",
                    body: file.name ?? "A file from your phone could not be written."
                )
            }
        }
    }

    /// Send a local file to the phone, where it lands in Downloads/Link to Mac. The Mac→phone
    /// mirror of the phone's "Send as a File" share target.
    ///
    /// Unlike every other outbound frame this picks **one** transport instead of fanning out to
    /// both: a file is hundreds of frames, and pushing them at the relay as well when the phone is
    /// actually on the LAN would burn the relay's rate limit for nothing (the phone keeps only one
    /// link joined, so it would never see the duplicates anyway).
    func sendFileToPhone(_ url: URL) {
        guard !fileSender.isSending else {
            log("file send skipped (another transfer is in flight)")
            return
        }
        guard isLinked || lanPeerConnected else {
            Task { await MacNotifier.post(title: "Phone isn't connected", body: url.lastPathComponent) }
            return
        }
        let overLAN = lanPeerConnected
        let name = url.lastPathComponent
        outgoingFile = TransferProgress(name: name, done: 0, total: 0)
        log("file -> phone: \(name) (\(overLAN ? "lan" : "relay"))")

        fileSender.send(
            url: url,
            overLAN: overLAN,
            emit: { [self] payload in
                // DispatchQueue.main, not Task: this keeps chunks in order on the socket. (The
                // receiver writes by `seq` and tolerates gaps, but there's no reason to create them.)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if overLAN { self.onLocalFile?(payload) } else { self.sendFile(payload) }
                    }
                }
            },
            progress: { [self] sent, total in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.outgoingFile = TransferProgress(name: name, done: sent, total: total)
                    }
                }
            },
            done: { [self] outcome in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.outgoingFile = nil
                        switch outcome {
                        case .sent:
                            self.log("file delivered to phone: \(name)")
                            Task { await MacNotifier.post(title: "Sent to your phone", body: name) }
                        case let .failed(reason):
                            self.log("file send failed: \(reason)")
                            Task { await MacNotifier.post(title: "Couldn't send \(name)", body: reason) }
                        }
                    }
                }
            }
        )
    }

    /// Acknowledge one stored chunk, on both transports — `ConnectionManager` keeps exactly one
    /// link joined at a time, so the phone receives this once, never twice.
    private func sendFileAck(id: String, seq: Int) {
        let payload = FileFrame.ack(id: id, seq: seq)
        sendFile(payload)
        onLocalFile?(payload)
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

    /// Apply a phone `sms` frame that arrived over the LAN-direct transport (already decrypted by
    /// `LanServer`) — batch/delta or a reply ack, dispatched by `handleInboundSms`.
    func writeRemoteSms(_ json: String) {
        handleInboundSms(json)
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

    func clearMessages() {
        messages.removeAll()
        rebuildConversations()
    }

    /// Append a received clip to the in-memory history (newest first, capped, skip consecutive dupes).
    private func recordClip(_ text: String, isImage: Bool = false) {
        // The consecutive-duplicate guard stops an echo/re-copy from double-recording. Images are
        // all recorded as the placeholder "[Image]", so without the isImage bypass every image
        // after the first would look like a duplicate and be dropped.
        guard !text.isEmpty, isImage || clipHistory.first?.text != text else { return }
        clipHistory.insert(ClipEntry(text: text, date: Date(), isImage: isImage), at: 0)
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
            Task { await MacNotifier.post(title: bannerTitle, body: entry.text, iconPNG: iconPNG) }
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

    /// Peek the `op` of a decrypted `sms` payload and route to the right handler: `sent`/`failed`
    /// are acks for a Mac-composed reply, everything else (`batch`/`add`, or missing) is a mirrored
    /// message list.
    private func handleInboundSms(_ json: String) {
        switch Self.peekSmsOp(json) {
        case "sent", "failed":
            applySmsAck(json)
        default:
            applySms(json)
        }
    }

    private struct SmsOpPeek: Decodable { let op: String? }

    private static func peekSmsOp(_ json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(SmsOpPeek.self, from: data))?.op
    }

    /// Resolve an in-flight reply's ack: `sent` rewrites the placeholder's id to the real SMS-store
    /// id and marks it `.sent` (so the later genuine `SmsMirror` delta upserts over it, no
    /// duplicate); `failed` marks it `.failed` with the phone-reported reason. A `corr` with no
    /// matching pending reply (already timed out, or a stale/duplicate ack) is ignored.
    private func applySmsAck(_ json: String) {
        guard let ack = Self.decodeSmsAck(json), let placeholderId = pendingReplies.removeValue(forKey: ack.corr) else {
            log("sms ack: no matching pending reply")
            return
        }
        guard let idx = messages.firstIndex(where: { $0.id == placeholderId }) else { return }
        if ack.op == "sent" {
            // The phone couldn't write its own SMS store (only the default SMS app reliably can)
            // when `id` is absent — the placeholder stays as the permanent record for this reply
            // rather than being superseded by a mirrored delta that will never arrive.
            if let realId = ack.id { messages[idx].id = realId }
            messages[idx].status = .sent
            log("sms reply sent" + (ack.id.map { " (id \($0))" } ?? " (no store id)"))
        } else {
            messages[idx].status = .failed(ack.error ?? "send-error")
            log("sms reply failed: \(ack.error ?? "unknown")")
        }
        rebuildConversations()
    }

    private struct SmsAckPayload: Decodable {
        let op: String
        let corr: String
        let id: Int64?
        let error: String?
    }

    private static func decodeSmsAck(_ json: String) -> SmsAckPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmsAckPayload.self, from: data)
    }

    /// Parse + apply a decrypted phone `sms` payload (`{op, msgs:[…]}`). Each item is upserted by `id`
    /// (a backfill chunk and a live delta are handled identically — re-sends are idempotent). Trims to
    /// the cap by dropping the oldest. Grouping into threads happens in `conversations`.
    private func applySms(_ json: String) {
        guard let payload = Self.decodeSms(json) else { log("sms parse failed"); return }
        for m in payload.msgs {
            let threadKey: String
            // The addr fallback must be normalized: "+90 555 123 45 67" and "+905551234567" are
            // the same correspondent and must not split one conversation into two threads.
            if let t = m.thread, t > 0 { threadKey = "t\(t)" } else { threadKey = Self.normalizeAddr(m.addr) }
            let entry = MessageEntry(
                id: m.id,
                threadKey: threadKey,
                addr: m.addr,
                name: m.name,
                body: m.body,
                date: Date(timeIntervalSince1970: Double(m.date) / 1000),
                outgoing: m.dir == "out",
                read: m.read ?? true
            )
            if let idx = messages.firstIndex(where: { $0.id == entry.id }) {
                messages[idx] = entry
            } else {
                messages.append(entry)
            }
        }
        if messages.count > Self.messagesCap {
            messages.sort { $0.date > $1.date }
            messages.removeLast(messages.count - Self.messagesCap)
        }
        rebuildConversations()
        log("sms: +\(payload.msgs.count) (\(messages.count) total)")
    }

    private struct SmsPayload: Decodable {
        struct Item: Decodable {
            let id: Int64
            let thread: Int64?
            let addr: String
            let name: String?
            let body: String
            let date: Int64
            let dir: String?
            let read: Bool?
        }
        let op: String?
        let msgs: [Item]
    }

    private static func decodeSms(_ json: String) -> SmsPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmsPayload.self, from: data)
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
        messages.removeAll()
        pendingReplies.removeAll()
        rebuildConversations()
        iconCache.removeAll()
        phoneBatteryLevel = nil
        phoneCharging = nil
        phoneName = nil
        proxState = nil
        proxRSSI = nil
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
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        // Default is 1 MiB, which a clipboard image `file` frame can bump against; raise it so a
        // near-cap frame isn't rejected (the relay itself enforces the real MAX_PAYLOAD_BYTES).
        task.maximumMessageSize = 4 * 1024 * 1024
        lastLiveness = Date() // fresh socket starts with a clean liveness clock
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
        lastLiveness = Date() // any inbound frame proves the socket is alive, not just pong
        switch msg {
        case let .joined(peers):
            status = .joined
            reconnectAttempt = 0
            peerOnline = peers.contains(Config.peerDevice)
            log("joined; peers=\(peers)")
            if peerOnline { pushStatNow() } // give the phone a fresh value without waiting for the poll
        case let .peer(state, device):
            if device == Config.peerDevice {
                let cameOnline = (state == "online") && !peerOnline
                peerOnline = (state == "online")
                if cameOnline { pushStatNow() }
            }
            log("peer \(device) \(state)")
        case let .error(code, message):
            // Per-frame validation errors (e.g. an older relay that doesn't know `stat`) are not
            // connection failures — log them but don't sour the menu status.
            if code == "bad-message" {
                log("relay rejected a frame: \(message)")
                return
            }
            // Everything else (bad-join / room-full / not-joined / rate-limit / join-timeout)
            // invalidates the session. Setting `.error` and stopping used to wedge: the relay
            // won't resend `joined` on a live socket, so nothing ever cleared the status. Tear
            // down and reconnect with backoff instead — a rejoin resets the state either way.
            lastError = message
            handleFailure("relay error: \(code) — \(message)")
        case let .clip(nonce, ct):
            // ChaCha20-Poly1305, keyed by the pairing secret. Drops anything that fails to
            // authenticate (corrupt, tampered, or a key mismatch after a re-pair).
            if let text = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key, type: "clip") {
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
            if let action = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key, type: "cmd") {
                handleCommand(action)
            } else {
                log("cmd decrypt failed (key mismatch or corrupt)")
            }
        case let .stat(nonce, ct):
            // Phone telemetry (battery + name). Same AEAD as clips; drop anything unauthenticated.
            if let json = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key, type: "stat") {
                applyPhoneStat(json)
            } else {
                log("stat decrypt failed (key mismatch or corrupt)")
            }
        case let .note(nonce, ct):
            // A mirrored phone notification. Same AEAD as clips; drop anything unauthenticated.
            if let json = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key, type: "note") {
                applyNotification(json)
            } else {
                log("note decrypt failed (key mismatch or corrupt)")
            }
        case let .sms(nonce, ct):
            // A mirrored phone SMS batch/delta, or a reply ack. Same AEAD as clips; drop anything
            // unauthenticated.
            if let json = ClipCodec.decode(nonce: nonce, ct: ct, keyBase64: pairing.key, type: "sms") {
                handleInboundSms(json)
            } else {
                log("sms decrypt failed (key mismatch or corrupt)")
            }
        case let .file(nonce, ct):
            // A clipboard image, a file chunk, or a chunk ack from the phone. Same AEAD as clips;
            // drop anything unauthenticated.
            if let payload = ClipCodec.decodeData(nonce: nonce, ct: ct, keyBase64: pairing.key, type: "file") {
                receiveRemoteFile(payload)
            } else {
                log("file decrypt failed (key mismatch or corrupt)")
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
        // Sending proves nothing on a half-open socket (it succeeds into the kernel buffer for
        // minutes while every clip is silently lost) — receiving does. Two missed intervals
        // with no inbound frame at all means the link is dead: tear down and reconnect instead
        // of showing "linked".
        if Date().timeIntervalSince(lastLiveness) > RelayClient.pongTimeout {
            handleFailure("pong timeout (no frame for \(Int(RelayClient.pongTimeout))s)")
            return false
        }
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
