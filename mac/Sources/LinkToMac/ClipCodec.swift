import Foundation
import Security

/// Placeholder clip codec mirroring `mobile/src/features/relay/clip-codec.ts`.
/// NO ENCRYPTION YET — `ct` is base64(utf8(text)), `nonce` is random filler. libsodium
/// secretbox (keyed by the paired `key`) replaces this later; only this file changes.
enum ClipCodec {
    static func encode(_ text: String) -> (nonce: String, ct: String) {
        (nonce: randomBase64(24), ct: Data(text.utf8).base64EncodedString())
    }

    static func decode(ct: String) -> String? {
        guard let data = Data(base64Encoded: ct) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func randomBase64(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
