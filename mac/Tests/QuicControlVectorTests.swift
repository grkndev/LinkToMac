import Foundation
import Testing

/// The QUIC control plane's shared vectors (plan stage 1.5): `protocol-vectors/quic-control.json`, sections `constants`, `actions`,
/// `channels` and `handshake` (the `stat` section is `QuicCapsVectorTests`). The phone's `QuicControlVectorTest` runs the SAME file against
/// the Kotlin twin, and the Rust core checks the ALPN — so a rule can only change by changing the file, and then every side must follow.
@Suite struct QuicControlVectorTests {
    nonisolated(unsafe) private static let doc: [String: Any] = {  // read-only after the first load
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol-vectors/quic-control.json")
        let data = try? Data(contentsOf: url)
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }()

    private func cases(_ section: String) -> [[String: Any]] {
        ((Self.doc[section] as? [String: Any])?["cases"] as? [[String: Any]]) ?? []
    }

    private func name(_ c: [String: Any]) -> String { c["name"] as? String ?? "?" }

    @Test func theVectorFileHasTheSectionsThisSuiteRuns() {
        #expect(Self.doc["constants"] != nil)
        #expect(!cases("actions").isEmpty)
        #expect(!cases("channels").isEmpty)
        #expect(!cases("handshake").isEmpty)
    }

    // MARK: constants

    @Test func constantsMatchTheFile() {
        let values = (Self.doc["constants"] as? [String: Any])?["values"] as? [String: Any] ?? [:]
        #expect(QuicControl.alpn == values["alpn"] as? String)
        #expect(QuicControl.maxActionBytes == values["max_action_bytes"] as? Int)
        #expect(QuicHandshake.defaultAcceptTimeoutMs == (values["accept_timeout_ms"] as? NSNumber)?.int64Value)
    }

    // MARK: actions

    /// `{PAD}` in `text` becomes `pad.char` repeated: up to a total of `to_bytes` UTF-8 bytes, or `count` times.
    private func text(of c: [String: Any]) -> String {
        let raw = c["text"] as? String ?? ""
        guard let pad = c["pad"] as? [String: Any], let ch = pad["char"] as? String else { return raw }
        let count: Int
        if let total = pad["to_bytes"] as? Int {
            let base = raw.replacingOccurrences(of: "{PAD}", with: "").utf8.count
            count = (total - base) / max(ch.utf8.count, 1)
        } else {
            count = pad["count"] as? Int ?? 0
        }
        return raw.replacingOccurrences(of: "{PAD}", with: String(repeating: ch, count: count))
    }

    @Test func parseVectors() {
        for c in cases("actions") where c["kind"] as? String == "parse" {
            let expect = c["expect"] as? [String: Any] ?? [:]
            let parsed = QuicControl.parse(text(of: c), allowEcho: c["allow_echo"] as? Bool ?? false)
            switch (expect["result"] as? String, parsed) {
            case let ("action", .action(action)):
                #expect(QuicControl.encode(action) == expect["encoded"] as? String, "\(name(c))")
            case ("unknown", .unknown):
                break
            case let ("invalid", .invalid(code)):
                #expect(code == expect["code"] as? String, "\(name(c))")
            default:
                Issue.record("\(name(c)): got \(parsed), the file expects \(expect)")
            }
        }
    }

    /// Builds an action the way a peer would put it on the wire (a JSON object), so scenarios and encode cases go through `parse`.
    private func action(from object: [String: Any]) -> QuicAction? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8),
              case let .action(action) = QuicControl.parse(string, allowEcho: true) else { return nil }
        return action
    }

    @Test func encodeVectors() {
        for c in cases("actions") where c["kind"] as? String == "encode" {
            guard let action = action(from: c["action"] as? [String: Any] ?? [:]) else {
                Issue.record("\(name(c)): the action object does not parse"); continue
            }
            let encoded = QuicControl.encode(action)
            #expect(encoded == c["expect"] as? String, "\(name(c))")
            // Every canonical string must read back as the same action.
            if case let .action(back) = QuicControl.parse(encoded, allowEcho: true) {
                #expect(back == action, "\(name(c)): round trip")
            } else {
                Issue.record("\(name(c)): the encoded string does not parse")
            }
        }
    }

    // MARK: channels

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0
        }
    }

    private func channel(_ name: String?) -> QuicChannel? {
        switch name {
        case "file": return .file
        case "screen": return .screen
        case "camera": return .camera
        default: return nil
        }
    }

    @Test func channelHeaderVectors() {
        for c in cases("channels") where c["kind"] as? String == "header" {
            guard let ch = channel(c["channel"] as? String) else { Issue.record("\(name(c)): unknown channel"); continue }
            #expect(ch.header == bytes(c["hex"] as? String ?? ""), "\(name(c))")
            #expect(ch.isBidirectional == (c["direction"] as? String == "bidi"), "\(name(c)): direction")
        }
    }

    @Test func channelParseVectors() {
        for c in cases("channels") where c["kind"] as? String == "parse" {
            let expect = c["expect"] as? [String: Any] ?? [:]
            let parsed = QuicChannel.parse(bytes(c["hex"] as? String ?? ""))
            switch (expect["result"] as? String, parsed) {
            case let ("channel", .channel(ch, consumed)):
                #expect(ch == channel(expect["channel"] as? String), "\(name(c))")
                #expect(consumed == expect["consumed"] as? Int, "\(name(c))")
            case let ("unknown", .unknown(value, consumed)):
                #expect(Int(value) == expect["value"] as? Int, "\(name(c))")
                #expect(consumed == expect["consumed"] as? Int, "\(name(c))")
            case ("needMoreBytes", .needMoreBytes):
                break
            default:
                Issue.record("\(name(c)): got \(parsed), the file expects \(expect)")
            }
        }
    }

    // MARK: handshake

    private func phaseObject(_ phase: QuicHandshake.Phase) -> NSDictionary {
        switch phase {
        case let .awaitingAccept(deadline): return ["name": "awaitingAccept", "deadline_ms": NSNumber(value: deadline)]
        case let .awaitingUser(deadline): return ["name": "awaitingUser", "deadline_ms": NSNumber(value: deadline)]
        case .awaitingOffer: return ["name": "awaitingOffer"]
        case .mayOffer: return ["name": "mayOffer"]
        case .offered: return ["name": "offered"]
        case let .closed(close):
            switch close {
            case .ended: return ["name": "closed", "close": "ended"]
            case .timedOut: return ["name": "closed", "close": "timedOut"]
            case let .rejected(reason): return ["name": "closed", "close": "rejected", "reason": reason.rawValue]
            }
        }
    }

    private func samePhase(_ phase: QuicHandshake.Phase, _ expected: Any?) -> Bool {
        guard let expected = expected as? [String: Any] else { return false }
        return phaseObject(phase).isEqual(to: expected)
    }

    private func ms(_ any: Any?) -> Int64 { (any as? NSNumber)?.int64Value ?? 0 }

    @Test func handshakeVectors() {
        for scenario in cases("handshake") {
            let side: QuicSide = scenario["side"] as? String == "mac" ? .mac : .phone
            var hs = QuicHandshake(side: side, iRequested: scenario["asker"] as? Bool ?? false,
                                   sid: "123e4567-e89b-12d3-a456-426614174000", nowMs: ms(scenario["start_ms"]),
                                   acceptTimeoutMs: scenario["timeout_ms"].map { ms($0) } ?? QuicHandshake.defaultAcceptTimeoutMs)
            #expect(samePhase(hs.phase, scenario["initial"]), "\(name(scenario)): initial phase \(hs.phase)")
            for (i, step) in (scenario["steps"] as? [[String: Any]] ?? []).enumerated() {
                let where_ = "\(name(scenario)) step \(i)"
                let expect = step["expect"] as? [String: Any] ?? [:]
                let at = ms(step["at_ms"])
                if step["op"] as? String == "tick" {
                    #expect(samePhase(hs.tick(nowMs: at), expect["phase"]), "\(where_): phase \(hs.phase)")
                    continue
                }
                guard let act = action(from: step["action"] as? [String: Any] ?? [:]) else {
                    Issue.record("\(where_): the action object does not parse"); continue
                }
                let verdict = step["op"] as? String == "send" ? hs.send(act, nowMs: at) : hs.receive(act, nowMs: at)
                switch verdict {
                case let .applied(phase):
                    #expect(samePhase(phase, expect["applied"]), "\(where_): applied \(phase), the file expects \(expect)")
                case let .ignored(code):
                    #expect(code == expect["ignored"] as? String, "\(where_): ignored \(code), the file expects \(expect)")
                }
                if let then = step["then"] { #expect(samePhase(hs.phase, then), "\(where_): afterwards \(hs.phase)") }
            }
        }
    }
}
