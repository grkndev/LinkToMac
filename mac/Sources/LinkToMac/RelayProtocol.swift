import Foundation

enum RelayError: Error {
    case notConnected
}

/// Messages this client sends to the relay. Mirrors `server/src/protocol.ts`.
enum ClientMessage: Encodable {
    case join(room: String, device: String)
    case ping
    case pong
    /// Encrypted clipboard payload: `nonce` + `ct` from `ClipCodec` (ChaCha20-Poly1305).
    case clip(nonce: String, ct: String)
    /// Encrypted telemetry payload (e.g. battery `{"level":85,"charging":true}`), E2E-encrypted
    /// into `nonce`/`ct` exactly like a `clip`. The relay forwards it opaquely; only the peer decrypts.
    case stat(nonce: String, ct: String)
    /// Encrypted file payload (Mac → phone clipboard image): plaintext is
    /// `u16 BE header-len ‖ header JSON ‖ raw bytes` inside the v2 envelope, AAD "file".
    case file(nonce: String, ct: String)
    /// Encrypted SMS reply request (Mac → phone): plaintext is
    /// `{"op":"send","corr":"…","addr":"…","body":"…"}`, AAD "sms" — same envelope inbound
    /// `sms` batches/deltas use. The relay forwards it opaquely.
    case sms(nonce: String, ct: String)

    private enum CodingKeys: String, CodingKey {
        case t, room, device, nonce, ct
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .join(room, device):
            try c.encode("join", forKey: .t)
            try c.encode(room, forKey: .room)
            try c.encode(device, forKey: .device)
        case .ping:
            try c.encode("ping", forKey: .t)
        case .pong:
            try c.encode("pong", forKey: .t)
        case let .clip(nonce, ct):
            try c.encode("clip", forKey: .t)
            try c.encode(nonce, forKey: .nonce)
            try c.encode(ct, forKey: .ct)
        case let .stat(nonce, ct):
            try c.encode("stat", forKey: .t)
            try c.encode(nonce, forKey: .nonce)
            try c.encode(ct, forKey: .ct)
        case let .file(nonce, ct):
            try c.encode("file", forKey: .t)
            try c.encode(nonce, forKey: .nonce)
            try c.encode(ct, forKey: .ct)
        case let .sms(nonce, ct):
            try c.encode("sms", forKey: .t)
            try c.encode(nonce, forKey: .nonce)
            try c.encode(ct, forKey: .ct)
        }
    }
}

/// Assembles + parses the `file` frame plaintext (what goes inside the v2 envelope, AAD "file"):
///
///     u16 BE header-len ‖ header JSON utf8 ‖ raw file bytes
///
/// **Byte-exact contract with the Kotlin `FileFrame.kt`.** The two are hand-mirrored, not
/// generated; change both together (see the root CLAUDE.md invariant on the wire protocol).
///
/// Header fields are all optional but `mime`, and all additive to the original `{"mime":…}`
/// shape, so an older peer that only reads `mime` still pastes an image correctly:
///
/// - `op`   — `data` (payload), `ack` (receiver stored one chunk) or `nack` (receiver could not
///            store it). Default `data`.
/// - `have` — on an `ack`: leading chunks `[0, have)` already stored, so a retry resumes there.
/// - `mime` — content type. Default `image/png`.
/// - `name` — original file name, used by `disp: save`.
/// - `disp` — `clip` (paste it) or `save` (write it to the download folder). Default `clip`.
/// - `id` / `seq` / `n` — chunk group, 0-based index, total count. Absent = one whole file. An
///            `id` is written for a one-chunk file too: it is what makes the receiver ack, and a
///            "send as a file" transfer wants that receipt at any size.
/// - `dir`  — relative folder (`Photos/2024`) the file sits in, for `disp: save` of a dropped
///            folder. Absent = the download folder itself. An older peer ignores it and saves flat.
///
/// **Acks are flow control, not politeness.** The relay drops any peer buffering more than
/// `maxPayloadBytes * 8` (8 MiB) as a slow consumer, so a phone that fired a 50 MB file's chunks
/// back to back would disconnect *this* Mac partway through. Every stored chunk is acked and the
/// sender keeps only a small window in flight. Layering extra ops onto an existing frame type,
/// rather than adding a new one, is the same move the `sms` reply path makes.
enum FileFrame {
    static let opData = "data"
    static let opAck = "ack"
    static let opNack = "nack"
    static let dispClip = "clip"
    static let dispSave = "save"

    /// Raw payload bytes per chunk. Byte-for-byte the phone's `FileFrame.CHUNK_RAW_BYTES`: the
    /// relay caps a frame at 1 MiB (`MAX_PAYLOAD_BYTES`), and 640 KiB raw becomes ~853 KB of
    /// base64 plus ~60 bytes of JSON — a comfortable margin. Bump this only together with the
    /// relay's `MAX_PAYLOAD_BYTES` and both WebSocket `maximumMessageSize` settings.
    static let chunkRawBytes = 640 * 1024

    /// Refuse to start a transfer bigger than this. Mirrors the phone's `MAX_TRANSFER_BYTES` — they
    /// must match, or one side accepts a file the other then drops. Both receivers stream chunks to
    /// disk, so this is no longer a memory limit; time and free space are the real ones.
    static let maxTransferBytes = 1024 * 1024 * 1024

    /// One decoded `file` frame.
    struct Parsed {
        let op: String
        let mime: String
        let name: String?
        let dir: String?
        let disp: String
        let id: String?
        let seq: Int
        let count: Int
        let bytes: Data
        /// Why a `nack` was sent, when the receiver said.
        let reason: String?
        /// On an `ack`: how many leading chunks `[0, have)` the receiver already holds (resume).
        let have: Int?

        /// True when this frame is the whole file (the pre-chunking shape, and any one-chunk file).
        var isSingle: Bool { id == nil || count <= 1 }
    }

    /// The header length is a u16, so it can never exceed this.
    static let maxHeaderBytes = 0xFFFF

    /// Build a data frame. Chunk fields are omitted only when no `id` was assigned (a clipboard
    /// image), so those bytes stay identical to what pre-chunking builds sent.
    static func payload(
        mime: String,
        bytes: Data,
        name: String? = nil,
        dir: String? = nil,
        disp: String = dispClip,
        id: String? = nil,
        seq: Int = 0,
        count: Int = 1
    ) -> Data {
        var header: [String: Any] = ["mime": mime]
        if let name { header["name"] = name }
        if let dir, !dir.isEmpty { header["dir"] = dir }
        if disp != dispClip { header["disp"] = disp }
        if let id {
            header["id"] = id
            header["seq"] = seq
            header["n"] = count
        }
        return frame(header: fitted(header), bytes: bytes)
    }

    /// Build a zero-payload `ack` frame for one stored chunk. `have` (optional) tells the sender
    /// how many leading chunks the receiver already holds, so a retry of the same file can skip
    /// them; an older sender ignores the extra key and an older receiver never sends it.
    static func ack(id: String, seq: Int, have: Int? = nil) -> Data {
        var header: [String: Any] = ["op": opAck, "id": id, "seq": seq]
        if let have { header["have"] = have }
        return frame(header: header, bytes: Data())
    }

    /// Build a zero-payload `nack` frame: the receiver could not store `id`/`seq`.
    static func nack(id: String, seq: Int, reason: String? = nil) -> Data {
        var header: [String: Any] = ["op": opNack, "id": id, "seq": seq]
        if let reason { header["err"] = String(reason.prefix(200)) }
        return frame(header: header, bytes: Data())
    }

    /// Keep a header under the u16 limit. A file name and folder path are user data of unbounded
    /// length, and an over-long header would otherwise be truncated by the length prefix into
    /// something the receiver can't parse. Shed the folder first (the file still arrives, flat),
    /// then shorten the name.
    private static func fitted(_ header: [String: Any]) -> [String: Any] {
        var h = header
        func size() -> Int { (try? JSONSerialization.data(withJSONObject: h).count) ?? 0 }
        if size() <= maxHeaderBytes { return h }
        h["dir"] = nil
        if size() <= maxHeaderBytes { return h }
        if let name = h["name"] as? String {
            var short = name
            while size() > maxHeaderBytes, short.count > 16 {
                short = String(short.prefix(short.count / 2))
                h["name"] = short
            }
        }
        return h
    }

    /// `JSONSerialization`, not string interpolation: a file name is user data and may contain
    /// quotes or backslashes that would otherwise produce a header the Kotlin side can't parse.
    private static func frame(header: [String: Any], bytes: Data) -> Data {
        var headerData = (try? JSONSerialization.data(withJSONObject: header)) ?? Data("{}".utf8)
        // Unreachable for headers built by `payload` (it fits them first); an empty header is
        // the safe floor rather than a length prefix that wraps.
        if headerData.count > maxHeaderBytes { headerData = Data("{}".utf8) }
        var out = Data(capacity: 2 + headerData.count + bytes.count)
        out.append(UInt8((headerData.count >> 8) & 0xFF))
        out.append(UInt8(headerData.count & 0xFF))
        out.append(headerData)
        out.append(bytes)
        return out
    }

    /// Split an inbound `file` plaintext back into its header + raw bytes. nil if malformed.
    static func parse(_ payload: Data) -> Parsed? {
        guard payload.count >= 2 else { return nil }
        let base = payload.startIndex
        let headerLen = Int(payload[base]) << 8 | Int(payload[base + 1])
        guard payload.count >= 2 + headerLen else { return nil }
        let headerData = payload.subdata(in: (base + 2)..<(base + 2 + headerLen))
        let bytes = payload.subdata(in: (base + 2 + headerLen)..<payload.endIndex)
        let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] ?? [:]
        let name = header["name"] as? String
        let dir = header["dir"] as? String
        return Parsed(
            op: header["op"] as? String ?? opData,
            mime: header["mime"] as? String ?? "image/png",
            name: (name?.isEmpty == false) ? name : nil,
            dir: (dir?.isEmpty == false) ? dir : nil,
            disp: header["disp"] as? String ?? dispClip,
            id: header["id"] as? String,
            seq: header["seq"] as? Int ?? 0,
            count: header["n"] as? Int ?? 1,
            bytes: bytes,
            reason: header["err"] as? String,
            have: header["have"] as? Int
        )
    }
}

/// Messages the relay sends to this client. Decoded by the `t` discriminator.
enum ServerMessage: Decodable {
    case joined(peers: [String])
    case peer(state: String, device: String)
    case error(code: String, message: String)
    case clip(nonce: String, ct: String)
    /// A remote action from the peer (e.g. "lock"), E2E-encrypted into `nonce`/`ct` just like
    /// a clip. The relay forwards it opaquely; we decrypt with the pairing key before acting.
    case cmd(nonce: String, ct: String)
    /// Telemetry from the phone (battery + name), E2E-encrypted into `nonce`/`ct` like a clip.
    /// Decrypted plaintext is `{"level":N,"charging":bool,"name":"…"}`.
    case stat(nonce: String, ct: String)
    /// A mirrored device notification from the phone, E2E-encrypted into `nonce`/`ct` like a clip.
    /// Decrypted plaintext is a JSON object (see `RelayClient.applyNotification`).
    case note(nonce: String, ct: String)
    /// A batch/delta of mirrored SMS messages from the phone, E2E-encrypted into `nonce`/`ct` like a
    /// clip. Decrypted plaintext is a JSON object (see `RelayClient.applySms`).
    case sms(nonce: String, ct: String)
    /// A clipboard image from the phone, E2E-encrypted into `nonce`/`ct` like a clip. Decrypted
    /// plaintext is `u16 BE header-len ‖ header JSON ‖ raw bytes` (see `FileFrame.parse`).
    case file(nonce: String, ct: String)
    case pong

    private enum CodingKeys: String, CodingKey {
        case t, peers, state, device, code, message, nonce, ct
    }

    enum DecodeError: Error {
        case unknownType(String)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .t)
        switch t {
        case "joined":
            self = .joined(peers: try c.decodeIfPresent([String].self, forKey: .peers) ?? [])
        case "peer":
            self = .peer(
                state: try c.decode(String.self, forKey: .state),
                device: try c.decode(String.self, forKey: .device)
            )
        case "error":
            self = .error(
                code: try c.decode(String.self, forKey: .code),
                message: try c.decodeIfPresent(String.self, forKey: .message) ?? ""
            )
        case "clip":
            self = .clip(
                nonce: try c.decode(String.self, forKey: .nonce),
                ct: try c.decode(String.self, forKey: .ct)
            )
        case "cmd":
            self = .cmd(
                nonce: try c.decode(String.self, forKey: .nonce),
                ct: try c.decode(String.self, forKey: .ct)
            )
        case "stat":
            self = .stat(
                nonce: try c.decode(String.self, forKey: .nonce),
                ct: try c.decode(String.self, forKey: .ct)
            )
        case "note":
            self = .note(
                nonce: try c.decode(String.self, forKey: .nonce),
                ct: try c.decode(String.self, forKey: .ct)
            )
        case "sms":
            self = .sms(
                nonce: try c.decode(String.self, forKey: .nonce),
                ct: try c.decode(String.self, forKey: .ct)
            )
        case "file":
            self = .file(
                nonce: try c.decode(String.self, forKey: .nonce),
                ct: try c.decode(String.self, forKey: .ct)
            )
        case "pong":
            self = .pong
        default:
            throw DecodeError.unknownType(t)
        }
    }
}
