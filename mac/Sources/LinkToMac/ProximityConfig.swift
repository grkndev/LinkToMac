import CryptoKit
import Foundation

/// Tunables + the shared BLE identity for proximity auto-lock.
///
/// The phone advertises a presence beacon under a service UUID derived from the pairing
/// `room`; the Mac scans for exactly that UUID. Deriving from the (secret, per-pairing) room
/// means we only ever react to *our* phone and the UUID rotates on unpair — no extra pairing.
enum ProximityConfig {
    /// Re-evaluate presence on this cadence. (The RSSI cutoff and the away-grace are now
    /// user-configurable — see `ProximityMonitor.sensitivity` / `.graceSeconds`.)
    static let evalInterval: TimeInterval = 2.5
    /// EMA smoothing factor for the noisy raw RSSI (0…1; higher = snappier).
    static let rssiAlpha = 0.4

    /// Deterministic 128-bit service UUID from the pairing room. MUST stay byte-identical to the
    /// Kotlin derivation: `SHA256(utf8(room))` → first 16 bytes → UUID (bytes in order).
    static func serviceUUID(room: String) -> UUID {
        let digest = SHA256.hash(data: Data(room.utf8))
        let b = Array(digest.prefix(16))
        let bytes: uuid_t = (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        )
        return UUID(uuid: bytes)
    }
}
