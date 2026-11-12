import Cocoa
import os
import UniformTypeIdentifiers

/// **Needs a real certificate chain to run.** Under the old ad-hoc signature `amfid` refused the
/// binary (`AppleMobileFileIntegrityError -423`) and the menu item silently did nothing; with a
/// Developer ID signature the process runs. Registration (`pluginkit`) and execution (`amfid`) are
/// separate gates. Debug with:
///     log show --last 5m --predicate 'process == "SendToPhone"' --info --debug
/// NSLog is redacted to `<private>` in the unified log, so this file reports through `Logger` with
/// `privacy: .public` — filter on `subsystem == "dev.grkn.LinkToMac.ShareExtension"`.
///
/// **The hand-off must go through `NSWorkspace`, not `NSExtensionContext.open`.** Verified on the
/// first Developer-ID build: `extensionContext.open` was called and returned instantly, but the app
/// never received the URL (the same `linktomac://` opened from Terminal reached it fine). Apple
/// leaves it to each extension point whether `open` does anything, and a Finder share extension
/// evidently doesn't honor it. `extensionContext.open` is kept only as a fallback.
///
/// The Finder "Share ▸ Send to Phone" entry — the Mac-side mirror of the phone's share-sheet
/// targets. Right-click any file, share it, and it goes to the phone's Downloads.
///
/// **No UI.** macOS share extensions usually present a compose sheet; this one has nothing to
/// compose, so it completes as soon as it has the file. The user already chose the file and the
/// destination by picking this entry.
///
/// **How it reaches the app.** An extension is sandboxed even though the host app is not, so it
/// can't do the sending itself — the relay/LAN connection and the pairing key live in the app.
/// It records the path in a small file inside *its own* container (`ShareHandoff`, compiled into
/// both targets) and opens `linktomac://send?id=<uuid>`; the app (unsandboxed, so it can read the
/// container and the file, no bookmark needed) looks the id up. The URL itself names no file:
/// anything can open a URL, and a `path=` in it would have let any process or web page make this
/// Mac send any readable file to the phone. A shared app-group container would be the usual
/// channel, but it needs a team-provisioned entitlement and would break ad-hoc local builds.
/// `@objc(ShareViewController)` is load-bearing: `NSExtensionPrincipalClass` in Info.plist is
/// looked up through the Objective-C runtime, and a plain Swift class registers under its
/// *module-qualified* name (`SendToPhone.ShareViewController`), which that lookup would miss.
@objc(ShareViewController)
final class ShareViewController: NSViewController {

    override func loadView() {
        // A real (if tiny) frame: the system presents this controller's view, and a zero-sized one
        // is a good way to have the presentation quietly fail before viewDidLoad ever runs.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Everything Finder selected: every attachment of every item, in the order it listed them.
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        NSLog("[SendToPhone] viewDidLoad, items=%d attachments=%d", items.count, attachments.count)
        guard !attachments.isEmpty else {
            NSLog("[SendToPhone] no attachment on the extension item")
            return complete()
        }

        // One slot per attachment, so the files keep their order whichever load finishes first.
        let slots = URLSlots(count: attachments.count)
        let group = DispatchGroup()
        for (index, attachment) in attachments.enumerated() {
            group.enter()
            // `loadItem`, not `loadDataRepresentation`: a Finder share hands over an NSURL, and which
            // concrete form arrives varies, so accept all three rather than betting on one.
            attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { coded, error in
                let url: URL? = (coded as? URL)
                    ?? (coded as? NSURL) as URL?
                    ?? (coded as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let error {
                    NSLog("[SendToPhone] loadItem failed: %@", error.localizedDescription)
                }
                // The type only: `coded` is the shared file's URL, i.e. its path.
                if url == nil { NSLog("[SendToPhone] attachment %d has no file URL (got %@)", index, String(describing: type(of: coded))) }
                slots.set(index, url)
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            let urls = slots.fileURLs()
            guard !urls.isEmpty, let handoff = Self.handoffURL(for: urls) else {
                NSLog("[SendToPhone] no usable file URL, or the hand-off couldn't be recorded")
                self?.complete()
                return
            }
            // A count, never the paths: they are the user's file names.
            Self.log.info("handing off \(urls.count, privacy: .public) file(s)")
            self?.handOff(handoff)
        }
    }

    private static let log = Logger(subsystem: "dev.grkn.LinkToMac.ShareExtension", category: "handoff")

    /// Opens the `linktomac://` URL with `NSWorkspace` (see the type comment for why), falling back
    /// to `extensionContext.open`. The request is completed only once the attempt has resolved —
    /// completing first can tear the extension process down before LaunchServices has the URL.
    private func handOff(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false // the file is already on its way; don't pull the app to the front
        NSWorkspace.shared.open(url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil {
                    Self.log.info("NSWorkspace.open succeeded")
                    return self.complete()
                }
                Self.log.error("NSWorkspace.open failed: \(error!.localizedDescription, privacy: .public); trying extensionContext.open")
                self.extensionContext?.open(url) { ok in
                    Self.log.info("extensionContext.open returned \(ok, privacy: .public)")
                    self.complete()
                }
            }
        }
    }

    /// `linktomac://send?id=<uuid>`. The paths are recorded, together, in this extension's container
    /// — not in the URL (see `ShareHandoff`). `NSHomeDirectory()` inside the sandbox is the
    /// container's `Data` folder — the same place the app resolves with `ShareHandoff.extensionHome()`.
    private static func handoffURL(for files: [URL]) -> URL? {
        let id: String
        do {
            id = try ShareHandoff.write(paths: files.map(\.path), home: NSHomeDirectory())
        } catch {
            // Domain and code only: a Cocoa error's description can quote a file's path.
            let e = error as NSError
            log.error("couldn't record the hand-off: \(e.domain, privacy: .public) \(e.code, privacy: .public)")
            return nil
        }
        var components = URLComponents()
        components.scheme = "linktomac"
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

/// Collects the attachment loads, which finish on arbitrary threads, into fixed slots.
private final class URLSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [URL?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        slots[index] = url
    }

    /// The file URLs that loaded, in the order they were listed, each path once.
    func fileURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return slots.compactMap { $0 }.filter { $0.isFileURL && seen.insert($0.path).inserted }
    }
}
