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
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = Self.sanitize(preferredName, mime: mime)
        var candidate = folder.appendingPathComponent(base)
        if fm.fileExists(atPath: candidate.path) {
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            // Bounded so a pathological folder can't spin here; 999 collisions is already absurd.
            for n in 2...999 {
                let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                candidate = folder.appendingPathComponent(name)
                if !fm.fileExists(atPath: candidate.path) { break }
            }
        }
        try bytes.write(to: candidate, options: .atomic)
        return candidate
    }

    /// Turn a name that came off the wire into something safe to join onto a path. The phone sends
    /// whatever the sharing app called the file, so treat it as untrusted: keep only the last path
    /// component (no traversal), drop the separators HFS+ and POSIX each care about, and fall back
    /// to a timestamped name when nothing usable is left.
    static func sanitize(_ name: String?, mime: String) -> String {
        let raw = (name as NSString?)?.lastPathComponent ?? ""
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if !cleaned.isEmpty { return cleaned }

        let ext = UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "phone-\(stamp).\(ext)"
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
    private let maxBytes = 64 * 1024 * 1024
    private let ttl: TimeInterval = 120

    init(log: @escaping (String) -> Void) { self.log = log }

    /// Chunks stored / chunks expected for the transfer in flight, or nil when nothing is
    /// arriving. Drives the dashboard's "receiving" row.
    private(set) var progress: (name: String, received: Int, total: Int)?

    /// Take one decoded data frame. Returns the finished file when this frame completed it, and
    /// nil when it was buffered (or rejected — the log says which).
    func accept(_ frame: FileFrame.Parsed) -> Assembled? {
        sweep()

        if frame.isSingle {
            return Assembled(mime: frame.mime, name: frame.name, disp: frame.disp, bytes: frame.bytes)
        }
        guard let id = frame.id else { return nil }
        guard frame.count > 0, frame.seq >= 0, frame.seq < frame.count else {
            log("file: chunk \(frame.seq)/\(frame.count) out of range")
            progress = nil
            return nil
        }

        var partial = partials[id] ?? Partial(
            mime: frame.mime, name: frame.name, disp: frame.disp,
            count: frame.count, chunks: [:], bytes: 0, touched: Date()
        )
        if partials[id] == nil, partials.count >= maxConcurrent {
            log("file: too many transfers in flight; dropping \(id)")
            progress = nil
            return nil
        }
        guard partial.count == frame.count else {
            log("file: chunk count changed mid-transfer for \(id); dropping")
            partials[id] = nil
            progress = nil
            return nil
        }
        if partial.chunks[frame.seq] == nil {
            partial.bytes += frame.bytes.count
            guard partial.bytes <= maxBytes else {
                log("file: transfer \(id) exceeded \(maxBytes / (1024 * 1024)) MB; dropping")
                partials[id] = nil
                progress = nil
                return nil
            }
            partial.chunks[frame.seq] = frame.bytes
        }
        partial.touched = Date()

        guard partial.chunks.count == partial.count else {
            partials[id] = partial
            progress = (partial.name ?? "File", partial.chunks.count, partial.count)
            return nil
        }
        partials[id] = nil
        progress = nil
        var bytes = Data(capacity: partial.bytes)
        for seq in 0..<partial.count {
            guard let chunk = partial.chunks[seq] else { return nil }
            bytes.append(chunk)
        }
        return Assembled(mime: partial.mime, name: partial.name, disp: partial.disp, bytes: bytes)
    }

    /// Drop transfers whose sender went away mid-file, so a dead phone can't hold memory forever.
    private func sweep() {
        let cutoff = Date().addingTimeInterval(-ttl)
        for (id, partial) in partials where partial.touched < cutoff {
            log("file: transfer \(id) abandoned (\(partial.chunks.count)/\(partial.count) chunks)")
            partials[id] = nil
            progress = nil
        }
    }
}

/// One transfer in flight, for the progress UI. Deliberately unit-agnostic: the sender counts
/// bytes (it knows the file size up front), the receiver counts chunks (it doesn't), and the ratio
/// is all the UI needs from either.
struct TransferProgress: Equatable {
    let name: String
    var done: Int
    var total: Int

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var percent: Int { Int((fraction * 100).rounded()) }
}

/// Sends a local file to the phone in `FileFrame.chunkRawBytes` chunks — the Mac→phone mirror of
/// the phone's `ClipForegroundService.sendAsFile`.
///
/// **NOT `@MainActor`** (the same shape `LanServer` uses): the send loop blocks on an ack window,
/// which must never happen on the main actor, so all of it runs on a private serial queue and the
/// callbacks marshal back out. `ack(id:)` is deliberately lock-guarded rather than queue-hopping —
/// the queue is *blocked* inside `DispatchSemaphore.wait` when an ack arrives, so dispatching onto
/// it would deadlock.
///
/// Two relay limits shape this, and tripping either drops the connection rather than the frame:
/// the 8 MiB per-peer send buffer (hence a window of only `ackWindow` unacked chunks) and the
/// 120-frames-per-10 s rate limit (hence `relayChunkInterval`). A LAN-direct transfer goes
/// straight to the phone and has neither, so it isn't paced.
final class FileSender: @unchecked Sendable {
    enum Outcome: Equatable {
        case sent
        case failed(String)
    }

    private static let ackWindow = 4
    private static let ackTimeout: TimeInterval = 30
    private static let relayChunkInterval: TimeInterval = 0.125

    private let queue = DispatchQueue(label: "dev.grkn.LinkToMac.filesend")
    private let lock = NSLock()
    private var activeID: String?
    private var window = DispatchSemaphore(value: 0)

    /// True while a transfer is in flight — one at a time, so the window and the socket are never
    /// shared between two files.
    var isSending: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeID != nil
    }

    /// The phone acknowledging one stored chunk. Safe from any thread.
    func ack(id: String) {
        lock.lock()
        let match = activeID == id
        lock.unlock()
        if match { window.signal() }
    }

    /// Stream `url` to the phone. `emit` is called once per chunk with the assembled `file`
    /// plaintext; `progress` and `done` report back for the UI. All three are called off the main
    /// thread — the caller marshals.
    func send(
        url: URL,
        overLAN: Bool,
        emit: @escaping @Sendable (Data) -> Void,
        progress: @escaping @Sendable (Int, Int) -> Void,
        done: @escaping @Sendable (Outcome) -> Void
    ) {
        queue.async { [self] in
            let name = url.lastPathComponent
            guard !isSending else { return done(.failed("Already sending a file")) }

            let total: Int
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                total = values.fileSize ?? 0
            } catch {
                return done(.failed("Couldn't read \(name)"))
            }
            guard total > 0 else { return done(.failed("\(name) is empty")) }
            guard total <= FileFrame.maxTransferBytes else {
                return done(.failed("\(name) is larger than \(FileFrame.maxTransferBytes / (1024 * 1024)) MB"))
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return done(.failed("Couldn't open \(name)"))
            }
            defer { try? handle.close() }

            let mime = Self.mimeType(for: url)
            let count = (total + FileFrame.chunkRawBytes - 1) / FileFrame.chunkRawBytes
            let id = String(UUID().uuidString.prefix(8))

            lock.lock(); activeID = id; window = DispatchSemaphore(value: Self.ackWindow); lock.unlock()
            defer { lock.lock(); activeID = nil; lock.unlock() }

            var sent = 0
            var lastSentAt = Date.distantPast
            for seq in 0..<count {
                guard window.wait(timeout: .now() + Self.ackTimeout) == .success else {
                    return done(.failed("Your phone stopped responding"))
                }
                guard let chunk = try? handle.read(upToCount: FileFrame.chunkRawBytes), !chunk.isEmpty else {
                    return done(.failed("Couldn't read \(name)"))
                }
                // Re-checked per chunk: a LAN link can drop to the relay mid-transfer.
                if !overLAN {
                    let wait = Self.relayChunkInterval - Date().timeIntervalSince(lastSentAt)
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
                emit(FileFrame.payload(
                    mime: mime, bytes: chunk, name: name,
                    disp: FileFrame.dispSave, id: id, seq: seq, count: count
                ))
                lastSentAt = Date()
                sent += chunk.count
                progress(sent, total)
            }

            // Reclaim the whole window: only then has every chunk actually been stored, which is
            // what makes the success report a delivery receipt rather than an optimistic guess.
            for _ in 0..<Self.ackWindow {
                guard window.wait(timeout: .now() + Self.ackTimeout) == .success else {
                    return done(.failed("Your phone stopped responding"))
                }
            }
            done(.sent)
        }
    }

    /// Best-effort content type from the path extension; the phone only uses it to label the file
    /// and to pick a viewer, so an unknown type falling back to octet-stream is harmless.
    private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
