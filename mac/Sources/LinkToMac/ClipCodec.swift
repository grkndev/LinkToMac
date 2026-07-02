import CryptoKit
import Foundation

/// End-to-end frame encryption. ChaCha20-Poly1305 (RFC 8439) keyed by the 32-byte pairing
/// `key` (the secret carried in the QR, base64 of 32 random bytes). Wire shape:
///   nonce = base64(12-byte random nonce),  ct = base64(ciphertext ‖ 16-byte Poly1305 tag).
///
/// **v2 envelope (replay protection + type binding):**
///   AAD       = utf8(frame type: "clip" | "cmd" | "stat" | "note" | "sms")
///   plaintext = 8-byte big-endian epoch-milliseconds ‖ utf8(payload)
/// The AAD stops a captured ciphertext from being relabeled to another frame type; the
/// timestamp (±2 min window) plus a seen-nonce cache stops replays of captured frames —
/// the relay is an explicitly untrusted pipe.
///
/// **Transitional:** decode falls back to the legacy v1 format (no AAD, raw payload) so a
/// not-yet-updated peer keeps working; remove the fallback once both ends ship v2.
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
        guard let key = symmetricKey(keyBase64) else { return nil }
        var plain = Data()
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        withUnsafeBytes(of: ts.bigEndian) { plain.append(contentsOf: $0) }
        plain.append(Data(text.utf8))
        guard let box = try? ChaChaPoly.seal(plain, using: key, authenticating: Data(type.utf8)) else { return nil }
        let ct = box.ciphertext + box.tag
        return (nonce: Data(box.nonce).base64EncodedString(), ct: ct.base64EncodedString())
    }

    /// Decrypt a `type` frame to its payload, or nil on auth failure / relabeled type /
    /// stale timestamp / replayed nonce / malformed input / wrong key.
    static func decode(nonce: String, ct: String, keyBase64: String, type: String) -> String? {
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

        // v2: type bound as AAD, ts-prefixed plaintext. A v2 frame that authenticates but is
        // stale/replayed is rejected HERE (the v1 fallback below can't resurrect it — its tag
        // was computed with AAD, so the AAD-less open fails).
        if let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(type.utf8)) {
            guard plain.count >= tsLen else { return nil }
            let ts = plain.prefix(tsLen).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let skew = now > ts ? now - ts : ts - now
            guard skew <= freshnessWindowMs else { return nil }
            guard rememberNonce(nonce, ts: ts, now: now) else { return nil }
            return String(decoding: plain.dropFirst(tsLen), as: UTF8.self)
        }
        // v1 (legacy, transitional): no AAD, whole plaintext is the payload. No freshness is
        // possible here — remove this acceptance once both ends ship the v2 codec.
        if let plain = try? ChaChaPoly.open(box, using: key) {
            NSLog("[ClipCodec] legacy v1 frame accepted (%@) — update the peer", type)
            return String(decoding: plain, as: UTF8.self)
        }
        return nil
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
