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
/// It hands the path over with `linktomac://send?path=…` through `NSExtensionContext.open`, and
/// the app (unsandboxed, so no bookmark needed) reads the file directly. A shared app-group
/// container would be the usual channel, but app groups need a real team identity and this app is
/// ad-hoc signed with no Apple Developer account.
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
        NSLog("[SendToPhone] viewDidLoad, inputItems=%d", extensionContext?.inputItems.count ?? -1)

        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachment = item.attachments?.first
        else {
            NSLog("[SendToPhone] no attachment on the extension item")
            return complete()
        }
        NSLog("[SendToPhone] offered types: %@", attachment.registeredTypeIdentifiers.joined(separator: ", "))

        // `loadItem`, not `loadDataRepresentation`: a Finder share hands over an NSURL, and which
        // concrete form arrives varies, so accept all three rather than betting on one.
        attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] coded, error in
            let url: URL? = (coded as? URL)
                ?? (coded as? NSURL) as URL?
                ?? (coded as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let error {
                NSLog("[SendToPhone] loadItem failed: %@", error.localizedDescription)
            }
            guard let url, let handoff = Self.handoffURL(for: url) else {
                NSLog("[SendToPhone] no usable file URL (got %@)", String(describing: coded))
                DispatchQueue.main.async { self?.complete() }
                return
            }
            Self.log.info("handing off \(handoff.absoluteString, privacy: .public)")
            DispatchQueue.main.async { self?.handOff(handoff) }
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

    /// `linktomac://send?path=<percent-encoded absolute path>`.
    private static func handoffURL(for file: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "linktomac"
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "path", value: file.path)]
        return components.url
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
