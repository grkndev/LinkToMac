import Foundation
import UniformTypeIdentifiers

/// Where a dragged **file promise** is materialised before it is sent.
///
/// Dragging a Mail attachment, a Photos item or a Safari download out of its list does not hand over
/// a file: the source app only *promises* to write one, on request, and it must be written
/// somewhere. Nothing downstream can read a promise — `FileBatchPlanner` and `FileSender` want a real
/// file on disk — so each promised file is received (or copied from the item provider's temporary
/// file, which is only valid for the duration of a callback) into a staging folder first, and the
/// staged URL is what gets sent.
///
/// **Lifetime.** A staged file has to outlive `finishBatch`: a failed row keeps its URL as its retry
/// source (`FileTransferRecord.resumeSources`). But that history is in memory, so a relaunch makes
/// every earlier staged file unreachable: `purgeAll()` at launch clears the lot, and `makeFolder()`
/// sweeps anything older than a day so a menu-bar app that runs for weeks doesn't pile them up.
///
/// Foundation only, so the test target compiles it. The unsandboxed app may write to the temp
/// directory freely.
enum DropStaging {
    static let folderName = "LinkToMacDrops"
    /// Older than this, a staged drop is swept the next time one is made.
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// `<temp>/LinkToMacDrops`. `base` is a parameter so the tests use their own directory.
    static func root(base: URL = FileManager.default.temporaryDirectory) -> URL {
        base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// A fresh, empty folder for ONE drop. Files keep their real names inside it, so the phone sees
    /// "invoice.pdf" and two drops of "image.jpg" can't collide.
    static func makeFolder(base: URL = FileManager.default.temporaryDirectory, now: Date = Date()) throws -> URL {
        sweep(base: base, now: now)
        let folder = root(base: base).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies `source` into `folder` under a sane name and returns the staged URL.
    ///
    /// `source` is typically an item provider's temporary file, deleted when its callback returns,
    /// so this must run inside that callback. A second file with the same name becomes "name 2.ext".
    static func stage(
        copying source: URL, suggestedName: String?, typeIdentifier: String?, into folder: URL
    ) throws -> URL {
        let fm = FileManager.default
        let name = stagedName(suggested: suggestedName, source: source, typeIdentifier: typeIdentifier)
        var target = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(numbered(name, n))
            n += 1
        }
        try fm.copyItem(at: source, to: target)
        return target
    }

    /// The name the phone will see. The suggested name wins, then the temp file's own; it is treated
    /// as untrusted (last path component, `/` and `:` replaced, no leading dots, ≤ 200 bytes with the
    /// extension kept) and gets an extension from the file or its type when it has none — a Photos
    /// item is often suggested as plain "IMG_0042".
    static func stagedName(suggested: String?, source: URL, typeIdentifier: String?) -> String {
        let candidate = [suggested, source.lastPathComponent]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let cleaned = (candidate as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // "/" or "///" cleans to "-": that is no name, so fall back like an empty one.
        let meaningful = !cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "- ")).isEmpty
        var name = meaningful ? FileDropStore.truncate(cleaned) : "Dropped item"
        if (name as NSString).pathExtension.isEmpty {
            let ext = source.pathExtension.isEmpty
                ? (typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "")
                : source.pathExtension
            if !ext.isEmpty { name += "." + ext }
        }
        return name
    }

    /// "report.pdf" → "report 2.pdf".
    static func numbered(_ name: String, _ n: Int) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name) \(n)" }
        return "\((name as NSString).deletingPathExtension) \(n).\(ext)"
    }

    /// The pasteboard types AppKit puts on an item that is a **file promise**
    /// (`NSFilePromiseProvider`). A text selection, a web link or a plain dragged image doesn't
    /// carry them.
    static let promiseMarkers: Set<String> = [
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.NSFilePromiseItemMetaData",
    ]

    /// Which of a provider's registered types is the promised file's content, or nil when the item
    /// is not a file promise at all.
    ///
    /// **The promise markers are required.** Guessing "file-like" from the content type alone is
    /// not safe: `public.url-name` (a dragged link's title) conforms to `public.data`, a Safari
    /// text selection also offers `webarchive`/`rtfd`, and sending any of those to the phone as a
    /// "file" would be wrong — while real files (`.zip`, `.pdf`, `.jpg`) have no type in common
    /// that a deny-list could safely cut around. So: markers present, then the first registered
    /// type that is data and is neither bookkeeping (`com.apple.pasteboard.…`), a dynamic type, a
    /// URL nor a link title. A text type IS accepted here — a promised `notes.txt`.
    ///
    /// **When the markers are there but no concrete content type is, the answer is `public.data`.**
    /// Measured with a real `NSFilePromiseProvider`: the item's pasteboard types are only the
    /// markers and `promised-…` bookkeeping; the actual type (`public.plain-text`) lives on
    /// `NSFilePromiseReceiver.fileTypes`, not among them. Whether an `NSItemProvider` surfaces it is
    /// not something this code can know, so the generic type is the best request to make.
    static func fileLikeType(among identifiers: [String]) -> String? {
        guard identifiers.contains(where: { promiseMarkers.contains($0) }) else { return nil }
        let specific = identifiers.first { id in
            guard !id.hasPrefix("com.apple.pasteboard."), !id.hasPrefix("dyn."),
                  id != "public.url-name", let type = UTType(id)
            else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        }
        return specific ?? UTType.data.identifier
    }

    /// Removes staged drops older than `maxAge`. Best effort, never throws.
    static func sweep(base: URL = FileManager.default.temporaryDirectory, now: Date = Date(),
                      maxAge: TimeInterval = DropStaging.maxAge) {
        let fm = FileManager.default
        let root = root(base: base)
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            let url = root.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { continue }
            if now.timeIntervalSince(modified) > maxAge { try? fm.removeItem(at: url) }
        }
    }

    /// Removes every staged drop. Called at launch: the transfer history that could still point at
    /// them lives in memory and is empty after a relaunch.
    static func purgeAll(base: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: root(base: base))
    }
}
