import Foundation
import Testing

/// The QUIC file stream's bytes (plan stage 2.2, Faz 2): runs the `file_stream` section of `protocol-vectors/quic-control.json`. The phone's
/// `QuicFileStreamVectorTest` and the Rust core's `tests/vectors.rs` run the same file, so every byte on the stream is pinned three times.
@Suite struct QuicFileStreamTests {
    private func doc() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mac
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("protocol-vectors/quic-control.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func cases(_ kind: String) throws -> [[String: Any]] {
        let section = (try doc())["file_stream"] as? [String: Any]
        return ((section?["cases"] as? [[String: Any]]) ?? []).filter { $0["kind"] as? String == kind }
    }

    private func name(_ c: [String: Any]) -> String { c["name"] as? String ?? "?" }

    private func bytes(_ hex: String?) -> [UInt8] {
        let h = Array(hex ?? "")
        return stride(from: 0, to: h.count - 1, by: 2).compactMap { UInt8(String(h[$0...$0 + 1]), radix: 16) }
    }

    private func header(_ o: [String: Any]?) -> QuicFileStream.Header? {
        guard let o, let id = o["id"] as? String, let mime = o["mime"] as? String, let nm = o["name"] as? String,
              let mtime = o["mtime"] as? Int, let size = o["size"] as? Int else { return nil }
        return QuicFileStream.Header(dir: o["dir"] as? String, id: id, mime: mime, mtime: Int64(mtime), name: nm, size: Int64(size))
    }

    private func int64(_ any: Any?) -> Int64? { (any as? Int).map(Int64.init) }

    private func expectedDecode(_ e: [String: Any]) -> QuicFileStream.HeaderResult {
        switch e["result"] as? String {
        case "header": return .header(header(e["header"] as? [String: Any])!, consumed: e["consumed"] as? Int ?? -1)
        case "needMore": return .needMore
        default:
            switch e["code"] as? String {
            case "bad-id": return .invalid(.badId)
            case "not-file": return .invalid(.notFile)
            default: return .invalid(.badHeader)
            }
        }
    }

    @Test func theVectorFileHasTheCasesThisSuiteRuns() throws {
        for kind in ["header_encode", "header_parse", "have_parse", "result_parse", "have_encode", "result_encode", "body_length", "finish_verdict"] {
            #expect(try !cases(kind).isEmpty, "\(kind)")
        }
        #expect(try cases("header_parse").count >= 60)
    }

    @Test func theLimitsAreOneNumberOnEverySide() throws {
        let v = ((try doc())["constants"] as? [String: Any])?["values"] as? [String: Any]
        #expect(v?["file_header_max_bytes"] as? Int == QuicFileStream.headerMaxBytes)
        #expect(v?["file_name_max_bytes"] as? Int == QuicFileStream.nameMaxBytes)
        #expect(v?["file_mime_max_bytes"] as? Int == QuicFileStream.mimeMaxBytes)
        #expect(v?["file_first_byte_timeout_ms"] as? Int == QuicFileStream.firstByteTimeoutMs)
        #expect(v?["file_size_max"] as? Int64 == QuicFileStream.sizeMax)
    }

    @Test func headerEncodeVectors() throws {
        for c in try cases("header_encode") {
            let h = try #require(header(c["header"] as? [String: Any]), "\(name(c))")
            #expect(QuicFileStream.encodeHeader(h) == bytes(c["hex"] as? String), "\(name(c))")
            // and what we write must be what a receiver reads back
            #expect(QuicFileStream.decodeHeader(bytes(c["hex"] as? String)) == .header(h, consumed: bytes(c["hex"] as? String).count), "\(name(c)) round trip")
        }
    }

    @Test func headerParseVectors() throws {
        for c in try cases("header_parse") {
            #expect(QuicFileStream.decodeHeader(bytes(c["hex"] as? String)) == expectedDecode(c["expect"] as? [String: Any] ?? [:]), "\(name(c))")
        }
    }

    /// A stream delivers bytes in pieces: whatever the split, the answer must be the same, and an early answer must already be the final one.
    @Test func headerParseGivesTheSameAnswerWhereverTheBytesAreSplit() throws {
        for c in try cases("header_parse") {
            let all = bytes(c["hex"] as? String)
            let want = expectedDecode(c["expect"] as? [String: Any] ?? [:])
            for cut in 0...all.count {
                var d = QuicFileStream.HeaderDecoder()
                let first = d.feed(Array(all[..<cut]))
                if first != .needMore { #expect(first == want, "\(name(c)) decided too early at \(cut)") }
                let last = d.feed(Array(all[cut...]))
                #expect(last == want, "\(name(c)) split at \(cut)")
            }
            var d = QuicFileStream.HeaderDecoder()
            var last = QuicFileStream.HeaderResult.needMore
            for b in all { last = d.feed([b]) }
            #expect(last == want, "\(name(c)) byte by byte")
        }
    }

    @Test func haveParseVectors() throws {
        for c in try cases("have_parse") {
            let got = QuicFileStream.parseHave(bytes(c["hex"] as? String), size: int64(c["size"]) ?? -1)
            let e = c["expect"] as? [String: Any] ?? [:]
            switch e["result"] as? String {
            case "have": #expect(got == .have(int64(e["have"]) ?? -1), "\(name(c))")
            case "err": #expect(got == .refused(refusal(e["err"] as? String)), "\(name(c))")
            default: #expect(got == .invalid, "\(name(c))")
            }
        }
    }

    @Test func resultParseVectors() throws {
        for c in try cases("result_parse") {
            let got = QuicFileStream.parseResult(bytes(c["hex"] as? String))
            let e = c["expect"] as? [String: Any] ?? [:]
            switch e["result"] as? String {
            case "ok": #expect(got == .ok, "\(name(c))")
            case "err": #expect(got == .refused(refusal(e["err"] as? String)), "\(name(c))")
            default: #expect(got == .invalid, "\(name(c))")
            }
        }
    }

    private func refusal(_ s: String?) -> QuicFileStream.Refusal {
        guard let s, let code = QuicFileStream.WireError(rawValue: s) else { return .unknown }
        return .known(code)
    }

    @Test func haveAndResultEncodeVectors() throws {
        for c in try cases("have_encode") {
            #expect(QuicFileStream.encodeHave(int64(c["have"]) ?? -1) == bytes(c["hex"] as? String), "\(name(c))")
        }
        for c in try cases("result_encode") {
            let ok = c["ok"] as? Bool ?? false
            let err = (c["err"] as? String).flatMap { QuicFileStream.WireError(rawValue: $0) }
            #expect(QuicFileStream.encodeResult(ok: ok, err: err) == bytes(c["hex"] as? String), "\(name(c))")
        }
    }

    @Test func bodyLengthAndFinishVerdictVectors() throws {
        for c in try cases("body_length") {
            let want: Int64? = c["expect"] is NSNull ? nil : int64(c["expect"])
            #expect(QuicFileStream.bodyLength(size: int64(c["size"]) ?? -1, have: int64(c["have"]) ?? -2) == want, "\(name(c))")
        }
        for c in try cases("finish_verdict") {
            let want: QuicFileStream.Verdict = (c["expect"] as? String) == "ok" ? .ok : .sizeMismatch
            #expect(QuicFileStream.finishVerdict(expected: int64(c["expected"]) ?? -1, received: int64(c["received"]) ?? -2) == want, "\(name(c))")
        }
    }

    @Test func aMessageIsTwoLengthBytesPlusItsBody() {
        #expect(QuicFileStream.messageLength(prefix: []) == nil)
        #expect(QuicFileStream.messageLength(prefix: [0]) == nil)
        #expect(QuicFileStream.messageLength(prefix: [0, 12]) == 14)
        #expect(QuicFileStream.messageLength(prefix: [0x10, 0x00, 1, 2, 3]) == 4098)
    }
}
