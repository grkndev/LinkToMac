import Foundation
import Testing

/// Stage 1.9: the log rule for the QUIC code, enforced by reading the sources (the Mac half of what
/// `mobile/scripts/check-log-privacy.mjs` does for the phone).
///
/// The rule: a QUIC log line is a fixed sentence. It never interpolates a value, and nothing in its
/// arguments is named after a secret — the peer's address, the port, the certificate fingerprint,
/// the session token, the session id, or the offer that carries all of them.
///
/// Like the phone's checker this looks at NAMES, not values: `let x = tok; log("\(x)")` is caught only by
/// the interpolation rule, and `NSLog("%@", x)` with an innocently named `x` is not caught at all. That
/// is why the interpolation ban is absolute and why the second line of defence (the diagnostics
/// sanitizer on the phone) exists.
enum QuicLogRule {
    struct Violation: Equatable { let call: String; let why: String }

    /// Names that must not appear in a log call's code (outside string literals).
    static let forbidden: Set<String> = [
        "tok", "fp", "port", "sid", "token", "fingerprint", "offer",
        "fpHex", "tokB64", "hostAddress", "lanHost", "sessionId", "certFingerprint",
    ]

    static let callStarts = ["quicLog.", "NSLog(", "print(", "debugPrint(", "os_log(", "logger."]

    static func scan(_ source: String) -> [Violation] {
        let chars = Array(source)
        var found: [Violation] = []
        var i = 0
        while i < chars.count {
            guard let start = callStarts.first(where: { matches($0, in: chars, at: i) }),
                  isBoundary(chars, before: i) else { i += 1; continue }
            // a call start that is itself a `quicLog.` member runs to its opening paren
            var j = i + start.count
            if start.hasSuffix(".") {
                while j < chars.count, chars[j] != "(", chars[j] != "\n" { j += 1 }
                guard j < chars.count, chars[j] == "(" else { i += 1; continue }
            } else {
                j -= 1   // points at the "("
            }
            let (args, end) = arguments(chars, openParen: j)
            let call = String(chars[i..<min(end + 1, chars.count)])
            for piece in args {
                switch piece {
                case .literal(let text, let interpolated):
                    if interpolated { found.append(Violation(call: call, why: "interpolates a value")) }
                    _ = text
                case .code(let code):
                    for word in identifiers(in: code) where forbidden.contains(word) {
                        found.append(Violation(call: call, why: "names \(word)"))
                    }
                }
            }
            i = max(end, i + 1)
        }
        return found
    }

    // MARK: lexing

    private enum Piece { case literal(String, interpolated: Bool); case code(String) }

    private static func matches(_ s: String, in chars: [Character], at i: Int) -> Bool {
        let n = Array(s)
        guard i + n.count <= chars.count else { return false }
        return Array(chars[i..<(i + n.count)]) == n
    }

    /// `quicLog` must not be the tail of a longer identifier (`mquicLog.`), and a `//` comment is not a call.
    private static func isBoundary(_ chars: [Character], before i: Int) -> Bool {
        if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_" { return false }
        var k = i
        while k > 0, chars[k - 1] != "\n" { k -= 1 }
        let linePrefix = String(chars[k..<i])
        return !linePrefix.contains("//")
    }

    private static func identifiers(in code: String) -> [String] {
        var words: [String] = []; var cur = ""
        for c in code {
            if c.isLetter || c.isNumber || c == "_" { cur.append(c) } else { if !cur.isEmpty { words.append(cur); cur = "" } }
        }
        if !cur.isEmpty { words.append(cur) }
        return words
    }

    /// Splits the argument list of the call whose "(" is at `openParen` into literal and code pieces; returns the index of its ")".
    private static func arguments(_ chars: [Character], openParen: Int) -> ([Piece], Int) {
        var pieces: [Piece] = []
        var depth = 0
        var code = ""
        var k = openParen
        while k < chars.count {
            let c = chars[k]
            if c == "\"" {
                if !code.isEmpty { pieces.append(.code(code)); code = "" }
                var lit = ""; var interpolated = false
                k += 1
                while k < chars.count, chars[k] != "\"" {
                    if chars[k] == "\\", k + 1 < chars.count {
                        if chars[k + 1] == "(" { interpolated = true }
                        lit.append(chars[k]); lit.append(chars[k + 1]); k += 2; continue
                    }
                    lit.append(chars[k]); k += 1
                }
                pieces.append(.literal(lit, interpolated: interpolated))
            } else if c == "(" {
                depth += 1; if depth > 1 { code.append(c) }
            } else if c == ")" {
                depth -= 1
                if depth == 0 { if !code.isEmpty { pieces.append(.code(code)) }; return (pieces, k) }
                code.append(c)
            } else {
                code.append(c)
            }
            k += 1
        }
        return (pieces, chars.count - 1)
    }
}

@Suite("QUIC log privacy (stage 1.9)")
struct QuicLogPrivacyTests {
    // MARK: the checker itself — it must catch real leaks and stay quiet on the sentences the app writes

    @Test(arguments: [
        #"quicLog.info("port \(port)")"#,
        #"quicLog.error("connect failed: \(error)")"#,
        #"NSLog("[QuicTest] token %@", token)"#,
        #"NSLog("pinned %@", fingerprint)"#,
        #"quicLog.info("offer sent", offer)"#,
        #"print("session \(sid)")"#,
        #"logger.debug("listening", port)"#,
        #"quicLog.info("x \(String(describing: tok))")"#,
    ])
    func catchesTheLeaks(_ line: String) {
        #expect(!QuicLogRule.scan(line).isEmpty, "should have been flagged: \(line)")
    }

    @Test(arguments: [
        #"quicLog.info("listener ready")"#,
        #"quicLog.error("session write failed")"#,
        #"NSLog("[QuicTest] %@", text)"#,
        #"quicLog.info("the port, the fp and the tok stay out of the log")"#,
        #"let port = 53125   // quicLog.info("port \(port)") is only a comment"#,
        #"let ready = listener.port != nil"#,
        #"mquicLog.info("not our logger \(port)")"#,
    ])
    func staysQuietOnFixedSentences(_ line: String) {
        #expect(QuicLogRule.scan(line).isEmpty, "false alarm: \(line)")
    }

    @Test func aMultiLineCallIsScannedToItsClosingParen() {
        let src = """
        quicLog.info(
            "refused"
        )
        quicLog.info("a \\(sid)")
        """
        #expect(QuicLogRule.scan(src).count == 1)
    }

    @Test func reportsTheOffendingCall() {
        let v = QuicLogRule.scan(#"quicLog.info("port \(port)")"#)
        #expect(v.first?.why == "interpolates a value")
        #expect(v.first?.call.hasPrefix("quicLog.info(") == true)
    }

    // MARK: the repository itself

    private static var quicSources: [URL] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()   // mac/
            .appendingPathComponent("Sources/LinkToMac/Quic")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func theQuicSourcesAreFound() {
        let names = Self.quicSources.map(\.lastPathComponent)
        for n in ["QuicListener.swift", "QuicService.swift", "QuicSession.swift", "QuicControl.swift"] {
            #expect(names.contains(n), "\(n) not found — the check below would pass on nothing")
        }
    }

    @Test func noQuicLogLineCarriesASecret() throws {
        for file in Self.quicSources {
            let violations = QuicLogRule.scan(try String(contentsOf: file, encoding: .utf8))
            #expect(violations.isEmpty, "\(file.lastPathComponent): \(violations)")
        }
    }

    @Test func theRealSourcesDoContainLogCalls() throws {
        // A checker that finds no calls at all would also "pass". The listener is known to log.
        let listener = try String(contentsOf: Self.quicSources.first { $0.lastPathComponent == "QuicListener.swift" }!, encoding: .utf8)
        #expect(listener.contains("quicLog.info(\"listener ready\")"))
        #expect(QuicLogRule.scan(listener).isEmpty)
    }
}
