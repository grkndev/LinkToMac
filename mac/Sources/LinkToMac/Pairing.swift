import Foundation
import Security
import AppKit
import CoreImage.CIFilterBuiltins

/// The shared secret established at pairing. `room` is the relay bearer (also the QR's
/// room); `key` is the 256-bit secret the E2E `ClipCodec` (ChaCha20-Poly1305) uses to
/// encrypt/decrypt clipboard payloads.
struct Pairing: Codable {
    let room: String // base64(32 random bytes)
    let key: String  // base64(32 random bytes)
}

/// Generates the pairing on first launch and persists it to the Keychain. The Mac is the
/// pairing initiator: it owns the room and shows it as a QR for the phone to scan.
enum PairingStore {
    private static let service = "dev.grkn.LinkToMac"
    private static let account = "pairing"

    /// True when the last save could not be persisted to the Keychain (locked/ACL failure).
    /// The freshly minted room/key then only lives for this session — the next launch mints a
    /// DIFFERENT pairing and strands the already-paired phone — so surface it (PairingView)
    /// instead of failing silently. MainActor-isolated (Swift 6): every writer (`save`, via
    /// `loadOrCreate` from the `@MainActor` RelayClient) and reader (PairingView) is main-actor.
    @MainActor private(set) static var persistFailed = false

    @MainActor
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

    @MainActor
    @discardableResult
    static func save(_ pairing: Pairing) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else {
            persistFailed = true
            return false
        }
        let status = keychainSet(data)
        persistFailed = (status != errSecSuccess)
        if persistFailed {
            NSLog("[PairingStore] Keychain save failed (OSStatus %d) — pairing will not survive relaunch", status)
        }
        return !persistFailed
    }

    /// Deletes the persisted pairing; the next `loadOrCreate()` mints a fresh room/key.
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// JSON the phone scans (v3): v2's `{room,key,name,host,port,secure,token}` plus the LAN-direct
    /// params `{lport,lan}` (this Mac's WebSocket port + whether LAN is enabled). `name` is the
    /// current computer name, read fresh on every QR render. The relay endpoint may be blank
    /// (LAN-only). The phone still accepts legacy v1/v2 payloads.
    static func qrPayload(_ pairing: Pairing) -> String {
        let name = Host.current().localizedName ?? "Mac"
        let payload = QRPayload(
            v: 3,
            room: pairing.room,
            key: pairing.key,
            name: name,
            host: Config.host,
            port: Config.port,
            secure: Config.secure,
            token: Config.authToken,
            lport: Config.lanPort,
            lan: Config.lanEnabled
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private struct QRPayload: Codable {
        let v: Int
        let room: String
        let key: String
        let name: String
        let host: String
        let port: Int
        let secure: Bool
        let token: String
        let lport: Int
        let lan: Bool
    }

    private static func randomBase64(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // An RNG failure must never silently mint an all-zero pairing key — crash loud instead.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
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

    private static func keychainSet(_ data: Data) -> OSStatus {
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        // Device-only: the 256-bit E2E pairing key must not migrate off this Mac via
        // Keychain backup/sync — a re-pair is cheap, a leaked key is not.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
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
