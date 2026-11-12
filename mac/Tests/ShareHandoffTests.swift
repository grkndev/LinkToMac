import Foundation
import Testing

@Suite struct ShareHandoffTests {
    /// A throwaway "container home" so nothing touches the real one.
    private func makeHome() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func dir(_ home: String) -> URL { ShareHandoff.directory(home: home) }
    private func file(_ home: String, _ id: String) -> URL { dir(home).appendingPathComponent("\(id).json") }
    private func files(_ home: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir(home).path)) ?? []
    }

    /// Writes a record by hand, so a test can make it older, bigger or malformed than `write` would.
    private func plant(_ home: String, id: String = UUID().uuidString, bytes: Data) throws -> String {
        try FileManager.default.createDirectory(at: dir(home), withIntermediateDirectories: true)
        try bytes.write(to: file(home, id))
        return id
    }

    private func record(_ path: String, created: Date) -> Data {
        try! JSONEncoder().encode(ShareHandoff.Record(path: path, created: created.timeIntervalSince1970))
    }

    @Test func roundTripReturnsThePath() throws {
        let home = try makeHome()
        let id = try ShareHandoff.write(path: "/Users/someone/report.pdf", home: home)
        #expect(UUID(uuidString: id)?.uuidString == id)
        #expect(ShareHandoff.consume(id: id, home: home) == URL(fileURLWithPath: "/Users/someone/report.pdf"))
    }

    @Test func aHandoffWorksOnlyOnce() throws {
        let home = try makeHome()
        let id = try ShareHandoff.write(path: "/tmp/a", home: home)
        #expect(ShareHandoff.consume(id: id, home: home) != nil)
        #expect(ShareHandoff.consume(id: id, home: home) == nil)
        #expect(files(home).isEmpty)
    }

    @Test func idsThatAreNotACanonicalUUIDAreRefused() throws {
        let home = try makeHome()
        // A real record sits there; none of these may reach it or anything outside the directory.
        let id = try ShareHandoff.write(path: "/tmp/a", home: home)
        let bad = ["", "..", "../x", "a/b", "\(id)/..", id.lowercased(), "\(id).json", String(id.dropLast()),
                   id + "0", "not-a-uuid", String(repeating: "A", count: 4096)]
        for candidate in bad {
            #expect(ShareHandoff.consume(id: candidate, home: home) == nil, "accepted \(candidate.prefix(40))")
        }
        // …and the real one is untouched by all of that.
        #expect(ShareHandoff.consume(id: id, home: home) != nil)
    }

    @Test func aStaleRecordIsRefusedAndRemoved() throws {
        let home = try makeHome()
        let now = Date()
        let id = try plant(home, bytes: record("/tmp/a", created: now.addingTimeInterval(-ShareHandoff.maxAge - 1)))
        #expect(ShareHandoff.consume(id: id, home: home, now: now) == nil)
        #expect(files(home).isEmpty)
    }

    @Test func aRecordJustInsideTheWindowIsAccepted() throws {
        let home = try makeHome()
        let now = Date()
        let id = try plant(home, bytes: record("/tmp/a", created: now.addingTimeInterval(-ShareHandoff.maxAge + 5)))
        #expect(ShareHandoff.consume(id: id, home: home, now: now) == URL(fileURLWithPath: "/tmp/a"))
    }

    @Test func aRecordFromTheFutureIsRefused() throws {
        let home = try makeHome()
        let now = Date()
        let id = try plant(home, bytes: record("/tmp/a", created: now.addingTimeInterval(60)))
        #expect(ShareHandoff.consume(id: id, home: home, now: now) == nil)
    }

    @Test func anOversizedRecordIsRefusedAndRemoved() throws {
        let home = try makeHome()
        let padded = record(String(repeating: "x", count: ShareHandoff.maxRecordBytes), created: Date())
        let id = try plant(home, bytes: padded)
        #expect(ShareHandoff.consume(id: id, home: home) == nil)
        #expect(files(home).isEmpty)
    }

    @Test func malformedAndRelativeRecordsAreRefusedAndRemoved() throws {
        let home = try makeHome()
        let junk = try plant(home, bytes: Data("not json".utf8))
        let relative = try plant(home, bytes: record("relative/path.txt", created: Date()))
        let empty = try plant(home, bytes: record("", created: Date()))
        for id in [junk, relative, empty] {
            #expect(ShareHandoff.consume(id: id, home: home) == nil)
        }
        #expect(files(home).isEmpty)
    }

    @Test func aSymlinkIsRefusedAndOnlyTheLinkIsRemoved() throws {
        let home = try makeHome()
        // The link points at a perfectly valid record elsewhere; following it would succeed.
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString).json")
        try record("/tmp/a", created: Date()).write(to: real)
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: dir(home), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file(home, id), withDestinationURL: real)

        #expect(ShareHandoff.consume(id: id, home: home) == nil)
        #expect(FileManager.default.fileExists(atPath: real.path), "the link's target must survive")
        #expect(files(home).isEmpty)
    }

    @Test func leftoversAreSweptButFreshRecordsAreNot() throws {
        let home = try makeHome()
        let now = Date()
        let old = try plant(home, bytes: record("/tmp/old", created: now))
        let fresh = try plant(home, bytes: record("/tmp/fresh", created: now))
        // Age one file's modification date past the sweep window.
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ShareHandoff.sweepAge - 60)], ofItemAtPath: file(home, old).path)

        // Consuming any id (even a bad one) triggers the sweep.
        _ = ShareHandoff.consume(id: "nope", home: home, now: now)
        #expect(!files(home).contains("\(old).json"))
        #expect(files(home).contains("\(fresh).json"))
    }

    @Test func aMissingDirectoryIsJustNil() throws {
        let home = try makeHome()
        #expect(ShareHandoff.consume(id: UUID().uuidString, home: home) == nil)
        #expect(ShareHandoff.consume(id: UUID().uuidString, home: "/definitely/not/a/real/home") == nil)
    }

    @Test func writeRefusesARelativePath() throws {
        let home = try makeHome()
        #expect(throws: ShareHandoff.WriteError.self) { try ShareHandoff.write(path: "relative.txt", home: home) }
        #expect(files(home).isEmpty)
    }

    @Test func theAppLooksWhereTheExtensionWrites() {
        // The extension's own home inside its sandbox is the container's `Data` folder; the app must
        // resolve to that same folder from the outside.
        let home = ShareHandoff.extensionHome(userHome: "/Users/someone")
        #expect(home == "/Users/someone/Library/Containers/dev.grkn.LinkToMac.ShareExtension/Data")
        #expect(ShareHandoff.directory(home: home).path
            == "/Users/someone/Library/Containers/dev.grkn.LinkToMac.ShareExtension/Data/Library/Caches/ShareHandoff")
    }
}
