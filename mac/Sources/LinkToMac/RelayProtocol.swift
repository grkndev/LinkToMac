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
/// - `op`   — `data` (payload) or `ack` (receiver acknowledging one stored chunk). Default `data`.
/// - `mime` — content type. Default `image/png`.
/// - `name` — original file name, used by `disp: save`.
/// - `disp` — `clip` (paste it) or `save` (write it to the download folder). Default `clip`.
/// - `id` / `seq` / `n` — chunk group, 0-based index, total count. Absent = one whole file.
///
/// **Acks are flow control, not politeness.** The relay drops any peer buffering more than
/// `maxPayloadBytes * 8` (8 MiB) as a slow consumer, so a phone that fired a 50 MB file's chunks
/// back to back would disconnect *this* Mac partway through. Every stored chunk is acked and the
/// sender keeps only a small window in flight. Layering extra ops onto an existing frame type,
/// rather than adding a new one, is the same move the `sms` reply path makes.
enum FileFrame {
    static let opData = "data"
    static let opAck = "ack"
    static let dispClip = "clip"
    static let dispSave = "save"

    /// Raw payload bytes per chunk. Byte-for-byte the phone's `FileFrame.CHUNK_RAW_BYTES`: the
    /// relay caps a frame at 1 MiB (`MAX_PAYLOAD_BYTES`), and 640 KiB raw becomes ~853 KB of
    /// base64 plus ~60 bytes of JSON — a comfortable margin. Bump this only together with the
    /// relay's `MAX_PAYLOAD_BYTES` and both WebSocket `maximumMessageSize` settings.
    static let chunkRawBytes = 640 * 1024

    /// Refuse to start a transfer bigger than this. Mirrors the phone's `MAX_TRANSFER_BYTES`.
    static let maxTransferBytes = 64 * 1024 * 1024

    /// One decoded `file` frame.
    struct Parsed {
        let op: String
        let mime: String
        let name: String?
        let disp: String
        let id: String?
        let seq: Int
        let count: Int
        let bytes: Data

        /// True when this frame is the whole file (the pre-chunking shape, and any one-chunk file).
        var isSingle: Bool { id == nil || count <= 1 }
    }

    /// Build a data frame. Chunk fields are omitted for a single-frame transfer, so the bytes stay
    /// identical to what pre-chunking builds sent.
    static func payload(
        mime: String,
        bytes: Data,
        name: String? = nil,
        disp: String = dispClip,
        id: String? = nil,
        seq: Int = 0,
        count: Int = 1
    ) -> Data {
        var header: [String: Any] = ["mime": mime]
        if let name { header["name"] = name }
        if disp != dispClip { header["disp"] = disp }
        if let id, count > 1 {
            header["id"] = id
            header["seq"] = seq
            header["n"] = count
        }
        return frame(header: header, bytes: bytes)
    }

    /// Build a zero-payload `ack` frame for one stored chunk.
    static func ack(id: String, seq: Int) -> Data {
        frame(header: ["op": opAck, "id": id, "seq": seq], bytes: Data())
    }

    /// `JSONSerialization`, not string interpolation: a file name is user data and may contain
    /// quotes or backslashes that would otherwise produce a header the Kotlin side can't parse.
    private static func frame(header: [String: Any], bytes: Data) -> Data {
        let headerData = (try? JSONSerialization.data(withJSONObject: header)) ?? Data("{}".utf8)
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
        return Parsed(
            op: header["op"] as? String ?? opData,
            mime: header["mime"] as? String ?? "image/png",
            name: (name?.isEmpty == false) ? name : nil,
            disp: header["disp"] as? String ?? dispClip,
            id: header["id"] as? String,
            seq: header["seq"] as? Int ?? 0,
            count: header["n"] as? Int ?? 1,
            bytes: bytes
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
