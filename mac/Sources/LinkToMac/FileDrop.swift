import Foundation
import AppKit
import UniformTypeIdentifiers

/// UserDefaults key for the download folder, kept next to `AppearanceKeys` so anything reading it
/// with `@AppStorage` uses the exact string the store writes.
enum FileDropKeys {
    static let folder = "downloadFolder"
}

/// Where files shared from the phone land.
///
/// The phone's share sheet offers "Send as a File" next to "Send to Clipboard"; this is the
/// destination for the first one. A plain path string is enough because the app is **not**
/// sandboxed (no entitlements file, ad-hoc signed) — a sandboxed build would need a
/// security-scoped bookmark here instead.
@MainActor
@Observable
final class FileDropStore {
    /// Absolute path of the folder incoming files are written to.
    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: FileDropKeys.folder) }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: FileDropKeys.folder), !saved.isEmpty {
            folder = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            folder = Self.defaultFolder
        }
    }

    /// `~/Downloads/Link to Mac` — its own folder rather than Downloads itself, so a phone drop is
    /// never lost among browser downloads and the whole lot can be cleared in one go.
    static var defaultFolder: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("Link to Mac", isDirectory: true)
    }

    /// Ask the user for a new destination. Returns true when they picked one.
    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Choose"
        panel.message = "Where should files sent from your phone be saved?"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let picked = panel.url else { return false }
        folder = picked
        return true
    }

    /// Write `bytes` into the configured folder under a name derived from `preferredName`, never
    /// overwriting: a clash becomes "photo 2.jpg", then "photo 3.jpg", and so on. Returns the URL
    /// actually written.
    func save(bytes: Data, preferredName: String?, mime: String) throws -> URL {
        try Self.write(bytes: bytes, to: folder, preferredName: preferredName, mime: mime)
    }

    /// The file-system half of `save`, free of the main actor so a big write can run on a
    /// background task instead of freezing the UI. `dir` is the peer's folder path for the file
    /// (sanitised here), recreated under `folder`.
    nonisolated static func write(
        bytes: Data, to folder: URL, preferredName: String?, dir: String? = nil, mime: String
    ) throws -> URL {
        let target = try destination(in: folder, preferredName: preferredName, dir: dir, mime: mime)
        try bytes.write(to: target, options: .atomic)
        return target
    }

    /// Move a finished download (a temp file the inbox streamed chunks into) into place — a
    /// rename on one volume, a copy+delete across volumes, but never a pass through memory, which
    /// is what makes a 1 GiB file possible.
    nonisolated static func moveIn(
        _ temp: URL, to folder: URL, preferredName: String?, dir: String? = nil, mime: String
    ) throws -> URL {
        let target = try destination(in: folder, preferredName: preferredName, dir: dir, mime: mime)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    /// Where a received file goes: `folder/<sanitised dir>/<sanitised name>`, with the folders
    /// created and a free name picked (never overwriting).
    private nonisolated static func destination(
        in folder: URL, preferredName: String?, dir: String?, mime: String
    ) throws -> URL {
        let fm = FileManager.default
        var parent = folder
        for part in sanitizeDir(dir).split(separator: "/") {
            parent = parent.appendingPathComponent(String(part), isDirectory: true)
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        let base = sanitize(preferredName, mime: mime)
        var candidate = parent.appendingPathComponent(base)
        if fm.fileExists(atPath: candidate.path) {
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            var free = false
            // Bounded so a pathological folder can't spin here; 999 collisions is already absurd.
            for n in 2...999 {
                let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                candidate = parent.appendingPathComponent(name)
                if !fm.fileExists(atPath: candidate.path) { free = true; break }
            }
            // Refuse rather than fall through: the last candidate exists, and a write would
            // replace it.
            guard free else { throw CocoaError(.fileWriteFileExists) }
        }
        return candidate
    }

    /// Turn a folder path that came off the wire into something safe to join onto the download
    /// folder. Twin of the Kotlin `FileSink.sanitizeDir` — both run `protocol-vectors/dir-sanitize.json`.
    /// Splits on `/` and `\`, drops empty / `.` / `..` parts, replaces `:`, trims, caps a part at
    /// 100 characters and the path at 8 levels, so a peer can't escape the folder or build a
    /// pathological tree.
    nonisolated static func sanitizeDir(_ dir: String?) -> String {
        guard let dir else { return "" }
        var out: [String] = []
        for part in dir.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            let cleaned = String(
                part.replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .prefix(100)
            )
            if !cleaned.isEmpty { out.append(cleaned) }
            if out.count == 8 { break }
        }
        return out.joined(separator: "/")
    }

    /// Turn a name that came off the wire into something safe to join onto a path. The phone sends
    /// whatever the sharing app called the file, so treat it as untrusted: keep only the last path
    /// component (no traversal), drop the separators HFS+ and POSIX each care about, and fall back
    /// to a timestamped name when nothing usable is left.
    nonisolated static func sanitize(_ name: String?, mime: String) -> String {
        let raw = (name as NSString?)?.lastPathComponent ?? ""
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !cleaned.isEmpty { return truncate(cleaned) }

        let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "phone-\(stamp).\(ext)"
    }

    /// Most file systems cap a name at 255 bytes and fail the write past it. Cut the stem, keep the
    /// extension (it is what picks the app that opens the file), and leave headroom for the
    /// " 12" a name clash appends.
    nonisolated static func truncate(_ name: String, maxBytes: Int = 200) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let extPart = ext.isEmpty ? "" : "." + ext
        var stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let budget = max(1, maxBytes - extPart.utf8.count)
        while stem.utf8.count > budget { stem.removeLast() }
        return stem + extPart
    }
}

/// Reassembles chunked inbound `file` transfers — **on disk**.
///
/// The phone splits anything over `FileFrame` chunk size and repeats the full header on every
/// chunk, so frames may arrive in any order and a transfer never depends on chunk 0 landing first.
/// Each chunk is written straight into a temp file at `seq × chunkRawBytes` (the phone's
/// `FileInbox.kt` does the same): holding a gigabyte of chunks in a dictionary and then
/// concatenating it would need two gigabytes of RAM, which is what used to cap files at 64 MB.
///
/// Everything is bounded — an inbound transfer is peer-controlled: at most `maxConcurrent`
/// transfers, `maxBytes` each. A half-received transfer is **kept for `ttl`** (10 min) so a retry
/// of the same file can resume — the ack tells the sender how many leading chunks (`have`) are
/// already here — but it is shown as "receiving" only while fresh (`staleAfter`), and a stale one
/// is evicted rather than blocking a new transfer.
@MainActor
final class FileInbox {
    /// A transfer that just became complete.
    struct Assembled {
        /// Where the bytes are: a small one-frame file / clipboard image stays in memory; a
        /// chunked file is a temp file the caller must move (or delete).
        enum Payload {
            case memory(Data)
            case file(URL)
        }

        let mime: String
        let name: String?
        let dir: String?
        let disp: String
        let payload: Payload
    }

    /// What `accept` did with a frame. `rejected` is distinct from `buffered` on purpose: the
    /// receiver acks a stored chunk and **nacks** a refused one, so the sender hears about it now
    /// instead of reporting a delivery that never happened.
    enum Result {
        /// `have` = leading chunks `[0, have)` already stored, for the ack (resume).
        case buffered(received: Int, total: Int, have: Int)
        case done(Assembled)
        case rejected
    }

    private struct Partial {
        let mime: String
        let name: String?
        let dir: String?
        let disp: String
        let count: Int
        let file: URL
        let handle: FileHandle
        var seen = Set<Int>()
        /// Length of the contiguous run `0..<contiguous` — what resume reports as `have`.
        var contiguous = 0
        var bytes = 0
        var touched = Date()
    }

    private var partials: [String: Partial] = [:]
    private let log: (String) -> Void

    private let maxConcurrent = 2
    private let maxBytes: Int
    private let ttl: TimeInterval
    private let staleAfter: TimeInterval
    private let directory: URL

    nonisolated static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LinkToMac-inbox", isDirectory: true)
    }

    init(
        ttl: TimeInterval = 600,
        staleAfter: TimeInterval = 120,
        maxBytes: Int = FileFrame.maxTransferBytes,
        directory: URL = FileInbox.defaultDirectory,
        log: @escaping (String) -> Void
    ) {
        self.ttl = ttl
        self.staleAfter = staleAfter
        self.maxBytes = maxBytes
        self.directory = directory
        self.log = log
        Self.purge(directory, olderThan: 3600) // leftovers from a previous run
    }

    /// Chunks stored / chunks expected for the freshest transfer still arriving, or nil when
    /// nothing is. Drives the dashboard's "receiving" row; a partial that has gone quiet for
    /// `staleAfter` no longer counts (it is only being kept for a resume).
    var progress: (name: String, received: Int, total: Int)? {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        guard let p = partials.values.filter({ $0.touched >= cutoff }).max(by: { $0.touched < $1.touched })
        else { return nil }
        return (p.name ?? "File", p.seen.count, p.count)
    }

    /// Take one decoded data frame: store it, complete the transfer, or reject it (the log says
    /// why).
    func accept(_ frame: FileFrame.Parsed) -> Result {
        sweep()

        if frame.isSingle {
            return .done(Assembled(mime: frame.mime, name: frame.name, dir: frame.dir, disp: frame.disp,
                                   payload: .memory(frame.bytes)))
        }
        guard let id = frame.id else { return .rejected }
        guard frame.count > 0, frame.seq >= 0, frame.seq < frame.count else {
            log("file: chunk \(frame.seq)/\(frame.count) out of range")
            return .rejected
        }
        // A chunk is written at seq × chunkRawBytes; a longer one would overwrite its neighbour.
        guard frame.bytes.count <= FileFrame.chunkRawBytes else {
            log("file: chunk of \(frame.bytes.count) B exceeds the chunk size; dropping \(id)")
            discard(id)
            return .rejected
        }

        var partial: Partial
        if let existing = partials[id] {
            partial = existing
        } else {
            if partials.count >= maxConcurrent, !evictOldestStale() {
                log("file: too many transfers in flight; dropping \(id)")
                return .rejected
            }
            guard let created = open(frame) else { return .rejected }
            // Registered at once, so every reject below can `discard` it (close + delete the temp file).
            partials[id] = created
            partial = created
        }
        guard partial.count == frame.count else {
            log("file: chunk count changed mid-transfer for \(id); dropping")
            discard(id)
            return .rejected
        }

        if !partial.seen.contains(frame.seq) {
            let bytes = partial.bytes + frame.bytes.count
            guard bytes <= maxBytes else {
                log("file: transfer \(id) exceeded \(maxBytes / (1024 * 1024)) MB; dropping")
                discard(id)
                return .rejected
            }
            do {
                try partial.handle.seek(toOffset: UInt64(frame.seq) * UInt64(FileFrame.chunkRawBytes))
                try partial.handle.write(contentsOf: frame.bytes)
            } catch {
                log("file: couldn't write chunk \(frame.seq) of \(id): \(error.localizedDescription)")
                discard(id)
                return .rejected
            }
            partial.bytes = bytes
            partial.seen.insert(frame.seq)
            while partial.seen.contains(partial.contiguous) { partial.contiguous += 1 }
        }
        partial.touched = Date()

        guard partial.seen.count == partial.count else {
            partials[id] = partial
            return .buffered(received: partial.seen.count, total: partial.count, have: partial.contiguous)
        }
        partials[id] = nil
        try? partial.handle.close()
        return .done(Assembled(mime: partial.mime, name: partial.name, dir: partial.dir, disp: partial.disp,
                               payload: .file(partial.file)))
    }

    private func open(_ frame: FileFrame.Parsed) -> Partial? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).part")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                log("file: couldn't create a temp file in \(directory.path)")
                return nil
            }
            let handle = try FileHandle(forWritingTo: url)
            return Partial(mime: frame.mime, name: frame.name, dir: frame.dir, disp: frame.disp,
                           count: frame.count, file: url, handle: handle)
        } catch {
            log("file: couldn't open a temp file: \(error.localizedDescription)")
            return nil
        }
    }

    /// Forget a transfer and delete its temp file.
    private func discard(_ id: String) {
        guard let partial = partials.removeValue(forKey: id) else { return }
        try? partial.handle.close()
        try? FileManager.default.removeItem(at: partial.file)
    }

    /// Make room by dropping the partial that has been quiet longest — but only if it has been
    /// quiet for `staleAfter`; a live transfer is never evicted. True if one was freed.
    private func evictOldestStale() -> Bool {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        guard let (id, _) = partials.filter({ $0.value.touched < cutoff }).min(by: { $0.value.touched < $1.value.touched })
        else { return false }
        log("file: evicting idle transfer \(id) to make room")
        discard(id)
        return true
    }

    /// Drop transfers whose sender went away for good (idle past `ttl`), deleting their temp files.
    /// Also called on a timer while a transfer is showing, so the "receiving" row can't outlive a
    /// phone that went away.
    func sweep() {
        let cutoff = Date().addingTimeInterval(-ttl)
        for (id, partial) in partials where partial.touched < cutoff {
            log("file: transfer \(id) abandoned (\(partial.seen.count)/\(partial.count) chunks)")
            discard(id)
        }
    }

    /// Delete temp files older than `age` — what a crash or a quit mid-transfer leaves behind.
    nonisolated static func purge(_ directory: URL, olderThan age: TimeInterval) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: item) }
        }
    }
}
