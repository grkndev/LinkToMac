import Foundation

/// Configuration for the relay connection. Host/port/token are injected from build settings
/// (`Config.xcconfig`, overridden by the gitignored `Secrets.xcconfig`) → Info.plist → here,
/// so the secret never lives in tracked source. The room is not here — it comes from
/// `PairingStore` (generated once, persisted in the Keychain, shown as a QR).
enum Config {
    static let host = info("RelayHost")
    static let port = Int(info("RelayPort")) ?? 0
    static let path = "/ws"

    /// This device's role in the relay protocol; the peer is Android.
    static let device = "mac"
    static let peerDevice = "android"

    /// Relay token (RELAY_AUTH_TOKEN), sent as a Bearer header — defense-in-depth on top of the
    /// room bearer. Injected from `Secrets.xcconfig`; empty until you create that file.
    static let authToken = info("RelayAuthToken")

    /// `ws://<RelayHost>:<RelayPort>/ws` — token travels in the Authorization header, not the URL.
    static var relayURL: URL {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = path
        return components.url!
    }

    /// Read a string from the app's Info.plist (populated from build settings at build time).
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
