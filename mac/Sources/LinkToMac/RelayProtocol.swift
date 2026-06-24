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
        }
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
        case "pong":
            self = .pong
        default:
            throw DecodeError.unknownType(t)
        }
    }
}
