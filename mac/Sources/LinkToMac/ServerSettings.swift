import Foundation
import Security

/// Runtime-configured relay endpoint. Replaces the old build-time `Config.xcconfig` values:
/// the user enters these in the "Server Settings…" window, and they're embedded in the pairing
/// QR so the phone auto-configures on scan. `token` is the operator-defined relay password.
struct ServerSettings: Sendable, Equatable {
    var host: String
    var port: Int
    var secure: Bool // wss:// when true, ws:// when false
    var token: String
    /// LAN-direct: this Mac runs a WebSocket server on `lanPort` and advertises it over Bonjour so
    /// a phone on the same network connects without the relay. `lanEnabled` gates it (default on).
    var lanEnabled: Bool
    var lanPort: Int

    /// True once a host has been entered — the relay won't connect until then.
    var isConfigured: Bool { !host.isEmpty }
}

/// Persists `ServerSettings`: non-secret fields in `UserDefaults`, the `token` in the Keychain
/// (same service as the pairing secret). All static + nonisolated; UserDefaults and the Keychain
/// are thread-safe, so `Config` can read these from any context.
enum ServerSettingsStore {
    private static let service = "dev.grkn.LinkToMac"
    private static let tokenAccount = "serverToken"
    private static let kHost = "relayHost"
    private static let kPort = "relayPort"
    private static let kSecure = "relaySecure"
    private static let kLanEnabled = "lanEnabled"
    private static let kLanPort = "lanPort"
    static let defaultLanPort = 53124

    static func load() -> ServerSettings {
        let d = UserDefaults.standard
        return ServerSettings(
            host: d.string(forKey: kHost) ?? "",
            port: d.object(forKey: kPort) as? Int ?? 443,
            secure: d.object(forKey: kSecure) as? Bool ?? true,
            token: keychainGet() ?? "",
            lanEnabled: d.object(forKey: kLanEnabled) as? Bool ?? true,
            lanPort: d.object(forKey: kLanPort) as? Int ?? defaultLanPort
        )
    }

    static func save(_ s: ServerSettings) {
        let d = UserDefaults.standard
        d.set(s.host, forKey: kHost)
        d.set(s.port, forKey: kPort)
        d.set(s.secure, forKey: kSecure)
        d.set(s.lanEnabled, forKey: kLanEnabled)
        d.set(s.lanPort, forKey: kLanPort)
        keychainSet(s.token)
    }

    // MARK: - Keychain (generic password)

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
        ]
    }

    private static func keychainGet() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainSet(_ token: String) {
        SecItemDelete(baseQuery() as CFDictionary)
        guard !token.isEmpty else { return }
        var add = baseQuery()
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
