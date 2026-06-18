import Foundation

/// Configuration for the relay connection. The endpoint (host/port/secure/token) is no longer
/// baked into the build — it's entered at runtime in the "Server Settings…" window and read
/// from `ServerSettingsStore`. The room is separate: it comes from `PairingStore` (generated
/// once, persisted in the Keychain, shown as a QR).
enum Config {
    static let path = "/ws"

    /// This device's role in the relay protocol; the peer is Android.
    static let device = "mac"
    static let peerDevice = "android"

    // Endpoint values come from the runtime store, so changes apply on the next connect / QR render.
    static var host: String { ServerSettingsStore.load().host }
    static var port: Int { ServerSettingsStore.load().port }
    static var secure: Bool { ServerSettingsStore.load().secure }

    /// Operator-defined relay password, sent as a Bearer header. Empty until configured.
    static var authToken: String { ServerSettingsStore.load().token }

    /// LAN-direct (relay-less) server settings, embedded in the QR so the phone configures itself.
    static var lanEnabled: Bool { ServerSettingsStore.load().lanEnabled }
    static var lanPort: Int { ServerSettingsStore.load().lanPort }

    /// `ws(s)://<host>:<port>/ws` — token travels in the Authorization header, not the URL.
    /// Returns a non-connectable placeholder when unconfigured (callers gate on `host` first).
    static var relayURL: URL {
        let s = ServerSettingsStore.load()
        var components = URLComponents()
        components.scheme = s.secure ? "wss" : "ws"
        components.host = s.host
        components.port = s.port
        components.path = path
        return components.url ?? URL(string: "ws://0.0.0.0/ws")!
    }
}
