import Foundation
import Testing

@MainActor @Suite struct FileInboxTests {
    private func frame(id: String, seq: Int, count: Int, bytes: [UInt8], name: String? = "f.bin") -> FileFrame.Parsed {
        FileFrame.parse(FileFrame.payload(mime: "x/y", bytes: Data(bytes), name: name,
                                          disp: FileFrame.dispSave, id: id, seq: seq, count: count))!
    }

    @Test func outOfOrderChunksReassemble() {
        let inbox = FileInbox { _ in }
        guard case .buffered = inbox.accept(frame(id: "a", seq: 2, count: 3, bytes: [5, 6])) else { Issue.record("not buffered"); return }
        guard case .buffered = inbox.accept(frame(id: "a", seq: 0, count: 3, bytes: [1, 2])) else { Issue.record("not buffered"); return }
        guard case let .done(file) = inbox.accept(frame(id: "a", seq: 1, count: 3, bytes: [3, 4])) else { Issue.record("not done"); return }
        #expect(file.bytes == Data([1, 2, 3, 4, 5, 6]))
        #expect(inbox.progress == nil)
    }

    @Test func oneChunkFileWithAnIdCompletesImmediately() {
        let inbox = FileInbox { _ in }
        guard case let .done(file) = inbox.accept(frame(id: "solo", seq: 0, count: 1, bytes: [9])) else { Issue.record("not done"); return }
        #expect(file.bytes == Data([9]))
    }

    @Test func aDuplicateChunkDoesNotDoubleCount() {
        let inbox = FileInbox { _ in }
        _ = inbox.accept(frame(id: "d", seq: 0, count: 2, bytes: [1]))
        _ = inbox.accept(frame(id: "d", seq: 0, count: 2, bytes: [1]))
        guard case let .done(file) = inbox.accept(frame(id: "d", seq: 1, count: 2, bytes: [2])) else { Issue.record("not done"); return }
        #expect(file.bytes == Data([1, 2]))
    }

    @Test func aThirdConcurrentTransferIsRejected() {
        let inbox = FileInbox { _ in }
        _ = inbox.accept(frame(id: "1", seq: 0, count: 2, bytes: [1]))
        _ = inbox.accept(frame(id: "2", seq: 0, count: 2, bytes: [1]))
        guard case .rejected = inbox.accept(frame(id: "3", seq: 0, count: 2, bytes: [1])) else { Issue.record("accepted a third"); return }
    }

    @Test func oversizeTransferIsRejected() {
        let inbox = FileInbox(maxBytes: 4) { _ in }
        _ = inbox.accept(frame(id: "o", seq: 0, count: 3, bytes: [1, 2, 3]))
        guard case .rejected = inbox.accept(frame(id: "o", seq: 1, count: 3, bytes: [4, 5])) else { Issue.record("not rejected"); return }
    }

    @Test func outOfRangeChunkIsRejected() {
        let inbox = FileInbox { _ in }
        guard case .rejected = inbox.accept(frame(id: "r", seq: 5, count: 3, bytes: [1])) else { Issue.record("not rejected"); return }
    }

    @Test func abandonedTransferIsSweptAndTheProgressRowClears() async throws {
        let inbox = FileInbox(ttl: 0.05) { _ in }
        _ = inbox.accept(frame(id: "s", seq: 0, count: 2, bytes: [1]))
        #expect(inbox.progress != nil)
        try await Task.sleep(for: .milliseconds(150))
        inbox.sweep() // what the timer calls — no further frame needed
        #expect(inbox.progress == nil)
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
