import Foundation
import Testing

/// The shared wire vectors (`protocol-vectors/file-frame.json`) — the Kotlin codec runs the same file.
/// These exist because the two codecs are mirrored by hand and drifted once already.
@Suite struct FileFrameVectorTests {
    private struct Vectors {
        let cases: [[String: Any]]

        static func load() throws -> Vectors {
            // Tests run from a checkout, so the repo-root file is found relative to this source file.
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // mac
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("protocol-vectors/file-frame.json")
            let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            return Vectors(cases: (doc?["cases"] as? [[String: Any]]) ?? [])
        }

        func cases(kind: String) -> [[String: Any]] { cases.filter { $0["kind"] as? String == kind } }
    }

    private static func data(hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// Split a frame into (header object, body).
    private static func split(_ frame: Data) throws -> ([String: Any], Data) {
        let headerLen = Int(frame[frame.startIndex]) << 8 | Int(frame[frame.startIndex + 1])
        let headerData = frame.subdata(in: (frame.startIndex + 2)..<(frame.startIndex + 2 + headerLen))
        let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] ?? [:]
        return (header, frame.subdata(in: (frame.startIndex + 2 + headerLen)..<frame.endIndex))
    }

    private static func build(_ params: [String: Any]) -> Data {
        let id = params["id"] as? String ?? ""
        let seq = params["seq"] as? Int ?? 0
        switch params["op"] as? String {
        case FileFrame.opAck:
            return FileFrame.ack(id: id, seq: seq, have: params["have"] as? Int)
        case FileFrame.opNack:
            return FileFrame.nack(id: id, seq: seq, reason: params["reason"] as? String)
        default:
            return FileFrame.payload(
                mime: params["mime"] as? String ?? "",
                bytes: data(hex: params["bytes_hex"] as? String ?? ""),
                name: params["name"] as? String,
                dir: params["dir"] as? String,
                disp: params["disp"] as? String ?? FileFrame.dispClip,
                id: params["id"] as? String,
                seq: seq,
                count: params["count"] as? Int ?? 1
            )
        }
    }

    @Test func everyVectorParsesToTheExpectedFields() throws {
        let cases = try Vectors.load().cases(kind: "roundtrip")
        #expect(!cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let frame = try #require(FileFrame.parse(Self.data(hex: c["frame_hex"] as! String)), "\(name): did not parse")
            let want = c["parsed"] as! [String: Any]
            #expect(frame.op == want["op"] as? String, "\(name): op")
            #expect(frame.mime == want["mime"] as? String, "\(name): mime")
            #expect(frame.name == want["name"] as? String, "\(name): name")
            #expect(frame.dir == want["dir"] as? String, "\(name): dir")
            #expect(frame.disp == want["disp"] as? String, "\(name): disp")
            #expect(frame.id == want["id"] as? String, "\(name): id")
            #expect(frame.seq == want["seq"] as? Int, "\(name): seq")
            #expect(frame.count == want["count"] as? Int, "\(name): count")
            #expect(frame.reason == want["reason"] as? String, "\(name): reason")
            #expect(frame.have == want["have"] as? Int, "\(name): have")
            #expect(frame.bytes == Self.data(hex: want["bytes_hex"] as! String), "\(name): bytes")
        }
    }

    @Test func everyVectorEncodesToTheExpectedHeader() throws {
        for c in try Vectors.load().cases(kind: "roundtrip") {
            let name = c["name"] as? String ?? "?"
            let params = c["params"] as! [String: Any]
            let (header, body) = try Self.split(Self.build(params))
            #expect(NSDictionary(dictionary: header).isEqual(to: c["header"] as! [String: Any]),
                    "\(name): header \(header) != \(c["header"]!)")
            #expect(body == Self.data(hex: params["bytes_hex"] as? String ?? ""), "\(name): body")
        }
    }

    @Test func overlongNamesAndDirsFitTheHeaderPrefix() throws {
        let cases = try Vectors.load().cases(kind: "fits")
        #expect(!cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            var params = c["params"] as! [String: Any]
            func expand(_ key: String, into target: String) {
                if let r = params[key] as? [String: Any] {
                    params[target] = String(repeating: r["char"] as! String, count: r["times"] as! Int)
                }
            }
            expand("name_repeat", into: "name")
            expand("dir_repeat", into: "dir")
            let originalName = params["name"] as? String ?? ""

            let frame = Self.build(params)
            let (header, body) = try Self.split(frame)
            let want = c["expect"] as! [String: Any]
            let headerLen = Int(frame[frame.startIndex]) << 8 | Int(frame[frame.startIndex + 1])
            #expect(headerLen <= want["max_header_bytes"] as! Int, "\(name): header length")
            #expect((header["dir"] == nil) == (want["dir_dropped"] as! Bool), "\(name): dir")
            #expect(((header["name"] as? String)?.count ?? 0) < originalName.count, "\(name): name shortened")
            #expect(header["id"] as? String == want["id"] as? String, "\(name): id")
            #expect(header["seq"] as? Int == want["seq"] as? Int, "\(name): seq")
            #expect(header["n"] as? Int == want["count"] as? Int, "\(name): n")
            #expect(body == Self.data(hex: want["bytes_hex"] as! String), "\(name): body")
            #expect(FileFrame.parse(frame) != nil, "\(name): parses")
        }
    }

    @Test func dirSanitizeVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol-vectors/dir-sanitize.json")
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let cases = doc["cases"] as! [[String: Any]]
        #expect(!cases.isEmpty)
        for c in cases {
            let input = c["input"] as? String // JSON null -> nil
            #expect(FileDropStore.sanitizeDir(input) == c["expected"] as? String, "\(c["name"] ?? "?")")
        }
    }

    @Test func malformedVectorsParseToNothing() throws {
        let cases = try Vectors.load().cases(kind: "malformed")
        #expect(!cases.isEmpty)
        for c in cases {
            #expect(FileFrame.parse(Self.data(hex: c["frame_hex"] as! String)) == nil, "\(c["name"] ?? "?")")
        }
    }
}
