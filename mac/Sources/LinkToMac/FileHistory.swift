import Foundation

/// One line of the Files page: a file (or a whole dropped folder) that was sent to or received
/// from the phone, and how it ended. Foundation only, so the test target compiles it.
struct FileTransferRecord: Identifiable, Equatable, Sendable {
    enum Direction: Sendable { case received, sent }
    enum Status: Equatable, Sendable { case done, failed(String) }

    let id: UUID
    let direction: Direction
    /// What to show: a file name, or `Folder (folder)` for a dropped folder.
    var name: String
    /// Files behind this row (more than 1 for a folder).
    var fileCount: Int
    var bytes: Int
    var status: Status
    let date: Date
    /// Where a received file now lives (nil for sent rows, or if it could not be saved).
    var location: URL?
    /// What to re-send to retry a failed row. Empty when a retry is not safe (see
    /// `FileHistoryBuilder`) — the row is then shown as failed without a "resume" affordance.
    var resumeSources: [URL]

    init(id: UUID = UUID(), direction: Direction, name: String, fileCount: Int = 1, bytes: Int,
         status: Status, date: Date, location: URL? = nil, resumeSources: [URL] = []) {
        self.id = id
        self.direction = direction
        self.name = name
        self.fileCount = fileCount
        self.bytes = bytes
        self.status = status
        self.date = date
        self.location = location
        self.resumeSources = resumeSources
    }

    var canResume: Bool {
        if case .failed = status { return !resumeSources.isEmpty }
        return false
    }
}

/// Turns the result of a send batch into history rows.
enum FileHistoryBuilder {
    /// One row per loose file and one per dropped folder.
    ///
    /// Retrying re-sends the file with the same transfer id, so the phone resumes a partial copy.
    /// A *folder* is only retryable when none of its files got through: re-sending it after some
    /// arrived would deliver those again as "name 2" copies, which is worse than not offering it.
    static func sentRecords(items: [OutgoingItem], result: BatchResult, now: Date = Date()) -> [FileTransferRecord] {
        var sentLeft: [String: Int] = [:]
        for name in result.sent { sentLeft[name, default: 0] += 1 }
        var failuresLeft: [String: [String]] = [:]
        for failure in result.failures { failuresLeft[failure.name, default: []].append(failure.reason) }
        let unsent = result.cancelled ? "Cancelled" : "Not sent"

        func outcome(of item: OutgoingItem) -> FileTransferRecord.Status {
            if let n = sentLeft[item.name], n > 0 { sentLeft[item.name] = n - 1; return .done }
            if var reasons = failuresLeft[item.name], !reasons.isEmpty {
                let reason = reasons.removeFirst()
                failuresLeft[item.name] = reasons
                return .failed(reason)
            }
            return .failed(unsent)
        }

        var records: [FileTransferRecord] = []
        var folderOrder: [String] = []
        var folders: [String: [(item: OutgoingItem, status: FileTransferRecord.Status)]] = [:]

        for item in items {
            let status = outcome(of: item)
            if let root = Self.root(of: item.dir) {
                if folders[root] == nil { folderOrder.append(root) }
                folders[root, default: []].append((item, status))
            } else {
                records.append(FileTransferRecord(
                    direction: .sent, name: item.name, bytes: item.size, status: status, date: now,
                    resumeSources: status == .done ? [] : [item.url]))
            }
        }

        for root in folderOrder {
            guard let group = folders[root], let first = group.first else { continue }
            let done = group.filter { $0.status == .done }.count
            let firstFailure = group.compactMap { entry -> String? in
                if case let .failed(reason) = entry.status { return reason }
                return nil
            }.first
            let status: FileTransferRecord.Status = firstFailure.map { .failed($0) } ?? .done
            let rootURL = Self.rootURL(of: first.item)
            records.append(FileTransferRecord(
                direction: .sent, name: "\(root) (folder)", fileCount: group.count,
                bytes: group.reduce(0) { $0 + $1.item.size }, status: status, date: now,
                resumeSources: (firstFailure != nil && done == 0) ? [rootURL] : []))
        }
        return records
    }

    /// First path component of a relative folder path (`"Notes/week 1"` → `"Notes"`).
    static func root(of dir: String?) -> String? {
        guard let dir, !dir.isEmpty else { return nil }
        return dir.split(separator: "/").first.map(String.init)
    }

    /// The dropped folder an item came from. `dir` starts with the root's own name
    /// (`Notes/week`), so the root is the item's URL minus the file name and the sub-folders.
    static func rootURL(of item: OutgoingItem) -> URL {
        let depth = item.dir?.split(separator: "/").count ?? 1
        var url = item.url
        for _ in 0..<depth { url.deleteLastPathComponent() }
        return url
    }
}
