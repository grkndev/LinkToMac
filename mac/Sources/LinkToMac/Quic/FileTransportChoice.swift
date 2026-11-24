import Foundation

/// Which path ONE file takes (stage 2.1 of `docs/plans/2026-11-14-quic-data-plane.md`, Faz 2): a QUIC stream, the existing WebSocket `file`
/// path (TECHNICAL.md §5.4, limit 1 GiB), a wait for the LAN, or "too large". One pure function, so the rule lives in one place and the phone's
/// twin (`FileTransportChoice.kt`) can be held to the same answer by `protocol-vectors/quic-control.json` (section `transport`, the full
/// cross product). Foundation only (compiled into `LinkToMacTests`).
///
/// Rules, first match wins:
///  1. a clipboard image is `.ws` whatever its size (one frame; `ImagePrep` makes it fit);
///  2. the LAN-direct link and a peer that announced `q1` is `.quic` (no size limit, also when the size is not known yet);
///  3. a size that is not known is `.ws` (that path applies its own limit while it reads, as it always did);
///  4. a size up to and including the WebSocket limit is `.ws`;
///  5. above it: the relay with a `q1` peer is `.waitForLan` (QUIC will carry it once both are on the same LAN);
///  6. above it, anything else is `.tooLarge` (an older peer cannot do QUIC, so waiting for the LAN would not help).
enum FileTransportChoice: Equatable, Sendable {
    case quic
    case ws
    case waitForLan
    case tooLarge

    /// The link the file would travel on right now (the caller does not ask when there is no link at all).
    enum Link: Sendable {
        case lan
        case relay
    }

    /// Flipped to `true` in stage 2.5, when a QUIC file stream exists. Until then `.quic` cannot be acted on and [effective] keeps the WebSocket path.
    static let quicFilesServed = false

    /// `size` nil (or negative) = not known. The limit is the WebSocket path's own constant, so there is no second "1 GiB" to drift.
    static func choose(link: Link, peerCaps: Set<String>, size: Int64?, isClipboardImage: Bool) -> FileTransportChoice {
        if isClipboardImage { return .ws }
        let peerQuic = peerCaps.contains(QuicCaps.q1)
        if link == .lan && peerQuic { return .quic }
        guard let size, size >= 0 else { return .ws }
        if size <= Int64(FileFrame.maxTransferBytes) { return .ws }
        return (link == .relay && peerQuic) ? .waitForLan : .tooLarge
    }

    /// What the call sites act on while QUIC files are not served yet: a `.quic` verdict still goes over the WebSocket path.
    var effective: FileTransportChoice {
        (self == .quic && !Self.quicFilesServed) ? .ws : self
    }

    /// A fixed word for the log (nothing about the file or the peer).
    var logWord: String {
        switch self {
        case .quic: return "quic"
        case .ws: return "ws"
        case .waitForLan: return "wait-for-lan"
        case .tooLarge: return "too-large"
        }
    }
}
