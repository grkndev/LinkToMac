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
        }
    }
}

/// Assembles the `file` frame plaintext (what goes inside the v2 envelope, AAD "file"):
///   u16 BE header-len ‖ header JSON utf8 ‖ raw file bytes
/// Header v1 is `{"mime":"image/png"}` — JSON so future file transfer can add name/size.
/// Byte-exact contract with the Kotlin receiver (`ClipForegroundService.applyFile`).
enum FileFrame {
    static func payload(mime: String, bytes: Data) -> Data {
        let header = Data("{\"mime\":\"\(mime)\"}".utf8)
        var out = Data(capacity: 2 + header.count + bytes.count)
        out.append(UInt8((header.count >> 8) & 0xFF))
        out.append(UInt8(header.count & 0xFF))
        out.append(header)
        out.append(bytes)
        return out
    }

    /// Split an inbound `file` plaintext back into its mime + raw bytes. nil if malformed.
    static func parse(_ payload: Data) -> (mime: String, bytes: Data)? {
        guard payload.count >= 2 else { return nil }
        let base = payload.startIndex
        let headerLen = Int(payload[base]) << 8 | Int(payload[base + 1])
        guard payload.count >= 2 + headerLen else { return nil }
        let headerData = payload.subdata(in: (base + 2)..<(base + 2 + headerLen))
        let bytes = payload.subdata(in: (base + 2 + headerLen)..<payload.endIndex)
        let mime = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any]
        return (mime?["mime"] as? String ?? "image/png", bytes)
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
