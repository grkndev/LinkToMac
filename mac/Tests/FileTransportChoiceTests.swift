import Foundation
import Testing

/// Which path a file takes (plan stage 2.1, Faz 2): runs the `transport` section of `protocol-vectors/quic-control.json`; the phone's
/// `FileTransportChoiceVectorTest` runs the same file. Also pins what no vector can: the WebSocket size limit is ONE number on both sides.
@Suite struct FileTransportChoiceTests {
    private func doc() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol-vectors/quic-control.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func cases() throws -> [[String: Any]] {
        ((try doc())["transport"] as? [String: Any])?["cases"] as? [[String: Any]] ?? []
    }

    private func name(_ c: [String: Any]) -> String { c["name"] as? String ?? "?" }

    private func choice(_ c: [String: Any]) -> FileTransportChoice {
        let link: FileTransportChoice.Link = (c["link"] as? String) == "lan" ? .lan : .relay
        let caps = Set((c["caps"] as? [String]) ?? [])
        let size = c["size"] as? Int64 ?? (c["size"] as? Int).map(Int64.init)
        return FileTransportChoice.choose(link: link, peerCaps: caps, size: size, isClipboardImage: c["clipboard"] as? Bool ?? false)
    }

    private func word(_ s: String?) -> FileTransportChoice? {
        switch s {
        case "quic": return .quic
        case "ws": return .ws
        case "waitForLan": return .waitForLan
        case "tooLarge": return .tooLarge
        default: return nil
        }
    }

    @Test func theVectorFileHasTheCasesThisSuiteRuns() throws {
        #expect(try cases().count == 72)
    }

    @Test func transportVectors() throws {
        for c in try cases() {
            #expect(choice(c) == word(c["expect"] as? String), "\(name(c))")
        }
    }

    /// 2 links x 3 capability sets x 6 sizes x 2 kinds: none may be missing and none may be doubled (a skipped combination is an unpinned behaviour).
    @Test func theVectorsAreTheFullCrossProduct() throws {
        var seen: [String] = []
        for c in try cases() {
            let caps = ((c["caps"] as? [String]) ?? []).joined(separator: "+")
            let size = (c["size"] is NSNull || c["size"] == nil) ? "null" : "\(c["size"] as? Int ?? -999)"
            let clip = (c["clipboard"] as? Bool ?? false) ? "1" : "0"
            seen.append("\(c["link"] as? String ?? "?")|\(caps)|\(size)|\(clip)")
        }
        let limit = 1_073_741_824
        var want = Set<String>()
        for link in ["lan", "relay"] {
            for caps in ["q1", "", "q2"] {
                for size in ["null", "0", "1", "\(limit)", "\(limit + 1)", "\(10 * limit)"] {
                    for clip in ["0", "1"] { want.insert("\(link)|\(caps)|\(size)|\(clip)") }
                }
            }
        }
        #expect(want.count == 72)
        #expect(seen.count == 72, "a combination is doubled or missing")
        #expect(Set(seen) == want)
    }

    @Test func theWebSocketLimitIsOneNumberOnBothSides() throws {
        let values = ((try doc())["constants"] as? [String: Any])?["values"] as? [String: Any]
        #expect(values?["ws_file_limit_bytes"] as? Int == FileFrame.maxTransferBytes)
        #expect(FileFrame.maxTransferBytes == 1_073_741_824)
    }

    @Test func theExactEdgeIsTheLimitItselfAndOneByteMore() {
        let limit = Int64(FileFrame.maxTransferBytes)
        for caps in [Set<String>(), ["q1"]] {
            #expect(FileTransportChoice.choose(link: .relay, peerCaps: caps, size: limit, isClipboardImage: false) == .ws)
        }
        #expect(FileTransportChoice.choose(link: .relay, peerCaps: ["q1"], size: limit + 1, isClipboardImage: false) == .waitForLan)
        #expect(FileTransportChoice.choose(link: .relay, peerCaps: [], size: limit + 1, isClipboardImage: false) == .tooLarge)
        #expect(FileTransportChoice.choose(link: .lan, peerCaps: [], size: limit + 1, isClipboardImage: false) == .tooLarge)
        #expect(FileTransportChoice.choose(link: .lan, peerCaps: ["q1"], size: limit + 1, isClipboardImage: false) == .quic)
    }

    @Test func aNegativeSizeIsAnUnknownSize() {
        for link in [FileTransportChoice.Link.lan, .relay] {
            for caps in [Set<String>(), ["q1"]] {
                #expect(FileTransportChoice.choose(link: link, peerCaps: caps, size: -1, isClipboardImage: false)
                        == FileTransportChoice.choose(link: link, peerCaps: caps, size: nil, isClipboardImage: false))
            }
        }
    }

    @Test func aClipboardImageNeverLeavesTheWebSocketPath() {
        for link in [FileTransportChoice.Link.lan, .relay] {
            for size in [nil, 0, 700_000, Int64(FileFrame.maxTransferBytes) + 1] as [Int64?] {
                #expect(FileTransportChoice.choose(link: link, peerCaps: ["q1"], size: size, isClipboardImage: true) == .ws)
            }
        }
    }

    /// Until the QUIC file stream exists (stage 2.5) a `.quic` verdict cannot be acted on: the call sites use `effective`, which keeps the
    /// WebSocket path, so nothing a user sees changes in stage 2.1.
    @Test func whileQuicFilesAreNotServedQuicEffectivelyMeansTheWebSocketPath() {
        #expect(FileTransportChoice.quicFilesServed == false)
        #expect(FileTransportChoice.quic.effective == .ws)
        #expect(FileTransportChoice.ws.effective == .ws)
        #expect(FileTransportChoice.waitForLan.effective == .waitForLan)
        #expect(FileTransportChoice.tooLarge.effective == .tooLarge)
    }

    @Test func theLogWordsAreFixedSentencesWithNothingAboutTheFile() {
        #expect(FileTransportChoice.quic.logWord == "quic")
        #expect(FileTransportChoice.ws.logWord == "ws")
        #expect(FileTransportChoice.waitForLan.logWord == "wait-for-lan")
        #expect(FileTransportChoice.tooLarge.logWord == "too-large")
    }
}
