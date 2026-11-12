import Foundation

/// How the Finder share extension hands a file to the app **without putting its path in a URL**.
///
/// The extension is sandboxed and can't send anything itself, so it used to open
/// `linktomac://send?path=<absolute path>` and let the app read the file. That made the URL scheme a
/// capability: anything that can open a URL (Terminal's `open`, another app, a web page) could make
/// the Mac send any readable file or folder to the paired phone.
///
/// Now the URL is `linktomac://send?id=<uuid>` and carries nothing. The real path sits in a small
/// JSON file in the **extension's own sandbox container**:
///
///     ~/Library/Containers/dev.grkn.LinkToMac.ShareExtension/Data/Library/Caches/ShareHandoff/<uuid>.json
///
/// The app is not sandboxed, so it can read that container; a web page or a sandboxed app can only
/// open URLs, and can't write there. An `id` nobody planted resolves to nothing. (A same-user,
/// unsandboxed process can still plant one — but it could already read every file the URL used to
/// expose, so that door was never the one being closed.)
///
/// Foundation only, and compiled into the app, the extension and the test target, so the side that
/// writes and the side that reads are the same source and can't drift. `home` is a parameter
/// throughout: the extension passes its own `NSHomeDirectory()` (inside a sandbox that is the
/// container's `Data` folder), the app passes `extensionHome()`, and the tests pass a temp directory.
enum ShareHandoff {
    static let extensionBundleID = "dev.grkn.LinkToMac.ShareExtension"
    /// A hand-off older than this is refused: the URL arrives within moments of the write.
    static let maxAge: TimeInterval = 120
    /// Leftovers (an id whose URL never arrived) are swept after this.
    static let sweepAge: TimeInterval = 600
    /// A real record is ~200 bytes; anything bigger isn't one.
    static let maxRecordBytes = 8 * 1024

    struct Record: Codable, Equatable {
        var path: String
        /// Seconds since 1970.
        var created: TimeInterval
    }

    enum WriteError: Error { case notAbsolute }

    /// `<home>/Library/Caches/ShareHandoff`.
    static func directory(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Caches/ShareHandoff", isDirectory: true)
    }

    /// The `home` the **app** passes: the extension's container, as seen from outside the sandbox.
    static func extensionHome(userHome: String = NSHomeDirectory()) -> String {
        userHome + "/Library/Containers/\(extensionBundleID)/Data"
    }

    /// Extension side: record `path` and return the id to put in the URL.
    static func write(path: String, home: String, now: Date = Date()) throws -> String {
        guard path.hasPrefix("/") else { throw WriteError.notAbsolute }
        let id = UUID().uuidString
        let dir = directory(home: home)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Record(path: path, created: now.timeIntervalSince1970))
        try data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        return id
    }

    /// App side: the file the extension recorded under `id`, or nil.
    ///
    /// Refuses anything that isn't exactly what the extension writes, and **uses the record up**:
    /// once the file exists it is deleted whether or not it passes, so an id works at most once.
    static func consume(
        id: String, home: String, now: Date = Date(), fileManager fm: FileManager = .default
    ) -> URL? {
        let dir = directory(home: home)
        defer { sweep(dir, now: now, fileManager: fm) }

        // Only the canonical (upper-case) UUID spelling. That has no separators or dots, so the id
        // can't traverse out of `dir`.
        guard UUID(uuidString: id)?.uuidString == id else { return nil }

        let file = dir.appendingPathComponent("\(id).json")
        // `attributesOfItem` does not follow a symlink: it describes the link itself.
        guard let attrs = try? fm.attributesOfItem(atPath: file.path) else { return nil }
        defer { try? fm.removeItem(at: file) }

        guard attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxRecordBytes else { return nil }
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }

        let age = now.timeIntervalSince1970 - record.created
        guard age >= -2, age <= maxAge else { return nil }
        guard record.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: record.path)
    }

    /// Removes records nobody collected. Best effort, never throws.
    private static func sweep(_ dir: URL, now: Date, fileManager fm: FileManager) {
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let path = dir.appendingPathComponent(name).path
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else { continue }
            if now.timeIntervalSince(modified) > sweepAge { try? fm.removeItem(atPath: path) }
        }
    }
}
