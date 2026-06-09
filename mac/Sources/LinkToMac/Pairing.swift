import Foundation
import Security
import AppKit
import CoreImage.CIFilterBuiltins

/// The shared secret established at pairing. `room` is the relay bearer (also the QR's
/// room); `key` is the 256-bit E2E secret carried for later (unused until crypto lands).
struct Pairing: Codable {
    let room: String // base64(32 random bytes)
    let key: String  // base64(32 random bytes)
}

/// Generates the pairing on first launch and persists it to the Keychain. The Mac is the
/// pairing initiator: it owns the room and shows it as a QR for the phone to scan.
enum PairingStore {
    private static let service = "dev.grkn.LinkToMac"
    private static let account = "pairing"

    static func loadOrCreate() -> Pairing {
        if let existing = load() { return existing }
        let fresh = Pairing(room: randomBase64(32), key: randomBase64(32))
        save(fresh)
        return fresh
    }

    static func load() -> Pairing? {
        guard let data = keychainGet() else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    static func save(_ pairing: Pairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        keychainSet(data)
    }

    /// JSON the phone scans: `{"v":1,"room":"...","key":"..."}`.
    static func qrPayload(_ pairing: Pairing) -> String {
        let payload = QRPayload(v: 1, room: pairing.room, key: pairing.key)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private struct QRPayload: Codable {
        let v: Int
        let room: String
        let key: String
    }

    private static func randomBase64(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Keychain (generic password)

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainGet() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func keychainSet(_ data: Data) {
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Renders a string into a QR `NSImage` using CoreImage.
enum QRCode {
    static func image(from string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
