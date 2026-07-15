import CryptoKit
import Foundation

/// End-to-end frame encryption. ChaCha20-Poly1305 (RFC 8439) keyed by the 32-byte pairing
/// `key` (the secret carried in the QR, base64 of 32 random bytes). Wire shape:
///   nonce = base64(12-byte random nonce),  ct = base64(ciphertext ‖ 16-byte Poly1305 tag).
///
/// **v2 envelope (replay protection + type binding):**
///   AAD       = utf8(frame type: "clip" | "cmd" | "stat" | "note" | "sms" | "file")
///   plaintext = 8-byte big-endian epoch-milliseconds ‖ utf8(payload)
/// The AAD stops a captured ciphertext from being relabeled to another frame type; the
/// timestamp (±2 min window) plus a seen-nonce cache stops replays of captured frames —
/// the relay is an explicitly untrusted pipe.
///
/// Legacy v1 (no AAD, raw payload) is **no longer accepted**: a v1 frame carried no
/// freshness and was replayable indefinitely. Both ends ship v2; an old peer fails closed.
///
/// Wire-compatible with the Android `ClipCodec` (`javax.crypto "ChaCha20-Poly1305"`) — the
/// envelope is a byte-exact cross-language contract, change both sides together. Fails
/// closed: malformed key, tampered/relabeled/stale/replayed frame, or key mismatch → nil.
enum ClipCodec {
    private static let tagLen = 16
    private static let tsLen = 8
    /// Freshness window (ms): frames whose timestamp differs from the local clock by more
    /// than this (either direction, tolerating skew) are rejected as replayed/stale.
    private static let freshnessWindowMs: UInt64 = 120_000

    /// Nonces accepted within the freshness window (`nonceB64 → tsMs`); a duplicate is a
    /// replay. Static + locked: decode runs on the main actor (RelayClient) and on
    /// LanServer's serial queue.
    nonisolated(unsafe) private static var seenNonces: [String: UInt64] = [:]
    private static let seenLock = NSLock()

    /// Encrypt `text` as a `type` frame. nil if the key is malformed.
    static func encode(_ text: String, keyBase64: String, type: String) -> (nonce: String, ct: String)? {
        encodeData(Data(text.utf8), keyBase64: keyBase64, type: type)
    }

    /// Encrypt a raw byte payload (e.g. `file` image bytes) as a `type` frame — same v2
    /// envelope as text, just no UTF-8 step. nil if the key is malformed.
    static func encodeData(_ payload: Data, keyBase64: String, type: String) -> (nonce: String, ct: String)? {
        guard let key = symmetricKey(keyBase64) else { return nil }
        var plain = Data()
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        withUnsafeBytes(of: ts.bigEndian) { plain.append(contentsOf: $0) }
        plain.append(payload)
        guard let box = try? ChaChaPoly.seal(plain, using: key, authenticating: Data(type.utf8)) else { return nil }
        let ct = box.ciphertext + box.tag
        return (nonce: Data(box.nonce).base64EncodedString(), ct: ct.base64EncodedString())
    }

    /// Decrypt a `type` frame to its payload, or nil on auth failure / relabeled type /
    /// stale timestamp / replayed nonce / malformed input / wrong key.
    static func decode(nonce: String, ct: String, keyBase64: String, type: String) -> String? {
        guard let plain = decodeData(nonce: nonce, ct: ct, keyBase64: keyBase64, type: type) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Decrypt a `type` frame to its raw byte payload (e.g. `file` image bytes) — same checks
    /// as the text variant.
    static func decodeData(nonce: String, ct: String, keyBase64: String, type: String) -> Data? {
        guard
            let key = symmetricKey(keyBase64),
            let nonceData = Data(base64Encoded: nonce),
            let ctData = Data(base64Encoded: ct),
            ctData.count >= tagLen,
            let aeadNonce = try? ChaChaPoly.Nonce(data: nonceData)
        else { return nil }
        let cipher = ctData.prefix(ctData.count - tagLen)
        let tag = ctData.suffix(tagLen)
        guard let box = try? ChaChaPoly.SealedBox(nonce: aeadNonce, ciphertext: cipher, tag: tag) else { return nil }

        // v2 envelope only: type bound as AAD, ts-prefixed plaintext. A legacy v1 frame (no
        // AAD) fails this open and is dropped — v1 carried no freshness and was replayable.
        guard let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(type.utf8)) else {
            return nil
        }
        guard plain.count >= tsLen else { return nil }
        let ts = plain.prefix(tsLen).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let skew = now > ts ? now - ts : ts - now
        guard skew <= freshnessWindowMs else { return nil }
        guard rememberNonce(nonce, ts: ts, now: now) else { return nil }
        return Data(plain.dropFirst(tsLen))
    }

    /// Records the nonce; false when it was already seen inside the window (a replay).
    private static func rememberNonce(_ nonce: String, ts: UInt64, now: UInt64) -> Bool {
        seenLock.lock()
        defer { seenLock.unlock() }
        let horizon = freshnessWindowMs * 2
        let cutoff = now > horizon ? now - horizon : 0
        seenNonces = seenNonces.filter { $0.value > cutoff }
        if seenNonces[nonce] != nil { return false }
        seenNonces[nonce] = ts
        return true
    }

    private static func symmetricKey(_ base64: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
