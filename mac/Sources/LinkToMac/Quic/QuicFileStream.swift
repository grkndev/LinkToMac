import Foundation

/// The bytes of one QUIC file stream (stage 2.2 of `docs/plans/2026-11-14-quic-data-plane.md`, Faz 2): one bidirectional stream per file.
///
///     sender   ->  0x01 (the file channel varint)  ‖  header message
///     receiver ->  {"have":N}  or  {"err":"…","ok":false}          (N = bytes it already holds, 0 <= N <= size)
///     sender   ->  exactly size - have raw bytes, then it closes its side
///     receiver ->  {"ok":true}  (only after the file is in its final place)  or  {"err":"…","ok":false}
///
/// Every message is `u16 BE length ‖ JSON`. Pure and Foundation only (compiled into `LinkToMacTests`); the Kotlin twin is `QuicFileStream` in
/// `quic/QuicFileStream.kt` and the Rust one is `quic-core/src/file.rs`. All three run the `file_stream` section of
/// `protocol-vectors/quic-control.json`, so every byte is pinned three times. Nothing here touches a socket or a file name: the receivers sanitise
/// the name and directory themselves (stages 2.3 / 2.4); this layer only checks the syntax and the limits.
enum QuicFileStream {
    static let headerMaxBytes = 4096
    static let nameMaxBytes = 200
    static let mimeMaxBytes = 255
    /// How long a receiver waits for the first byte of a bidirectional stream before it ignores the stream (Network.framework's reserved,
    /// byte-less server-initiated stream, see the plan's stage 2.2 item 7).
    static let firstByteTimeoutMs = 2000
    static let sizeMax: Int64 = 9_007_199_254_740_991  // 2^53 - 1: every JSON library reads it exactly

    struct Header: Equatable, Sendable {
        var dir: String?
        var id: String
        var mime: String
        var mtime: Int64
        var name: String
        var size: Int64
    }

    /// The refusal codes on the wire.
    enum WireError: String, Sendable {
        case space, busy, write, size
        case badId = "bad-id"
        case tooMany = "too-many"
        case badHeader = "bad-header"
    }

    /// A refusal the peer sent: a code we know, or one a newer peer invented (or none at all).
    enum Refusal: Equatable, Sendable {
        case known(WireError)
        case unknown
    }

    enum HeaderInvalid: Equatable, Sendable {
        /// The first varint names another channel: not ours, nothing is answered.
        case notFile
        /// Anything wrong with the structure or the limits.
        case badHeader
        /// The structure is fine but `id` is not 8 lower-case hex (checked last).
        case badId
    }

    enum HeaderResult: Equatable, Sendable {
        case needMore
        /// The header, and how many bytes it used; later bytes belong to the body.
        case header(Header, consumed: Int)
        case invalid(HeaderInvalid)
    }

    /// Feeds the bytes the way a stream delivers them. The answer for the bytes so far; an `invalid` is final, `needMore` is not.
    struct HeaderDecoder: Sendable {
        private var buffer: [UInt8] = []
        mutating func feed(_ bytes: [UInt8]) -> HeaderResult {
            buffer += bytes
            return QuicFileStream.decodeHeader(buffer)
        }
    }

    // MARK: header

    /// What a sender writes first: the file channel varint and the header message (canonical JSON). The sender keeps the header within the
    /// limits (it shortens a long name the way the WebSocket path does); a header over `headerMaxBytes` would be refused.
    static func encodeHeader(_ h: Header) -> [UInt8] {
        var json = "{"
        if let dir = h.dir { json += "\"dir\":\(quoted(dir)),"}
        json += "\"id\":\(quoted(h.id)),\"mime\":\(quoted(h.mime)),\"mtime\":\(h.mtime),\"name\":\(quoted(h.name)),\"size\":\(h.size)}"
        return QuicChannel.file.header + message(json)
    }

    /// The answer for ALL the bytes received so far.
    static func decodeHeader(_ bytes: [UInt8]) -> HeaderResult {
        let channelLength: Int
        switch QuicChannel.parse(bytes) {
        case .needMoreBytes: return .needMore
        case .unknown: return .invalid(.notFile)
        case .channel(let channel, let consumed):
            guard channel == .file else { return .invalid(.notFile) }
            channelLength = consumed
        }
        guard bytes.count >= channelLength + 2 else { return .needMore }
        let length = Int(bytes[channelLength]) << 8 | Int(bytes[channelLength + 1])
        if length == 0 || length > headerMaxBytes { return .invalid(.badHeader) }  // known as soon as the two length bytes are
        let end = channelLength + 2 + length
        guard bytes.count >= end else { return .needMore }
        guard let header = parseHeaderBody(Array(bytes[(channelLength + 2)..<end])) else { return .invalid(.badHeader) }
        guard isId(header.id) else { return .invalid(.badId) }
        return .header(header, consumed: end)
    }

    /// Structure and limits. The id's PATTERN is checked by the caller afterwards so that a structural fault wins over a bad id.
    private static func parseHeaderBody(_ body: [UInt8]) -> Header? {
        guard let o = object(body) else { return nil }
        guard let name = o["name"] as? String, (1...nameMaxBytes).contains(name.utf8.count),
              let mime = o["mime"] as? String, (1...mimeMaxBytes).contains(mime.utf8.count),
              let size = integer(o["size"]), let mtime = integer(o["mtime"]),
              let id = o["id"] as? String else { return nil }
        var dir: String?
        if let raw = o["dir"] {
            guard let s = raw as? String else { return nil }
            dir = s
        }
        return Header(dir: dir, id: id, mime: mime, mtime: mtime, name: name, size: size)
    }

    private static func isId(_ s: String) -> Bool {
        s.utf8.count == 8 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    // MARK: answers

    static func encodeHave(_ have: Int64) -> [UInt8] { message("{\"have\":\(have)}") }

    /// `{"ok":true}`, or a refusal with its code (`{"err":"space","ok":false}`).
    static func encodeResult(ok: Bool, err: WireError? = nil) -> [UInt8] {
        if ok { return message("{\"ok\":true}") }
        if let err { return message("{\"err\":\"\(err.rawValue)\",\"ok\":false}") }
        return message("{\"ok\":false}")
    }

    enum HaveResult: Equatable, Sendable {
        case have(Int64)
        case refused(Refusal)
        case invalid
    }

    /// The first answer, as ONE complete message; `size` is the file's size (a `have` beyond it is invalid).
    static func parseHave(_ bytes: [UInt8], size: Int64) -> HaveResult {
        guard let body = messageBody(bytes), let o = object(body) else { return .invalid }
        if let ok = o["ok"] {
            guard let flag = bool(ok), flag == false else { return .invalid }  // `ok:true` is not an answer to the header
            return .refused(refusal(o["err"]))
        }
        guard let have = integer(o["have"]), have <= size else { return .invalid }
        return .have(have)
    }

    enum FinalResult: Equatable, Sendable {
        case ok
        case refused(Refusal)
        case invalid
    }

    /// The last answer, as ONE complete message.
    static func parseResult(_ bytes: [UInt8]) -> FinalResult {
        guard let body = messageBody(bytes), let o = object(body), let ok = o["ok"].flatMap(bool) else { return .invalid }
        return ok ? .ok : .refused(refusal(o["err"]))
    }

    // MARK: the body

    /// How many raw bytes follow the first answer, or nil when `have` is outside 0...size.
    static func bodyLength(size: Int64, have: Int64) -> Int64? {
        (size >= 0 && have >= 0 && have <= size) ? size - have : nil
    }

    enum Verdict: Equatable, Sendable {
        case ok
        case sizeMismatch
    }

    /// The sender closed its side after `received` bytes while `expected` were due.
    static func finishVerdict(expected: Int64, received: Int64) -> Verdict {
        expected == received ? .ok : .sizeMismatch
    }

    // MARK: framing and JSON

    /// How long the whole message is, once its two length bytes are known (nil before that).
    static func messageLength(prefix: [UInt8]) -> Int? {
        prefix.count >= 2 ? 2 + (Int(prefix[0]) << 8 | Int(prefix[1])) : nil
    }

    private static func message(_ json: String) -> [UInt8] {
        let body = Array(json.utf8)
        return [UInt8(body.count >> 8 & 0xff), UInt8(body.count & 0xff)] + body
    }

    /// The JSON of ONE complete message (length prefix matching the bytes), or nil.
    private static func messageBody(_ bytes: [UInt8]) -> [UInt8]? {
        guard let total = messageLength(prefix: bytes), total == bytes.count, total > 2, total - 2 <= headerMaxBytes else { return nil }
        return Array(bytes[2...])
    }

    private static func object(_ body: [UInt8]) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body), options: [])) as? [String: Any]
    }

    private static func bool(_ any: Any) -> Bool? {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// A JSON integer literal 0...sizeMax: not a boolean, not a float (`5.0` and `1e3` are floats), not a string.
    private static func integer(_ any: Any?) -> Int64? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n),
              n.compare(NSNumber(value: 0)) != .orderedAscending,
              n.compare(NSNumber(value: sizeMax)) != .orderedDescending else { return nil }
        return n.int64Value
    }

    private static func refusal(_ any: Any?) -> Refusal {
        guard let s = any as? String, let code = WireError(rawValue: s) else { return .unknown }
        return .known(code)
    }

    /// Canonical JSON string: `"` `\` and control characters escaped (`\b \f \n \r \t` short, the rest `\u00xx` lower case), everything else raw.
    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
