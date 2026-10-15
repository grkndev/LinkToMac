import Foundation
import Testing

@Suite struct FileBatchPlannerTests {
    private func tree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("l2m-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ path: String, in root: URL, bytes: Int = 4) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    @Test func plainFilesGoThroughFlat() throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        try write("a.txt", in: root)
        let plan = FileBatchPlanner.plan(urls: [root.appendingPathComponent("a.txt")])
        #expect(plan.items.map(\.name) == ["a.txt"])
        #expect(plan.items[0].dir == nil)
        #expect(plan.problems.isEmpty)
    }

    @Test func foldersKeepTheirStructure() throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        try write("Album/one.jpg", in: root)
        try write("Album/Sub/two.jpg", in: root)
        try write("Album/Sub/Deep/three.jpg", in: root)
        let plan = FileBatchPlanner.plan(urls: [root.appendingPathComponent("Album")])

        let byName = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.name, $0.dir) })
        #expect(byName["one.jpg"] == "Album")
        #expect(byName["two.jpg"] == "Album/Sub")
        #expect(byName["three.jpg"] == "Album/Sub/Deep")
        #expect(plan.items.count == 3)
    }

    @Test func hiddenFilesAndNestedSymlinksAreSkipped() throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        try write("Dir/keep.txt", in: root)
        try write("Dir/.secret", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Dir/link.txt"),
            withDestinationURL: root.appendingPathComponent("Dir/keep.txt"))
        let plan = FileBatchPlanner.plan(urls: [root.appendingPathComponent("Dir")])
        #expect(plan.items.map(\.name) == ["keep.txt"])
    }

    @Test func emptyFolderIsReportedNotSilentlyDropped() throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let plan = FileBatchPlanner.plan(urls: [root.appendingPathComponent("Empty")])
        #expect(plan.items.isEmpty)
        #expect(plan.problems == ["Empty has no files to send"])
    }

    @Test func emptyAndOversizedFilesAreReported() throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        try write("zero.txt", in: root, bytes: 0)
        let big = root.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(FileFrame.maxTransferBytes + 1)) // sparse, costs nothing
        try handle.close()

        let plan = FileBatchPlanner.plan(urls: [root.appendingPathComponent("zero.txt"), big])
        #expect(plan.items.isEmpty)
        #expect(plan.problems.contains("zero.txt is empty"))
        #expect(plan.problems.contains("big.bin is larger than 64 MB"))
    }

    @Test func runawayFolderIsCapped() throws {
        let root = try tree(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<(FileBatchPlanner.maxFiles + 5) { try write("Big/f\(i).txt", in: root, bytes: 1) }
        let plan = FileBatchPlanner.plan(urls: [root.appendingPathComponent("Big")])
        #expect(plan.items.count == FileBatchPlanner.maxFiles)
        #expect(plan.problems.contains { $0.contains("only the first") })
    }

    @Test func missingPathIsReported() {
        let plan = FileBatchPlanner.plan(urls: [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")])
        #expect(plan.items.isEmpty)
        #expect(plan.problems.count == 1)
    }
}
