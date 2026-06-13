import Foundation

/// Static configuration for the relay connection. The room is no longer here — it comes
/// from `PairingStore` (generated once, persisted in the Keychain, shown as a QR).
///
/// TODO: `authToken` is still an app-global hardcode (defense-in-depth on top of the room
/// bearer); fine for personal/dev use.
enum Config {
    static let host = "51.38.98.148"
    static let port = 59183
    static let path = "/ws"

    /// This device's role in the relay protocol; the peer is Android.
    static let device = "mac"
    static let peerDevice = "android"

    /// Local relay token from `server/.env` (RELAY_AUTH_TOKEN), sent as a Bearer header.
    static let authToken = "c94bff35f554588c211b520b935c583ef8f33bb25eab1932e52575e9926c1804"

    /// `ws://51.38.98.148:59183/ws` — token travels in the Authorization header, not the URL.
    static var relayURL: URL {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = path
        return components.url!
    }
}
