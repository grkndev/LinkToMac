import Foundation
import Testing

@Suite struct FileHistoryTests {
    private func item(_ name: String, dir: String? = nil, size: Int = 10, at path: String? = nil) -> OutgoingItem {
        OutgoingItem(url: URL(fileURLWithPath: path ?? "/tmp/\(dir.map { $0 + "/" } ?? "")\(name)"),
                     name: name, dir: dir, size: size)
    }

    @Test func looseFilesGetOneRowEachWithTheirOutcome() {
        var result = BatchResult()
        result.sent = ["a.txt"]
        result.failures = [.init(name: "b.txt", reason: "phone went offline")]
        let rows = FileHistoryBuilder.sentRecords(items: [item("a.txt"), item("b.txt")], result: result)
        #expect(rows.map(\.name) == ["a.txt", "b.txt"])
        #expect(rows[0].status == .done)
        #expect(rows[1].status == .failed("phone went offline"))
        #expect(rows[0].resumeSources.isEmpty)
        #expect(rows[1].resumeSources == [URL(fileURLWithPath: "/tmp/b.txt")])
    }

    @Test func aFolderIsOneRowWithSummedSize() {
        var result = BatchResult()
        result.sent = ["1.txt", "2.txt"]
        let items = [item("1.txt", dir: "Notes", size: 5), item("2.txt", dir: "Notes/week", size: 7)]
        let rows = FileHistoryBuilder.sentRecords(items: items, result: result)
        #expect(rows.count == 1)
        #expect(rows[0].name == "Notes (folder)")
        #expect(rows[0].fileCount == 2)
        #expect(rows[0].bytes == 12)
        #expect(rows[0].status == .done)
    }

    @Test func aPartlyDeliveredFolderIsNotRetryable() {
        var result = BatchResult()
        result.sent = ["1.txt"]
        result.failures = [.init(name: "2.txt", reason: "nack")]
        let items = [item("1.txt", dir: "Notes"), item("2.txt", dir: "Notes")]
        let rows = FileHistoryBuilder.sentRecords(items: items, result: result)
        #expect(rows[0].status == .failed("nack"))
        #expect(rows[0].resumeSources.isEmpty) // re-sending would duplicate 1.txt on the phone
    }

    @Test func aFolderThatSentNothingRetriesAsTheFolderRoot() {
        var result = BatchResult()
        result.failures = [.init(name: "1.txt", reason: "offline")]
        result.notSent = 1
        let items = [item("1.txt", dir: "Notes", at: "/Users/me/Notes/1.txt"),
                     item("2.txt", dir: "Notes", at: "/Users/me/Notes/2.txt")]
        let rows = FileHistoryBuilder.sentRecords(items: items, result: result)
        #expect(rows[0].resumeSources.map(\.path) == ["/Users/me/Notes"]) // paths: a directory URL may carry a trailing slash
    }

    @Test func filesNeverAttemptedAreMarkedByCause() {
        var result = BatchResult()
        result.sent = ["a.txt"]
        result.notSent = 1
        result.cancelled = true
        let rows = FileHistoryBuilder.sentRecords(items: [item("a.txt"), item("b.txt")], result: result)
        #expect(rows[1].status == .failed("Cancelled"))
        #expect(rows[1].canResume)
    }

    @Test func rootURLStripsTheRelativeDirAndName() {
        let nested = item("x.txt", dir: "Notes/week", at: "/Users/me/Notes/week/x.txt")
        #expect(FileHistoryBuilder.rootURL(of: nested).path == "/Users/me/Notes")
    }
}
