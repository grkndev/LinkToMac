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

    /// The file-system half of `save`, free of the main actor so a 64 MB write can run on a
    /// background task instead of freezing the UI.
    nonisolated static func write(bytes: Data, to folder: URL, preferredName: String?, mime: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = sanitize(preferredName, mime: mime)
        var candidate = folder.appendingPathComponent(base)
        if fm.fileExists(atPath: candidate.path) {
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            var free = false
            // Bounded so a pathological folder can't spin here; 999 collisions is already absurd.
            for n in 2...999 {
                let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                candidate = folder.appendingPathComponent(name)
                if !fm.fileExists(atPath: candidate.path) { free = true; break }
            }
            // Refuse rather than fall through: the last candidate exists, and `.atomic` would
            // replace it.
            guard free else { throw CocoaError(.fileWriteFileExists) }
        }
        try bytes.write(to: candidate, options: .atomic)
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

/// Reassembles chunked inbound `file` transfers.
///
/// The phone splits anything over `FileFrame` chunk size and repeats the full header on every
/// chunk, so frames may be buffered in any order and a transfer never depends on chunk 0 landing
/// first. Everything here is bounded — an inbound transfer is attacker-influenced in the sense
/// that a buggy or hostile peer could otherwise pin unbounded memory:
/// at most `maxConcurrent` transfers, `maxBytes` each, and anything idle past `ttl` is swept.
@MainActor
final class FileInbox {
    /// A transfer that just became complete.
    struct Assembled {
        let mime: String
        let name: String?
        let disp: String
        let bytes: Data
    }

    /// What `accept` did with a frame. `rejected` is distinct from `buffered` on purpose: the
    /// receiver acks a stored chunk and **nacks** a refused one, so the sender hears about it now
    /// instead of reporting a delivery that never happened.
    enum Result {
        case buffered(received: Int, total: Int)
        case done(Assembled)
        case rejected
    }

    private struct Partial {
        let mime: String
        let name: String?
        let disp: String
        let count: Int
        var chunks: [Int: Data]
        var bytes: Int
        var touched: Date
    }

    private var partials: [String: Partial] = [:]
    private let log: (String) -> Void

    private let maxConcurrent = 2
    private let maxBytes: Int
    private let ttl: TimeInterval


    init(ttl: TimeInterval = 120, maxBytes: Int = FileFrame.maxTransferBytes, log: @escaping (String) -> Void) {
        self.ttl = ttl
        self.maxBytes = maxBytes
        self.log = log
    }

    /// Chunks stored / chunks expected for the transfer in flight, or nil when nothing is
    /// arriving. Drives the dashboard's "receiving" row.
    private(set) var progress: (name: String, received: Int, total: Int)?

    /// Take one decoded data frame: buffer it, complete the transfer, or reject it (the log says
    /// why).
    func accept(_ frame: FileFrame.Parsed) -> Result {
        sweep()

        if frame.isSingle {
            return .done(Assembled(mime: frame.mime, name: frame.name, disp: frame.disp, bytes: frame.bytes))
        }
        guard let id = frame.id else { return .rejected }
        guard frame.count > 0, frame.seq >= 0, frame.seq < frame.count else {
            log("file: chunk \(frame.seq)/\(frame.count) out of range")
            return reject()
        }

        if partials[id] == nil, partials.count >= maxConcurrent {
            log("file: too many transfers in flight; dropping \(id)")
            return .rejected
        }
        var partial = partials[id] ?? Partial(
            mime: frame.mime, name: frame.name, disp: frame.disp,
            count: frame.count, chunks: [:], bytes: 0, touched: Date()
        )
        guard partial.count == frame.count else {
            log("file: chunk count changed mid-transfer for \(id); dropping")
            partials[id] = nil
            return reject()
        }
        if partial.chunks[frame.seq] == nil {
            partial.bytes += frame.bytes.count
            guard partial.bytes <= maxBytes else {
                log("file: transfer \(id) exceeded \(maxBytes / (1024 * 1024)) MB; dropping")
                partials[id] = nil
                return reject()
            }
            partial.chunks[frame.seq] = frame.bytes
        }
        partial.touched = Date()

        guard partial.chunks.count == partial.count else {
            partials[id] = partial
            progress = (partial.name ?? "File", partial.chunks.count, partial.count)
            return .buffered(received: partial.chunks.count, total: partial.count)
        }
        partials[id] = nil
        progress = nil
        var bytes = Data(capacity: partial.bytes)
        for seq in 0..<partial.count {
            guard let chunk = partial.chunks[seq] else { return reject() }
            bytes.append(chunk)
        }
        return .done(Assembled(mime: partial.mime, name: partial.name, disp: partial.disp, bytes: bytes))
    }

    private func reject() -> Result {
        if partials.isEmpty { progress = nil }
        return .rejected
    }

    /// Drop transfers whose sender went away mid-file, so a dead phone can't hold memory forever.
    /// Also called on a timer while a transfer is showing: it used to run only when the next frame
    /// arrived, so a phone that vanished left the "receiving" row on screen for good.
    func sweep() {
        let cutoff = Date().addingTimeInterval(-ttl)
        for (id, partial) in partials where partial.touched < cutoff {
            log("file: transfer \(id) abandoned (\(partial.chunks.count)/\(partial.count) chunks)")
            partials[id] = nil
        }
        if partials.isEmpty { progress = nil }
    }
}
