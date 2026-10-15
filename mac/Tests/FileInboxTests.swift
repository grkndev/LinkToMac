import Foundation
import Testing

@MainActor @Suite struct FileInboxTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("l2m-inbox-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func frame(id: String, seq: Int, count: Int, bytes: Data, name: String? = "f.bin", dir: String? = nil) -> FileFrame.Parsed {
        FileFrame.parse(FileFrame.payload(mime: "x/y", bytes: bytes, name: name, dir: dir,
                                          disp: FileFrame.dispSave, id: id, seq: seq, count: count))!
    }

    /// The inbox writes chunk N at `N × chunkRawBytes`, so real chunks are exactly that size.
    private func chunk(_ seq: Int, size: Int = FileFrame.chunkRawBytes) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: seq &* 31 &+ $0) })
    }

    private func files(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func outOfOrderChunksReassembleByPositionOnDisk() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(directory: dir) { _ in }
        let c0 = chunk(0), c1 = chunk(1), c2 = chunk(2, size: 100)
        guard case .buffered = inbox.accept(frame(id: "a", seq: 2, count: 3, bytes: c2)) else { Issue.record("not buffered"); return }
        guard case .buffered = inbox.accept(frame(id: "a", seq: 0, count: 3, bytes: c0)) else { Issue.record("not buffered"); return }
        guard case let .done(file) = inbox.accept(frame(id: "a", seq: 1, count: 3, bytes: c1)) else { Issue.record("not done"); return }
        guard case let .file(url) = file.payload else { Issue.record("expected a temp file"); return }
        #expect(try Data(contentsOf: url) == c0 + c1 + c2)
        #expect(inbox.progress == nil)
    }

    @Test func haveReportsTheContiguousPrefix() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(directory: dir) { _ in }
        func have(_ seq: Int) -> Int? {
            if case let .buffered(_, _, h) = inbox.accept(frame(id: "h", seq: seq, count: 6, bytes: chunk(seq))) { return h }
            return nil
        }
        #expect(have(0) == 1)
        #expect(have(1) == 2)
        #expect(have(3) == 2) // a gap at 2
        #expect(have(2) == 4) // filling it jumps over 3
        #expect(have(2) == 4) // a duplicate changes nothing
    }

    @Test func oneChunkFileWithAnIdCompletesInMemory() {
        let inbox = FileInbox(directory: tempDir()) { _ in }
        guard case let .done(file) = inbox.accept(frame(id: "solo", seq: 0, count: 1, bytes: Data([9]))) else { Issue.record("not done"); return }
        guard case let .memory(bytes) = file.payload else { Issue.record("expected memory"); return }
        #expect(bytes == Data([9]))
    }

    @Test func dirTravelsWithTheTransfer() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(directory: dir) { _ in }
        _ = inbox.accept(frame(id: "d", seq: 0, count: 2, bytes: chunk(0), dir: "Album/Sub"))
        guard case let .done(file) = inbox.accept(frame(id: "d", seq: 1, count: 2, bytes: chunk(1, size: 5), dir: "Album/Sub")) else { Issue.record("not done"); return }
        #expect(file.dir == "Album/Sub")
    }

    @Test func aThirdConcurrentTransferIsRejectedWhileOthersAreLive() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(directory: dir) { _ in }
        _ = inbox.accept(frame(id: "1", seq: 0, count: 2, bytes: chunk(0)))
        _ = inbox.accept(frame(id: "2", seq: 0, count: 2, bytes: chunk(0)))
        guard case .rejected = inbox.accept(frame(id: "3", seq: 0, count: 2, bytes: chunk(0))) else { Issue.record("accepted a third"); return }
    }

    @Test func aStalePartialIsEvictedToMakeRoom() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(ttl: 600, staleAfter: 0.05, directory: dir) { _ in }
        _ = inbox.accept(frame(id: "1", seq: 0, count: 2, bytes: chunk(0)))
        _ = inbox.accept(frame(id: "2", seq: 0, count: 2, bytes: chunk(0)))
        try await Task.sleep(for: .milliseconds(150))
        guard case .buffered = inbox.accept(frame(id: "3", seq: 0, count: 2, bytes: chunk(0))) else { Issue.record("not accepted after eviction"); return }
        #expect(files(in: dir).count == 2) // the evicted one's temp file is gone
    }

    @Test func aQuietPartialIsKeptForResumeButStopsShowingAsReceiving() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(ttl: 600, staleAfter: 0.05, directory: dir) { _ in }
        _ = inbox.accept(frame(id: "r", seq: 0, count: 3, bytes: chunk(0)))
        _ = inbox.accept(frame(id: "r", seq: 1, count: 3, bytes: chunk(1)))
        #expect(inbox.progress != nil)
        try await Task.sleep(for: .milliseconds(150))
        inbox.sweep()
        #expect(inbox.progress == nil) // the row clears…
        // …but the partial is still there: a retry of the same transfer resumes where it stopped.
        guard case let .buffered(_, _, have) = inbox.accept(frame(id: "r", seq: 0, count: 3, bytes: chunk(0))) else { Issue.record("lost the partial"); return }
        #expect(have == 2)
    }

    @Test func aPartialIdlePastTheTTLIsDeleted() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(ttl: 0.05, staleAfter: 0.05, directory: dir) { _ in }
        _ = inbox.accept(frame(id: "t", seq: 0, count: 2, bytes: chunk(0)))
        #expect(files(in: dir).count == 1)
        try await Task.sleep(for: .milliseconds(150))
        inbox.sweep()
        #expect(files(in: dir).isEmpty)
    }

    @Test func oversizeTransferIsRejectedAndItsTempFileRemoved() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(maxBytes: 4, directory: dir) { _ in }
        _ = inbox.accept(frame(id: "o", seq: 0, count: 3, bytes: Data([1, 2, 3])))
        guard case .rejected = inbox.accept(frame(id: "o", seq: 1, count: 3, bytes: Data([4, 5]))) else { Issue.record("not rejected"); return }
        #expect(files(in: dir).isEmpty)
    }

    @Test func aChunkLargerThanTheChunkSizeIsRejected() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(directory: dir) { _ in }
        // Written at seq × chunkRawBytes, it would overwrite the next chunk.
        guard case .rejected = inbox.accept(frame(id: "big", seq: 0, count: 2, bytes: chunk(0, size: FileFrame.chunkRawBytes + 1))) else { Issue.record("accepted an oversized chunk"); return }
        #expect(files(in: dir).isEmpty)
    }

    @Test func outOfRangeChunkIsRejected() {
        let inbox = FileInbox(directory: tempDir()) { _ in }
        guard case .rejected = inbox.accept(frame(id: "r", seq: 5, count: 3, bytes: Data([1]))) else { Issue.record("not rejected"); return }
    }

    @Test func aChangedChunkCountMidTransferDropsItAndItsFile() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = FileInbox(directory: dir) { _ in }
        _ = inbox.accept(frame(id: "c", seq: 0, count: 3, bytes: chunk(0)))
        guard case .rejected = inbox.accept(frame(id: "c", seq: 1, count: 4, bytes: chunk(1))) else { Issue.record("not rejected"); return }
        #expect(files(in: dir).isEmpty)
    }

    @Test func purgeDeletesOnlyOldLeftovers() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.part"), fresh = dir.appendingPathComponent("fresh.part")
        try Data([1]).write(to: old); try Data([1]).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        FileInbox.purge(dir, olderThan: 3600)
        #expect(files(in: dir) == ["fresh.part"])
    }
}

@MainActor @Suite struct FileDropStoreTests {
    @Test func traversalAndSeparatorsAreNeutralised() {
        #expect(FileDropStore.sanitize("../../etc/passwd", mime: "x/y") == "passwd")
        #expect(FileDropStore.sanitize("a:b.txt", mime: "x/y") == "a-b.txt")
        #expect(FileDropStore.sanitize("...", mime: "image/png").hasPrefix("phone-"))
        #expect(FileDropStore.sanitize(nil, mime: "image/png").hasSuffix(".png"))
    }

    @Test func longNamesKeepTheirExtension() {
        let name = String(repeating: "x", count: 400) + ".pdf"
        let cut = FileDropStore.sanitize(name, mime: "application/pdf")
        #expect(cut.utf8.count <= 200)
        #expect(cut.hasSuffix(".pdf"))
    }

    @Test func moveInRecreatesTheFolderTreeAndMovesTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l2m-movein-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = root.appendingPathComponent("incoming.part")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: temp)
        let folder = root.appendingPathComponent("Link to Mac")

        let url = try FileDropStore.moveIn(temp, to: folder, preferredName: "p.jpg", dir: "Album/Sub", mime: "image/jpeg")
        #expect(url == folder.appendingPathComponent("Album/Sub/p.jpg"))
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: temp.path)) // moved, not copied
    }

    @Test func aHostileDirCannotEscapeTheDownloadFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l2m-escape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Link to Mac")
        let url = try FileDropStore.write(bytes: Data([1]), to: folder, preferredName: "x.txt", dir: "../../etc", mime: "text/plain")
        #expect(url.path.hasPrefix(folder.path + "/"))
        #expect(url == folder.appendingPathComponent("etc/x.txt"))
    }

    @Test func clashesInsideAFolderStillGetANumber() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l2m-clash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try FileDropStore.write(bytes: Data([1]), to: root, preferredName: "x.jpg", dir: "Trip", mime: "image/jpeg")
        let b = try FileDropStore.write(bytes: Data([2]), to: root, preferredName: "x.jpg", dir: "Trip", mime: "image/jpeg")
        #expect(a.lastPathComponent == "x.jpg")
        #expect(b.lastPathComponent == "x 2.jpg")
        #expect(a.deletingLastPathComponent() == b.deletingLastPathComponent())
    }

    @Test func clashesGetANumberAndNothingIsOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l2m-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try FileDropStore.write(bytes: Data([1]), to: folder, preferredName: "x.jpg", mime: "image/jpeg")
        let b = try FileDropStore.write(bytes: Data([2]), to: folder, preferredName: "x.jpg", mime: "image/jpeg")
        #expect(a.lastPathComponent == "x.jpg")
        #expect(b.lastPathComponent == "x 2.jpg")
        #expect(try Data(contentsOf: a) == Data([1]))
    }
}
