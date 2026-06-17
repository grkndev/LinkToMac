import CryptoKit
import Foundation

/// End-to-end clipboard encryption. ChaCha20-Poly1305 (RFC 8439) keyed by the 32-byte pairing
/// `key` (the secret carried in the QR, base64 of 32 random bytes). Wire shape:
///   nonce = base64(12-byte random nonce),  ct = base64(ciphertext ‖ 16-byte Poly1305 tag).
/// Wire-compatible with the Android `ClipCodec` (`javax.crypto "ChaCha20-Poly1305"`). The relay
/// only ever sees opaque base64 — never the key or the plaintext. Fails closed: a malformed key,
/// a tampered frame, or a key mismatch returns nil and the clip is dropped.
enum ClipCodec {
    private static let tagLen = 16

    /// Encrypt `text` with `keyBase64` (base64 of 32 bytes). nil if the key is malformed.
    static func encode(_ text: String, keyBase64: String) -> (nonce: String, ct: String)? {
        guard let key = symmetricKey(keyBase64) else { return nil }
        guard let box = try? ChaChaPoly.seal(Data(text.utf8), using: key) else { return nil }
        let ct = box.ciphertext + box.tag
        return (nonce: Data(box.nonce).base64EncodedString(), ct: ct.base64EncodedString())
    }

    /// Decrypt to plaintext, or nil on auth failure / malformed input / wrong key.
    static func decode(nonce: String, ct: String, keyBase64: String) -> String? {
        guard
            let key = symmetricKey(keyBase64),
            let nonceData = Data(base64Encoded: nonce),
            let ctData = Data(base64Encoded: ct),
            ctData.count >= tagLen,
            let aeadNonce = try? ChaChaPoly.Nonce(data: nonceData)
        else { return nil }
        let cipher = ctData.prefix(ctData.count - tagLen)
        let tag = ctData.suffix(tagLen)
        guard
            let box = try? ChaChaPoly.SealedBox(nonce: aeadNonce, ciphertext: cipher, tag: tag),
            let plain = try? ChaChaPoly.open(box, using: key)
        else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    private static func symmetricKey(_ base64: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
