import Foundation

// The `q.*` actions that open and close a QUIC session (plan stage 1.3). They travel as a JSON string inside the E2E `cmd` envelope
// (stage 1.1 sends it, stage 1.2 receives it on the phone). Foundation only, so the same logic is compiled into the unit-test bundle.
// The Kotlin twin is `quic/QuicControl.kt`: the rules and the canonical output must stay byte-identical (change both together).

enum QuicKind: String, Sendable, Equatable {
    case cast, file, audio, cam
    /// Debug builds only (`allowEcho`): the session echoes bytes back, for the stage 1.6 / 1.7 tests.
    case echo
}

enum QuicRejectReason: String, Sendable, Equatable { case relay, busy, denied, unsupported, timeout }

/// The Mac's answer to a request: where to connect (`port`), which certificate to pin (`fp`) and the one-time session token (`tok`).
struct QuicOffer: Equatable, Sendable {
    let sid: String
    let port: Int
    let fp: String
    let tok: String
}

enum QuicAction: Equatable, Sendable {
    case request(sid: String, kind: QuicKind)
    case accept(sid: String)
    case offer(QuicOffer)
    case reject(sid: String, reason: QuicRejectReason)
    case end(sid: String)

    var sid: String {
        switch self {
        case let .request(sid, _), let .accept(sid), let .reject(sid, _), let .end(sid): return sid
        case let .offer(offer): return offer.sid
        }
    }
}

/// `unknown` = a JSON object whose `a` is missing or not one of the five: ignored quietly so a newer peer cannot break an older one.
/// `invalid` = a known `a` with bad fields: a short fixed code (`too-large`, `bad-json`, `sid`, `kind`, `port`, `fp`, `tok`, `reason`).
enum QuicParse: Equatable, Sendable {
    case action(QuicAction)
    case unknown
    case invalid(String)
}

enum QuicControl {
    /// An action is at most this many UTF-8 bytes; checked before parsing, so a hostile frame cannot cost real work.
    static let maxActionBytes = 4096

    /// Never throws. Unknown extra fields are ignored. `allowEcho` is true only in a debug build.
    static func parse(_ action: String, allowEcho: Bool) -> QuicParse {
        guard action.utf8.count <= maxActionBytes else { return .invalid("too-large") }
        guard let data = action.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any] else { return .invalid("bad-json") }
        guard let name = object["a"] as? String else { return .unknown }

        switch name {
        case "q.req":
            guard let sid = sid(object) else { return .invalid("sid") }
            guard let kind = kind(object, allowEcho: allowEcho) else { return .invalid("kind") }
            return .action(.request(sid: sid, kind: kind))
        case "q.accept":
            guard let sid = sid(object) else { return .invalid("sid") }
            return .action(.accept(sid: sid))
        case "q.end":
            guard let sid = sid(object) else { return .invalid("sid") }
            return .action(.end(sid: sid))
        case "q.reject":
            guard let sid = sid(object) else { return .invalid("sid") }
            guard let raw = object["reason"] as? String, let reason = QuicRejectReason(rawValue: raw) else { return .invalid("reason") }
            return .action(.reject(sid: sid, reason: reason))
        case "q.offer":
            guard let sid = sid(object) else { return .invalid("sid") }
            guard let port = port(object) else { return .invalid("port") }
            guard let fp = fingerprint(object) else { return .invalid("fp") }
            guard let tok = token(object) else { return .invalid("tok") }
            return .action(.offer(QuicOffer(sid: sid, port: port, fp: fp, tok: tok)))
        default:
            return .unknown
        }
    }

    /// The canonical wire form: keys in alphabetical order, no whitespace, built from a template (not a serializer), so the Mac and the
    /// phone write the same bytes for the same action. A session id is lower-cased. Callers pass validated values.
    static func encode(_ action: QuicAction) -> String {
        switch action {
        case let .request(sid, kind):
            return #"{"a":"q.req","kind":"\#(kind.rawValue)","sid":"\#(sid.lowercased())"}"#
        case let .accept(sid):
            return #"{"a":"q.accept","sid":"\#(sid.lowercased())"}"#
        case let .offer(o):
            return #"{"a":"q.offer","fp":"\#(o.fp)","port":\#(o.port),"sid":"\#(o.sid.lowercased())","tok":"\#(o.tok)"}"#
        case let .reject(sid, reason):
            return #"{"a":"q.reject","reason":"\#(reason.rawValue)","sid":"\#(sid.lowercased())"}"#
        case let .end(sid):
            return #"{"a":"q.end","sid":"\#(sid.lowercased())"}"#
        }
    }

    // MARK: field validation (the Kotlin side applies the same rules)

    /// Canonical 8-4-4-4-12 UUID, either case in, lower case out.
    private static func sid(_ o: [String: Any]) -> String? {
        guard let s = o["sid"] as? String, s.utf8.count == 36 else { return nil }
        for (i, c) in s.utf8.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if c != UInt8(ascii: "-") { return nil }
            } else if !isHex(c) {
                return nil
            }
        }
        return s.lowercased()
    }

    private static func kind(_ o: [String: Any], allowEcho: Bool) -> QuicKind? {
        guard let raw = o["kind"] as? String, let k = QuicKind(rawValue: raw) else { return nil }
        return (k == .echo && !allowEcho) ? nil : k
    }

    /// A JSON integer literal 1024...65535. Not a boolean, not a float (`53125.0` and `5.3125e4` are floats), not a string.
    private static func port(_ o: [String: Any]) -> Int? {
        guard let n = o["port"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(n) else { return nil }
        let d = n.doubleValue
        guard d >= 1024, d <= 65535, d == d.rounded() else { return nil }
        return Int(d)
    }

    /// Exactly 64 lower-case hex characters (the SHA-256 of the Mac's certificate).
    private static func fingerprint(_ o: [String: Any]) -> String? {
        guard let s = o["fp"] as? String, s.utf8.count == 64 else { return nil }
        for c in s.utf8 where !(c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) && !(c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f")) { return nil }
        return s
    }

    /// 32 random bytes as unpadded base64url: exactly 43 characters, and the canonical encoding (re-encoding gives the same text).
    private static func token(_ o: [String: Any]) -> String? {
        guard let s = o["tok"] as? String, s.utf8.count == 43 else { return nil }
        for c in s.utf8 where !isBase64URL(c) { return nil }
        let standard = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let raw = Data(base64Encoded: standard), raw.count == 32 else { return nil }
        let again = raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return again == s ? s : nil
    }

    private static func isHex(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "F"))
    }

    private static func isBase64URL(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) || (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-") || c == UInt8(ascii: "_")
    }
}

enum QuicSide: Equatable, Sendable { case mac, phone }

/// The rules of the handshake for ONE session, as pure logic with an injected clock (milliseconds). Four views: the Mac or the phone, as the
/// side that asked or the side that was asked. The offer is always the Mac's (it is the QUIC server).
///
///   Mac asked:    awaitingAccept --accept--> mayOffer --send offer--> offered      (the phone's user must say yes; no accept in time: timedOut)
///   Phone asked:  Mac: mayOffer (no accept step) --send offer--> offered
///   Phone asked:  phone: awaitingOffer --offer--> offered
///   Mac asked:    phone: awaitingUser --send accept--> awaitingOffer --offer--> offered   (no answer in time: timedOut)
///
/// Anything else is `ignored` with a fixed code and changes nothing. After `closed` everything is ignored. The offer / session wait times of
/// stages 1.6 and 1.8 are not here; only the accept wait (60 s by default, stage 3.2) is.
struct QuicHandshake {
    enum Phase: Equatable, Sendable {
        case awaitingAccept(deadlineMs: Int64)   // Mac asked, waits for the phone's accept
        case awaitingUser(deadlineMs: Int64)     // phone was asked, waits for its user
        case awaitingOffer                       // phone waits for the Mac's offer
        case mayOffer                            // Mac may send the offer
        case offered(QuicOffer)
        case closed(Close)
    }

    enum Close: Equatable, Sendable { case ended, rejected(QuicRejectReason), timedOut }

    enum Verdict: Equatable, Sendable {
        case applied(Phase)
        case ignored(String)
    }

    let side: QuicSide
    let iRequested: Bool
    let sid: String
    private(set) var phase: Phase

    init(side: QuicSide, iRequested: Bool, sid: String, nowMs: Int64, acceptTimeoutMs: Int64 = 60_000) {
        self.side = side
        self.iRequested = iRequested
        self.sid = sid.lowercased()
        switch (side, iRequested) {
        case (.mac, true): phase = .awaitingAccept(deadlineMs: nowMs + acceptTimeoutMs)
        case (.mac, false): phase = .mayOffer
        case (.phone, true): phase = .awaitingOffer
        case (.phone, false): phase = .awaitingUser(deadlineMs: nowMs + acceptTimeoutMs)
        }
    }

    /// Moves a phase that is waiting for an answer to `closed(.timedOut)` once its deadline has passed (`now >= deadline`).
    @discardableResult
    mutating func tick(nowMs: Int64) -> Phase {
        switch phase {
        case let .awaitingAccept(deadline), let .awaitingUser(deadline):
            if nowMs >= deadline { phase = .closed(.timedOut) }
        default: break
        }
        return phase
    }

    /// An action from the peer.
    mutating func receive(_ action: QuicAction, nowMs: Int64) -> Verdict {
        tick(nowMs: nowMs)
        if case .closed = phase { return .ignored("closed") }
        guard action.sid.lowercased() == sid else { return .ignored("sid") }
        switch action {
        case .request:
            return .ignored("unexpected-request")
        case .end:
            return apply(.closed(.ended))
        case let .reject(_, reason):
            switch (side, iRequested, phase) {
            case (.mac, true, .awaitingAccept), (.phone, true, .awaitingOffer): return apply(.closed(.rejected(reason)))
            default: return .ignored("unexpected-reject")
            }
        case .accept:
            if side == .mac, iRequested, case .awaitingAccept = phase { return apply(.mayOffer) }
            return .ignored("unexpected-accept")
        case let .offer(offer):
            guard side == .phone else { return .ignored("unexpected-offer") }
            switch phase {
            case .awaitingOffer: return apply(.offered(offer))
            case .awaitingUser: return .ignored("offer-before-accept")
            case .offered: return .ignored("duplicate-offer")
            default: return .ignored("unexpected-offer")
            }
        }
    }

    /// An action this side wants to send; applied only when the rules allow it.
    mutating func send(_ action: QuicAction, nowMs: Int64) -> Verdict {
        tick(nowMs: nowMs)
        if case .closed = phase { return .ignored("closed") }
        guard action.sid.lowercased() == sid else { return .ignored("sid") }
        switch action {
        case .request:
            return .ignored("request-not-allowed")
        case .end:
            return apply(.closed(.ended))
        case let .offer(offer):
            if side == .mac, case .mayOffer = phase { return apply(.offered(offer)) }
            return .ignored("offer-not-allowed")
        case let .reject(_, reason):
            switch (side, iRequested, phase) {
            case (.mac, false, .mayOffer), (.phone, false, .awaitingUser): return apply(.closed(.rejected(reason)))
            default: return .ignored("reject-not-allowed")
            }
        case .accept:
            if side == .phone, !iRequested, case .awaitingUser = phase { return apply(.awaitingOffer) }
            return .ignored("accept-not-allowed")
        }
    }

    private mutating func apply(_ next: Phase) -> Verdict {
        phase = next
        return .applied(next)
    }
}

// MARK: - stat.caps (stage 1.4)

/// `stat.caps`: how each side learns whether the other speaks the QUIC session protocol (`q1`). The field is optional and the `stat`
/// frame is additive, so a receiver only updates what is present: a stat WITHOUT `caps` (battery, proximity, media) never clobbers it.
/// The Kotlin twin is `QuicCaps` in `quic/QuicControl.kt`; both run `protocol-vectors/quic-control.json` (section `stat`).
enum QuicCaps {
    /// The QUIC session protocol, version 1.
    static let q1 = "q1"

    /// The names this build understands; any other name in a peer's `caps` is ignored.
    static let known: Set<String> = [q1]

    enum Update: Equatable, Sendable {
        /// No usable `caps` in the stat: the receiver keeps what it has.
        case absent
        /// The peer's capabilities (the known ones), possibly empty: it says it supports none.
        case set(Set<String>)
    }

    /// What this side writes into its own `stat`: `["q1"]` once it can actually serve the protocol, nothing before. (Advertising a
    /// capability that does not exist yet would make the peer offer sessions this side cannot answer.)
    static func advertised(supportsQuic: Bool) -> [String] { supportsQuic ? [q1] : [] }

    /// The `"caps":["q1"]` piece for a hand-built `stat` JSON object, or nil when nothing is advertised (the frame stays as it was).
    static func statFragment(supportsQuic: Bool) -> String? {
        let names = advertised(supportsQuic: supportsQuic)
        guard !names.isEmpty else { return nil }
        return #""caps":["# + names.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// Reads `caps` from a decoded stat object. Anything that is not an array (missing, a string, a number, an object, null) is `absent`,
    /// so a malformed field cannot wipe what is known. In an array, unknown names and non-string items are ignored.
    static func parse(stat: [String: Any]) -> Update {
        guard let raw = stat["caps"] as? [Any] else { return .absent }
        return .set(Set(raw.compactMap { $0 as? String }.filter { known.contains($0) }))
    }

    /// QUIC is usable only on the LAN-direct link and only when the peer is known to speak `q1`. The one gate the UI will use (stage 1.8).
    static func available(onLan: Bool, caps: Set<String>) -> Bool { onLan && caps.contains(q1) }
}

/// What a side knows about the peer's capabilities. Empty until a `stat` carrying `caps` arrives, so an old peer (no `caps` ever) is
/// "not supported", and emptied again when the peer goes offline so a stale answer cannot outlive the session it came from.
struct PeerCaps: Equatable, Sendable {
    private(set) var caps: Set<String>

    init(caps: Set<String> = []) { self.caps = caps }

    mutating func applyStat(_ stat: [String: Any]) {
        if case let .set(set) = QuicCaps.parse(stat: stat) { caps = set }
    }

    /// The peer is gone (the only link it had).
    mutating func peerWentOffline() { caps = [] }

    /// For the Mac, where one phone can be on the relay AND on the LAN: forget the capabilities only when it has left both.
    mutating func linksChanged(relayOnline: Bool, lanConnected: Bool) {
        if !relayOnline && !lanConnected { caps = [] }
    }

    func quicAvailable(onLan: Bool) -> Bool { QuicCaps.available(onLan: onLan, caps: caps) }
}
